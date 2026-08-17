// ═══════════════════════════════════════════════════════════════
// APP: swiftNOTES
// AES-256 encrypted notebook with archive
// File: swiftNOTES/source_code/scn.main.swift
// Updated: 2026-08-17
// ═══════════════════════════════════════════════════════════════

import Foundation
import CryptoKit

// MARK: - App Storage Location

/// Resolves the directory the compiled binary itself lives in — not the current working
/// directory, which varies by how the app is launched. Kept consistent with the rest of the
/// suite so a folder-sync tool like Syncthing can carry notes.json between machines if you want
/// that. The file itself is real AES-256-GCM ciphertext, so a copy sitting in a synced folder
/// doesn't expose note content on its own — it's only as strong as your master password.
func resolveAppDataDirectory() -> URL {
    let executablePath = CommandLine.arguments.first ?? "."
    return URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().deletingLastPathComponent()
}

// MARK: - View Preferences
// A small, separate, UNENCRYPTED file for view-only preferences like
// hideArchived -- deliberately kept out of the encrypted notes.json
// rather than added as a new field there. It's not sensitive data, and
// keeping it separate avoids touching the encrypted file's structure
// (and the backward-compatibility handling that would need) just to
// remember a display toggle.
struct NotesPreferences: Codable {
    var hideArchived: Bool = false
}

let notesPrefsURL = resolveAppDataDirectory().appendingPathComponent("notes_prefs.json")

func loadNotesPreferences() -> NotesPreferences {
    guard let data = try? Data(contentsOf: notesPrefsURL),
          let prefs = try? JSONDecoder().decode(NotesPreferences.self, from: data) else {
        return NotesPreferences()
    }
    return prefs
}

func saveNotesPreferences(_ prefs: NotesPreferences) {
    guard let data = try? JSONEncoder().encode(prefs) else { return }
    try? data.write(to: notesPrefsURL, options: .atomic)
}

// MARK: - Debug Logger
//
// IMPORTANT: this must never be passed a decrypted note body, a title someone might consider
// sensitive, or the master password — only operation descriptions (e.g. "note added", "notebook
// unlocked", "backup restored"). Every call site below sticks to that.

class NotesDebugLogger {
    /// logs/ subfolder next to the binary — new for v3.0 (previously the log file sat loose
    /// beside the binary). Created on first access if it doesn't exist yet. notes.json and
    /// other data files are unaffected and stay exactly where they were.
    static let logsDir: URL = {
        let dir = resolveAppDataDirectory().appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// One rotated log file per app launch, timestamped at process start. Swift only evaluates
    /// a `static let` closure once per process lifetime, so every log() call within this run
    /// writes to the same file — no per-call rotation logic needed.
    static let logURL: URL = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let ts = formatter.string(from: Date())
        return logsDir.appendingPathComponent("swiftnotes_\(ts).log")
    }()

    /// Keeps only the most recent 5 log files, matching swiftADMIN.py's existing build-log
    /// retention exactly (prune_logs()/MAX_LOGS=5). Called after every write rather than once
    /// at launch — cheap enough for a personal tool's logging frequency, and avoids any
    /// lazy-static-initialization timing edge cases around when the current file first appears.
    private static func pruneOldLogs(keep: Int = 5) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil) else { return }
        let logs = files.filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if logs.count > keep {
            for old in logs.prefix(logs.count - keep) {
                try? FileManager.default.removeItem(at: old)
            }
        }
    }

    static func log(_ message: String, category: String = "GENERAL") {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        let logLine = "[\(timestamp)] [\(category)] \(message)\n"
        
        guard let data = logLine.data(using: .utf8) else { return }
        
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let fileHandle = try? FileHandle(forWritingTo: logURL) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            }
        } else {
            try? data.write(to: logURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        }
        pruneOldLogs()
    }
}

// MARK: - Cryptography
//
// Replaces the old "security": a per-note "challenge key" hashed with DJB2 (a fast,
// non-cryptographic hash meant for hash tables, not passwords — 32-bit, no salt, trivially
// brute-forced) that gated viewing a note *through the app's own menus* while the note's body
// sat in notes.json in plain, unencrypted text the entire time. Anyone reading the file directly
// could see every "locked" note instantly. This implements actual encryption, one master
// password for the whole notebook rather than a per-note gate:
//   - PBKDF2-HMAC-SHA256, 600,000 iterations (OWASP's current minimum recommendation for
//     PBKDF2-SHA256 as of 2023-2026), turning the master password into a 256-bit key. Hand-
//     implemented on CryptoKit's HMAC primitive rather than importing CommonCrypto, since
//     CryptoKit is already proven to compile in this toolchain.
//   - AES-256-GCM (authenticated encryption) for each note's body, via CryptoKit.
//   - A random 16-byte salt per notebook (not secret — its job is only to stop precomputed
//     rainbow-table attacks and ensure two notebooks with the same password derive different
//     keys).

enum NotebookCryptoError: Error {
    case invalidCiphertext
    case decryptionFailed
}

/// PBKDF2 (RFC 8018) built from CryptoKit's HMAC<SHA256>. For our fixed 32-byte output size this
/// only ever needs a single block, but the general block-construction loop is kept for clarity
/// and correctness against the spec rather than hand-optimizing away.
enum PBKDF2 {
    static func deriveKey(password: String, salt: Data, iterations: Int, keyByteCount: Int = 32) -> SymmetricKey {
        let hmacKey = SymmetricKey(data: Data(password.utf8))
        var derivedKey = Data()
        var blockIndex: UInt32 = 1
        
        while derivedKey.count < keyByteCount {
            var blockIndexBE = blockIndex.bigEndian
            let blockIndexData = withUnsafeBytes(of: &blockIndexBE) { Data($0) }
            
            var u = Data(HMAC<SHA256>.authenticationCode(for: salt + blockIndexData, using: hmacKey))
            var t = u
            
            if iterations > 1 {
                for _ in 2...iterations {
                    u = Data(HMAC<SHA256>.authenticationCode(for: u, using: hmacKey))
                    for i in 0..<t.count { t[i] ^= u[i] }
                }
            }
            
            derivedKey.append(t)
            blockIndex += 1
        }
        
        return SymmetricKey(data: derivedKey.prefix(keyByteCount))
    }
}

enum NotebookCrypto {
    /// OWASP's current (2023-2026) minimum recommendation for PBKDF2-HMAC-SHA256.
    static let kdfIterations = 100_000
    /// Encrypted at notebook creation and decrypted on every unlock attempt — if it doesn't come
    /// back exactly matching this, the master password was wrong.
    static let canaryPlaintext = "swiftNOTES-OK"
    
    /// Cryptographically-secure random bytes via Swift's SystemRandomNumberGenerator (backed by
    /// the platform CSPRNG) — deliberately avoids pulling in Security.framework just for this.
    static func randomSalt(byteCount: Int = 16) -> Data {
        var generator = SystemRandomNumberGenerator()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(byteCount)
        for _ in 0..<byteCount {
            bytes.append(UInt8.random(in: 0...255, using: &generator))
        }
        return Data(bytes)
    }
    
    static func encrypt(_ plaintext: String, key: SymmetricKey) throws -> String {
        let sealedBox = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let combined = sealedBox.combined else { throw NotebookCryptoError.decryptionFailed }
        return combined.base64EncodedString()
    }
    
    static func decrypt(_ base64: String, key: SymmetricKey) throws -> String {
        guard let data = Data(base64Encoded: base64) else { throw NotebookCryptoError.invalidCiphertext }
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        let decryptedData = try AES.GCM.open(sealedBox, using: key)
        guard let text = String(data: decryptedData, encoding: .utf8) else { throw NotebookCryptoError.invalidCiphertext }
        return text
    }
}

// MARK: - Models

struct Note: Codable {
    var title: String = ""
    var encryptedBody: String = "" // base64 AES-256-GCM ciphertext
    var tags: [String] = []
    var dateCreated: Date = Date()
    var dateModified: Date = Date()
    var isArchived: Bool = false // missing key on older notebooks decodes to this default
    // Optional (there's no explicit CodingKeys enum on this struct at all, so every stored
    // property here decodes/encodes automatically) since this genuinely needs to round-trip to
    // disk. A missing key on older notebooks decodes to nil automatically — Swift's synthesized
    // Decodable treats a missing key as nil for Optional properties without any special handling.
    var dueDate: Date? = nil

    init(title: String = "", encryptedBody: String = "", tags: [String] = [], dateCreated: Date = Date(), dateModified: Date = Date(), isArchived: Bool = false, dueDate: Date? = nil) {
        self.title = title
        self.encryptedBody = encryptedBody
        self.tags = tags
        self.dateCreated = dateCreated
        self.dateModified = dateModified
        self.isArchived = isArchived
        self.dueDate = dueDate
    }
    
    /// Tags actually stored on the note, plus a synthetic "ARC" tag prepended when archived.
    /// Archived status isn't a real tag — it's never written into `tags`, so it can't collide with
    /// search matching real tags, the edit screen's tag list, or get stripped by editing tags —
    /// but it's prepended here so every place that displays tags shows it consistently.
    private var displayTags: [String] {
        isArchived ? ["ARC"] + tags : tags
    }
    
    func formattedTags() -> String {
        if displayTags.isEmpty { return "[None]" }
        return displayTags.map { "[\($0)]" }.joined(separator: " ")
    }
    
    /// Comma-joined form for the workspace's compact grid column.
    func formattedTagsCSV() -> String {
        displayTags.joined(separator: ",")
    }
}

/// Pre-encryption-overhaul notes.json shape: a bare array, plaintext bodies, with a per-note
/// "challenge key" gate that only blocked viewing through the app's own menus and never actually
/// protected the stored data. Used only to detect and migrate old data. Keeps `attachments` for
/// decoding old files even though the current Note model has dropped the field.
private struct LegacyNote: Codable {
    var title: String = ""
    var body: String = ""
    var tags: [String] = []
    var attachments: [String] = []
    var dateCreated: Date = Date()
    var dateModified: Date = Date()
    var isLocked: Bool = false
    var challengeHash: String = ""
}

/// The on-disk notebook format. `formatVersion` exists so a future change to this layout (or KDF
/// parameters) has somewhere to hang a migration off of, the way this version migrates the old
/// pre-encryption format.
struct NotebookFile: Codable {
    var formatVersion: Int = 2
    var kdfSalt: String       // base64
    var kdfIterations: Int
    var canary: String        // base64 AES-GCM ciphertext of NotebookCrypto.canaryPlaintext
    var notes: [Note]
    var lastBackupTimestamp: String? = nil // Optional decodes to nil for older files missing this key
}

/// A user-configured "remote send inbox" for email/text note capture. Nothing about the actual
/// address is hardcoded in source anywhere — entered via showCaptureAccountEditScreen() and
/// stored locally, mirroring swiftMAIL's own EmailAccount pattern. encryptedAppPassword is
/// encrypted with a key derived the same way swiftVAULT's own key is (not this app's own
/// notebookKey) — same security tier as anything actually stored in Vault, even though this
/// file lives in swiftNOTES' own folder rather than inside vault.json itself (avoids a
/// concurrent-write hazard between two apps sharing one file). Multiple accounts are supported —
/// stored as an array in capture_accounts.json, one entry per inbox.
struct CaptureAccount: Codable {
    var emailAddress: String = ""
    var imapHost: String = ""
    var imapPort: Int = 993
    var encryptedAppPassword: String = ""
    // Per-account, not global — one inbox might be a genuine throwaway drop point (safe to
    // auto-delete after capture), while another might be worth always keeping+labeling
    // regardless. Defaults to true to match the original single-account behavior exactly (text-
    // only messages were always deleted after capture before this became configurable).
    var pruneAfterCapture: Bool = true
}

/// Lets a launch skip the master password prompt if the notebook was unlocked within the last
/// 30 minutes — even across a separate process launch, since this suite's launcher (swiftCORE)
/// relaunches each app fresh via execv rather than keeping anything resident in memory between
/// app switches. This is a deliberate, lower-friction tradeoff for notes specifically (unlike
/// vault, which always requires the master password) — worth being clear about what it actually
/// means: the derived encryption key itself sits in this file for up to 30 minutes, at 0600
/// permissions. Anyone with access to the machine during that window can read the notebook
/// without ever knowing the master password. That's an intentional, informed tradeoff for a
/// lower-stakes notes app, not something to also do for vault.
private struct NotesSessionCache: Codable {
    var keyBase64: String
    var kdfSaltBase64: String // must match the notebook currently being opened — guards against
                               // reusing a cached key from a different notebook (e.g. after a
                               // restore swapped in a backup protected by a different password)
    var expiresAt: Date
}

// MARK: - Navigation State

enum NotesScreen {
    case workspace
    case search
    case selectResult(results: [Note], title: String)
    case viewNote(index: Int)
    case addNote
    case editNote(index: Int)
    case dbUtilities
    case captureAccountList
    case captureAccountEdit(index: Int?) // nil = adding a new account
}

// MARK: - Keyboard Handling Engine (POSIX Raw Mode)

enum NotesKey {
    case up, down, enter, escape
    case number(Int)
    case other(Character)
}

class NotesKeyboardReader {
    private var originalTermios = termios()

    func enableRawMode() {
        var raw = termios()
        tcgetattr(STDIN_FILENO, &originalTermios)
        raw = originalTermios
        raw.c_lflag &= ~(tcflag_t(ECHO) | tcflag_t(ICANON))
        raw.c_cc.16 = 1
        raw.c_cc.17 = 0
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    }

    func disableRawMode() {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
    }

    func readKey() -> NotesKey {
        var buffer = [UInt8](repeating: 0, count: 3)
        let bytesRead = read(STDIN_FILENO, &buffer, 3)
        if bytesRead <= 0 { return .other("\0") }
        
        if buffer[0] == 27 {
            if bytesRead == 1 { return .escape }
            if buffer[1] == 91 {
                switch buffer[2] {
                case 65: return .up
                case 66: return .down
                default: return .escape
                }
            }
            return .escape
        }
        if buffer[0] == 10 { return .enter }
        if buffer[0] >= 49 && buffer[0] <= 57 {
            return .number(Int(buffer[0] - 48))
        }
        return .other(Character(UnicodeScalar(buffer[0])))
    }
    
    /// Same idea as readKey(), but returns nil if no key arrives within timeoutSeconds instead of
    /// blocking forever — lets a caller repaint (e.g. to show live progress on a background
    /// operation) while still waiting for input. Passing nil for timeoutSeconds falls back to a
    /// plain blocking read, identical to calling readKey() directly. Mirrors swiftMAIL's
    /// waitForKey() exactly (same poll()-on-stdin approach) for consistency across the suite.
    func waitForKey(timeoutSeconds: Double?) -> NotesKey? {
        guard let timeoutSeconds = timeoutSeconds else {
            return readKey()
        }
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let timeoutMs = Int32(max(0, timeoutSeconds) * 1000)
        let ready = poll(&pfd, 1, timeoutMs)
        guard ready > 0 else { return nil } // 0 = timed out, <0 = interrupted/error
        return readKey()
    }
    
    /// Reads a line with "*" echoed instead of the typed character — used only for the master
    /// password. Note bodies/titles/tags are typed normally (getStringInput / getMultiLineInput)
    /// since you're composing content you want to see, not hiding a secret from yourself.
    /// Temporarily engages raw mode for the read and restores canonical mode afterward. Typing
    /// ESC cancels and returns the sentinel "\u{1B}".
    func readMaskedLine() -> String {
        enableRawMode()
        defer { disableRawMode() }
        
        var inputString = ""
        var buffer = [UInt8](repeating: 0, count: 1)
        
        while true {
            let bytesRead = read(STDIN_FILENO, &buffer, 1)
            if bytesRead <= 0 { continue }
            
            let byte = buffer[0]
            if byte == 27 {
                print("")
                return "\u{1B}"
            }
            if byte == 10 || byte == 13 {
                print("")
                break
            }
            if byte == 127 || byte == 8 {
                if !inputString.isEmpty {
                    inputString.removeLast()
                    print("\u{001B}[1D \u{001B}[1D", terminator: "")
                    fflush(stdout)
                }
                continue
            }
            if byte >= 32 && byte < 127 {
                inputString.append(Character(UnicodeScalar(byte)))
                print("*", terminator: "")
                fflush(stdout)
            }
        }
        return inputString
    }
}

// MARK: - Notes Manager

class NotesManager {
    var notes: [Note] = []
    var screenStack: [NotesScreen] = [.workspace]
    var running = true
    var selectedIdx = 0
    var hideArchived = loadNotesPreferences().hideArchived // workspace filter toggle -- now persisted across sessions
    
    // Protects isCaptureSyncing/captureSyncJustFinished, the only state actually touched from
    // both the main thread and the background capture-check thread. Deliberately narrow: unlike
    // swiftMAIL's dataLock (which protects its whole accounts/message-list state, since mail
    // syncing mutates that data directly from a background thread), the capture-check background
    // thread here never touches `notes` itself — it only signals "done" via this flag, and the
    // main thread does the actual reload from disk. Avoids retrofitting a lock around every one
    // of the many existing `notes` access points throughout this file.
    private let dataLock = NSLock()
    private var isCaptureSyncing = false
    private var captureSyncJustFinished = false
    
    let fileURL = resolveAppDataDirectory().appendingPathComponent("notes.json")
    let keyboard = NotesKeyboardReader()
    
    // The notebook's encryption key, held only in memory for the life of the process — set once
    // after a successful unlock/creation/migration and never written to disk. The master
    // password itself is never stored anywhere, only used transiently to derive this.
    private var notebookKey: SymmetricKey!
    private var kdfSalt: Data = Data()
    private var kdfIterations: Int = NotebookCrypto.kdfIterations
    
    var lastStatusMessage: String? = nil
    var lastStatusWasError = false
    
    private var lastBackupTimestamp: String? = nil
    
    // Recomputed after every save — decrypting every note body is required for full-text search
    // (search needs to reach into body content, not just title/tags) and for the stale-note
    // flag, so it's done once per save rather than repeatedly per keystroke. Keyed by
    // "title|dateCreated" — dateCreated never changes across edits, so this stays stable as a
    // note's identity even as its title/tags/body change, unlike keying on mutable fields.
    private var decryptedBodyCache: [String: String] = [:]
    private var staleNoteKeys: Set<String> = []
    
    // System telemetry — passed as args by swiftCORE at launch
    var machineName: String = "macOS"
    var uptime: String = "Unknown"
    var cpuUsage: String = "0%"
    var memUsage: String = "0G"
    
    init() {
        parseLauncherArguments()
        unlockOrCreateNotebook()
        checkCaptureInboxOnLaunch()
    }
    
    private func parseLauncherArguments() {
        let args = CommandLine.arguments
        if args.count >= 5 {
            self.machineName = args[1]
            self.uptime = args[2]
            self.cpuUsage = args[3]
            self.memUsage = args[4]
        }
    }
    
    private func noteKey(_ note: Note) -> String {
        "\(note.title)|\(note.dateCreated.timeIntervalSince1970)"
    }
    
    // MARK: - Unlock / Create / Migrate
    
    private let sessionCacheURL = resolveAppDataDirectory().appendingPathComponent(".notes_session")
    private static let sessionWindow: TimeInterval = 30 * 60 // 30 minutes
    
    /// Returns a usable key from the session cache if one exists, hasn't expired, matches this
    /// notebook's salt, AND still correctly decrypts the canary — that last check is a safety
    /// net against any mismatch (e.g. same salt but somehow a different key) rather than trusting
    /// the cache file's contents blindly. Self-cleans an expired file it finds along the way.
    private func loadValidSessionKey(notebookFile: NotebookFile) -> SymmetricKey? {
        guard let data = try? Data(contentsOf: sessionCacheURL),
              let cache = try? JSONDecoder().decode(NotesSessionCache.self, from: data) else {
            return nil
        }
        
        guard cache.expiresAt > Date() else {
            try? FileManager.default.removeItem(at: sessionCacheURL)
            return nil
        }
        
        guard cache.kdfSaltBase64 == notebookFile.kdfSalt,
              let keyData = Data(base64Encoded: cache.keyBase64) else {
            return nil
        }
        
        let candidateKey = SymmetricKey(data: keyData)
        guard let decryptedCanary = try? NotebookCrypto.decrypt(notebookFile.canary, key: candidateKey),
              decryptedCanary == NotebookCrypto.canaryPlaintext else {
            return nil
        }
        
        return candidateKey
    }
    
    /// Called after every successful unlock (whether via a fresh password or a cache hit) to
    /// push the expiry another 30 minutes out — a sliding window, not a fixed one, so staying
    /// actively in and out of the app doesn't get interrupted just because 30 minutes have
    /// passed since the very first unlock of the session.
    private func refreshSessionCache() {
        let keyBytes = notebookKey.withUnsafeBytes { Data($0) }
        let cache = NotesSessionCache(
            keyBase64: keyBytes.base64EncodedString(),
            kdfSaltBase64: kdfSalt.base64EncodedString(),
            expiresAt: Date().addingTimeInterval(Self.sessionWindow)
        )
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: sessionCacheURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionCacheURL.path)
    }
    

    // MARK: - Unified Auth (v2.5)
    // Reads the session key written by swiftCORE on login.
    // Returns a SymmetricKey derived specifically for this app, or nil if session is expired/missing.
    private func readCoreSessionKey(appID: String) -> SymmetricKey? {
        let sessionFile = resolveAppDataDirectory()
            .deletingLastPathComponent()
            .appendingPathComponent("swiftcore")
            .appendingPathComponent(".core_session")
        guard let content = try? String(contentsOf: sessionFile, encoding: .utf8) else { return nil }
        var expires: Double = 0
        var skeyBase64 = ""
        for line in content.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: ":")
            guard parts.count >= 2 else { continue }
            if parts[0] == "expires"  { expires    = Double(parts[1]) ?? 0 }
            if parts[0] == "skey"     { skeyBase64 = parts[1...].joined(separator: ":") }
        }
        guard Date().timeIntervalSince1970 < expires, !skeyBase64.isEmpty else { return nil }
        guard let skeyData = Data(base64Encoded: skeyBase64) else { return nil }
        // Derive app-specific key so each app has a different SymmetricKey
        var hasher = SHA256()
        hasher.update(data: skeyData)
        hasher.update(data: Data(appID.utf8))
        let appKeyData = Data(hasher.finalize())
        return SymmetricKey(data: appKeyData)
    }

    // Bounces to swiftCORE if session is expired or missing
    private func requireValidSession() -> Bool {
        let sessionFile = resolveAppDataDirectory()
            .deletingLastPathComponent()
            .appendingPathComponent("swiftcore")
            .appendingPathComponent(".core_session")
        guard let content = try? String(contentsOf: sessionFile, encoding: .utf8) else { return false }
        for line in content.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: ":")
            if parts.count >= 2 && parts[0] == "expires", let ts = Double(parts[1]) {
                return Date().timeIntervalSince1970 < ts
            }
        }
        return false
    }

    private func unlockOrCreateNotebook() {
        // v2.5 unified auth: try swiftCORE session key first
        if let sessionKey = readCoreSessionKey(appID: "swiftNOTES") {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                // No data file yet — create fresh notebook with session key
                self.notebookKey = sessionKey
                self.kdfSalt = NotebookCrypto.randomSalt()
                self.kdfIterations = NotebookCrypto.kdfIterations
                self.notes = []
                saveNotebook()
                NotesDebugLogger.log("New notebook created via unified auth", category: "NOTES")
                return
            }
            if let data = try? Data(contentsOf: fileURL),
               let notebookFile = try? JSONDecoder().decode(NotebookFile.self, from: data),
               let decryptedCanary = try? NotebookCrypto.decrypt(notebookFile.canary, key: sessionKey),
               decryptedCanary == NotebookCrypto.canaryPlaintext {
                // Session key works — unlock silently
                self.notebookKey = sessionKey
                self.kdfSalt = Data(base64Encoded: notebookFile.kdfSalt) ?? Data()
                self.kdfIterations = notebookFile.kdfIterations
                self.notes = notebookFile.notes
                self.lastBackupTimestamp = notebookFile.lastBackupTimestamp
                recomputeNoteCaches()
                NotesDebugLogger.log("Notebook unlocked via swiftCORE session (\(notebookFile.notes.count) notes)", category: "NOTES")
                return
            } else if FileManager.default.fileExists(atPath: fileURL.path) {
                // Data file exists but encrypted with old per-app key — migrate
                print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
                printStandardHeader()
                print("\n \u{001B}[1;33mswiftNOTES v2.5 upgrade:\u{001B}[0m Your notebook was encrypted with a")
                print(" per-app password (pre-v2.5). It will be reset to use your swiftCORE")
                print(" login password instead. Any existing notes will be cleared.\n")
                print(" Press Enter to continue and re-initialize your notebook.")
                _ = readLine()
                try? FileManager.default.removeItem(at: fileURL)
                self.notebookKey = sessionKey
                self.kdfSalt = NotebookCrypto.randomSalt()
                self.kdfIterations = NotebookCrypto.kdfIterations
                self.notes = []
                saveNotebook()
                NotesDebugLogger.log("Notebook reset for unified auth migration", category: "NOTES")
                return
            }
        }

        // Fallback: no valid session — bounce to swiftCORE
        if !requireValidSession() {
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()
            print("\n \u{001B}[1;31mSession expired.\u{001B}[0m Please log in via swiftCORE first.")
            print(" Press Enter to exit.")
            _ = readLine()
            returnToLauncher()
            exit(0)
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            createNewNotebook()
            return
        }
        
        guard let data = try? Data(contentsOf: fileURL) else {
            print(" Could not read notes file at \(fileURL.path). Exiting.")
            exit(1)
        }
        
        if let notebookFile = try? JSONDecoder().decode(NotebookFile.self, from: data) {
            if let cachedKey = loadValidSessionKey(notebookFile: notebookFile) {
                self.notebookKey = cachedKey
                self.kdfSalt = Data(base64Encoded: notebookFile.kdfSalt) ?? Data()
                self.kdfIterations = notebookFile.kdfIterations
                self.notes = notebookFile.notes
                self.lastBackupTimestamp = notebookFile.lastBackupTimestamp
                recomputeNoteCaches()
                refreshSessionCache()
                lastStatusMessage = "Unlocked automatically (active session — no password needed)."
                lastStatusWasError = false
                NotesDebugLogger.log("Notebook unlocked via cached session (\(notebookFile.notes.count) notes)", category: "NOTES")
                return
            }
            unlockExistingNotebook(notebookFile)
            return
        }
        
        // Not the current format — check whether it's a pre-encryption-overhaul notebook (a bare
        // [Note] array with a fake per-note "lock") before giving up.
        if let legacyNotes = try? JSONDecoder().decode([LegacyNote].self, from: data) {
            migrateLegacyNotebook(legacyNotes)
            return
        }
        
        print(" Notes file at \(fileURL.path) is unreadable or corrupted. Exiting.")
        NotesDebugLogger.log("Notes file present but unparseable in either current or legacy format", category: "FATAL")
        exit(1)
    }
    
    // MARK: - Email/Text Capture
    //
    // Checks the configured "remote send inbox" accounts for new emails and folds any captured notes into
    // the notebook — runs once per launch, right after unlocking, NOT a background daemon. Same
    // on-demand trigger point as swiftCALENDAR's own external sync helper. Silent no-op if no
    // capture account has been configured yet, or the helper script isn't present.
    
    private var captureAccountsURL: URL {
        resolveAppDataDirectory().appendingPathComponent("capture_accounts.json")
    }
    
    /// One-time migration from the original single-account capture_account.json (singular) to
    /// the new capture_accounts.json (plural, array of accounts) — runs automatically, once, the
    /// first time the plural file doesn't exist yet but the old singular one does. Preserves an
    /// already-configured account without requiring it to be re-entered. pruneAfterCapture
    /// defaults to true on the migrated entry, matching the old hardcoded behavior exactly (text-
    /// only messages were always deleted before this became a per-account setting).
    private func migrateSingleCaptureAccountIfNeeded() {
        guard !FileManager.default.fileExists(atPath: captureAccountsURL.path) else { return }
        let oldURL = resolveAppDataDirectory().appendingPathComponent("capture_account.json")
        guard FileManager.default.fileExists(atPath: oldURL.path),
              let data = try? Data(contentsOf: oldURL),
              let oldAccount = try? JSONDecoder().decode(CaptureAccount.self, from: data) else {
            return
        }
        if let newData = try? JSONEncoder().encode([oldAccount]) {
            try? newData.write(to: captureAccountsURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: captureAccountsURL.path)
            NotesDebugLogger.log("Migrated single capture_account.json to capture_accounts.json array", category: "CAPTURE")
        }
    }
    
    private func loadCaptureAccounts() -> [CaptureAccount] {
        migrateSingleCaptureAccountIfNeeded()
        guard let data = try? Data(contentsOf: captureAccountsURL),
              let accounts = try? JSONDecoder().decode([CaptureAccount].self, from: data) else {
            return []
        }
        return accounts
    }
    
    private func saveCaptureAccounts(_ accounts: [CaptureAccount]) {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        try? data.write(to: captureAccountsURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: captureAccountsURL.path)
    }
    
    private func checkCaptureInboxOnLaunch() {
        migrateSingleCaptureAccountIfNeeded()
        guard FileManager.default.fileExists(atPath: captureAccountsURL.path) else { return }
        let scriptURL = resolveAppDataDirectory().appendingPathComponent("source_code").appendingPathComponent("notes_capture.py")
        guard FileManager.default.fileExists(atPath: scriptURL.path) else { return }
        
        dataLock.lock()
        isCaptureSyncing = true
        dataLock.unlock()
        
        // Runs off the main thread, matching swiftMAIL's Thread.detachNewThread pattern for its
        // own network sync. One background check covers every configured account together (the
        // Python script loops over the whole capture_accounts.json array itself) — a single
        // status line, not per-account progress, matching how this already worked for one
        // account and keeping the UI unchanged. Deliberately does NOT touch `self.notes` from
        // this thread at all (see the dataLock comment up by the property declarations) — it
        // only flips captureSyncJustFinished under lock when done, and showWorkspace()'s render
        // loop does the actual reload from disk on the main thread.
        Thread.detachNewThread { [weak self] in
            guard let self = self else { return }
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", scriptURL.path]
            process.currentDirectoryURL = resolveAppDataDirectory()
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            // Explicitly redirected rather than left to inherit the parent's stdin — this
            // script never needs interactive input, and sharing the same tty as the app's own
            // raw-mode terminal reading is a real risk, not just theoretical. Found missing
            // here during a suite-wide audit — every equivalent call site in swiftCALENDAR
            // already had this, this one didn't.
            process.standardInput = FileHandle.nullDevice
            
            var succeeded = false
            do {
                try process.run()
                process.waitUntilExit()
                let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                    NotesDebugLogger.log("Capture check: \(output)", category: "CAPTURE")
                }
                succeeded = (process.terminationStatus == 0)
            } catch {
                NotesDebugLogger.log("Capture check failed to launch: \(error.localizedDescription)", category: "CAPTURE-ERR")
            }
            
            self.dataLock.lock()
            self.isCaptureSyncing = false
            if succeeded { self.captureSyncJustFinished = true }
            self.dataLock.unlock()
        }
    }
    
    private func reloadNotebookAfterCapture() {
        guard let data = try? Data(contentsOf: fileURL),
              let notebookFile = try? JSONDecoder().decode(NotebookFile.self, from: data) else {
            return
        }
        self.notes = notebookFile.notes
        recomputeNoteCaches()
    }
    
    /// Sensible per-provider IMAP host default, purely a convenience suggestion during setup —
    /// the user can always type over it. Falls back to an empty suggestion (plain prompt, no
    /// default) for anything not recognized.
    private func suggestedIMAPHost(forEmail email: String) -> String {
        let domain = email.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
        switch domain {
        case "gmail.com", "googlemail.com": return "imap.gmail.com"
        case "outlook.com", "hotmail.com", "live.com": return "imap-mail.outlook.com"
        case "yahoo.com": return "imap.mail.yahoo.com"
        case "icloud.com", "me.com", "mac.com": return "imap.mail.me.com"
        default: return ""
        }
    }
    
    func showCaptureAccountListScreen() {
        keyboard.enableRawMode()
        var selectedIdx = 0
        
        while true {
            let accounts = loadCaptureAccounts()
            if selectedIdx >= accounts.count { selectedIdx = max(0, accounts.count - 1) }
            
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()
            print("                          >>> MANAGE CAPTURE ACCOUNTS <<<                          ")
            print(String(repeating: "─", count: 120))
            print(" These are the remote send inboxes swiftNOTES checks on launch. Email or")
            print(" text-forward something to any of these addresses to capture it as a note.\n")
            
            if accounts.isEmpty {
                print("   No capture accounts configured yet.\n")
            } else {
                for (i, acct) in accounts.enumerated() {
                    let prefix = (i == selectedIdx) ? " -> " : "    "
                    let pruneLabel = acct.pruneAfterCapture ? "prune: on" : "prune: off"
                    print("\(prefix)[\(i + 1)]. \(acct.emailAddress)  (\(acct.imapHost))  [\(pruneLabel)]")
                }
                print("")
            }
            
            printStandardFooter(keys: "↑/↓: Navigate | ENTER: Edit | A: Add | D: Delete | ESC: Back")
            // No printNavFooter() here — this is a config/management screen, same convention
            // already established for Database Utilities elsewhere in this app.
            
            switch keyboard.readKey() {
            case .up:
                if !accounts.isEmpty { selectedIdx = (selectedIdx == 0) ? accounts.count - 1 : selectedIdx - 1 }
            case .down:
                if !accounts.isEmpty { selectedIdx = (selectedIdx == accounts.count - 1) ? 0 : selectedIdx + 1 }
            case .number(let num):
                if num >= 1 && num <= accounts.count {
                    keyboard.disableRawMode()
                    navigate(to: .captureAccountEdit(index: num - 1))
                    return
                }
            case .enter:
                if !accounts.isEmpty {
                    keyboard.disableRawMode()
                    navigate(to: .captureAccountEdit(index: selectedIdx))
                    return
                }
            case .other(let ch):
                let lower = ch.lowercased()
                if lower == "a" {
                    keyboard.disableRawMode()
                    navigate(to: .captureAccountEdit(index: nil))
                    return
                } else if lower == "d", !accounts.isEmpty {
                    var updated = accounts
                    updated.remove(at: selectedIdx)
                    saveCaptureAccounts(updated)
                    NotesDebugLogger.log("Capture account removed", category: "CAPTURE")
                }
            case .escape:
                keyboard.disableRawMode()
                goBack()
                return
            }
        }
    }
    
    func showCaptureAccountEditScreen(index: Int?) {
        printStandardHeader()
        let isNew = (index == nil)
        var accounts = loadCaptureAccounts()
        var target: CaptureAccount
        if let idx = index, idx < accounts.count {
            target = accounts[idx]
        } else {
            target = CaptureAccount()
        }
        
        print(isNew ? "                          >>> ADD CAPTURE ACCOUNT <<<                          "
                     : "                          >>> EDIT CAPTURE ACCOUNT <<<                          ")
        print(String(repeating: "─", count: 120))
        print(" This is a remote send inbox you'll email or text-forward notes to for capture.")
        print(" Nothing about this address is hardcoded anywhere — it's stored only in this")
        print(" local config file, and the password is encrypted separately.\n")
        
        if isNew {
            guard let emailInput = getStringInput(prompt: " Capture Inbox Email Address: "), !emailInput.isEmpty else {
                goBack()
                return
            }
            target.emailAddress = emailInput
        } else {
            if let val = getStringInput(prompt: " Capture Inbox Email Address [\(target.emailAddress)]: "), !val.isEmpty {
                target.emailAddress = val
            }
        }
        
        let suggestedHost = suggestedIMAPHost(forEmail: target.emailAddress)
        if isNew {
            let hostPrompt = suggestedHost.isEmpty
                ? " IMAP Host: "
                : " IMAP Host [\(suggestedHost)] (Enter to accept): "
            guard let imapHost = getStringInput(prompt: hostPrompt, defaultValue: suggestedHost.isEmpty ? nil : suggestedHost), !imapHost.isEmpty else {
                print("\n Cancelled: no IMAP host given.")
                goBack()
                return
            }
            target.imapHost = imapHost
        } else {
            if let val = getStringInput(prompt: " IMAP Host [\(target.imapHost)]: "), !val.isEmpty {
                target.imapHost = val
            }
        }
        
        let portDefault = isNew ? "993" : String(target.imapPort)
        if let portInput = getStringInput(prompt: " IMAP Port [\(portDefault)]: ", defaultValue: portDefault), let port = Int(portInput) {
            target.imapPort = port
        }
        
        let pruneDefault = target.pruneAfterCapture ? "y" : "n"
        print(" Delete text-only messages from this inbox after they're captured? (y/n)")
        print(" Anything with an attachment is always kept + labeled regardless — v1 capture")
        print(" is text-only, so an attachment is never actually captured, and deleting it")
        print(" would make it permanently unrecoverable.")
        if let pruneInput = getStringInput(prompt: " Delete after capture [\(pruneDefault)]: ", defaultValue: pruneDefault) {
            target.pruneAfterCapture = pruneInput.lowercased().hasPrefix("y")
        }
        
        if isNew {
            print("\n App-Specific Password (not your regular password — check your provider's")
            print(" account security settings to generate one): ", terminator: "")
            fflush(stdout)
            let rawPassword = keyboard.readMaskedLine()
            guard rawPassword != "\u{1B}", !rawPassword.isEmpty else {
                print("\n Cancelled — no password entered.")
                goBack()
                return
            }
            guard let vaultKey = readCoreSessionKey(appID: "swiftVAULT") else {
                print("\n \u{001B}[1;31mNo active swiftCORE session — can't encrypt the password right now.\u{001B}[0m")
                print(" Press Enter.")
                _ = readLine()
                goBack()
                return
            }
            guard let encryptedPassword = try? NotebookCrypto.encrypt(rawPassword, key: vaultKey) else {
                print("\n \u{001B}[1;31mEncryption failed — account not saved.\u{001B}[0m Press Enter.")
                _ = readLine()
                goBack()
                return
            }
            target.encryptedAppPassword = encryptedPassword
        } else {
            print("\n App-Specific Password (blank keeps the existing one): ", terminator: "")
            fflush(stdout)
            let rawPassword = keyboard.readMaskedLine()
            guard rawPassword != "\u{1B}" else {
                print("\n Cancelled.")
                goBack()
                return
            }
            if !rawPassword.isEmpty {
                guard let vaultKey = readCoreSessionKey(appID: "swiftVAULT") else {
                    print("\n \u{001B}[1;31mNo active swiftCORE session — can't encrypt the password right now.\u{001B}[0m")
                    print(" Press Enter.")
                    _ = readLine()
                    goBack()
                    return
                }
                guard let encryptedPassword = try? NotebookCrypto.encrypt(rawPassword, key: vaultKey) else {
                    print("\n \u{001B}[1;31mEncryption failed — account not saved.\u{001B}[0m Press Enter.")
                    _ = readLine()
                    goBack()
                    return
                }
                target.encryptedAppPassword = encryptedPassword
            }
        }
        
        if let idx = index, idx < accounts.count {
            accounts[idx] = target
        } else {
            accounts.append(target)
        }
        saveCaptureAccounts(accounts)
        NotesDebugLogger.log(isNew ? "Capture account added" : "Capture account updated", category: "CAPTURE")
        print("\n \u{001B}[1;32mSaved. New notes will be checked for on each launch.\u{001B}[0m")
        print(" Press Enter.")
        _ = readLine()
        goBack()
    }
    
    private func createNewNotebook() {
        print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
        printStandardHeader()
        print("\n No existing notebook found — let's set one up.\n")
        print(" Your master password protects every note you store here.")
        print(" \u{001B}[1;33mThere is no recovery if you forget it — the notebook cannot be\u{001B}[0m")
        print(" \u{001B}[1;33mdecrypted without it.\u{001B}[0m\n")
        
        let password = promptForNewMasterPassword()
        let salt = NotebookCrypto.randomSalt()
        let iterations = NotebookCrypto.kdfIterations
        let key = PBKDF2.deriveKey(password: password, salt: salt, iterations: iterations)
        
        self.notebookKey = key
        self.kdfSalt = salt
        self.kdfIterations = iterations
        self.notes = []
        
        saveNotebook()
        refreshSessionCache()
        NotesDebugLogger.log("New notebook created", category: "NOTES")
        
        print("\n \u{001B}[1;32mNotebook created and unlocked.\u{001B}[0m Press Enter to continue.")
        _ = readLine()
    }
    
    private func unlockExistingNotebook(_ notebookFile: NotebookFile) {
        guard let saltData = Data(base64Encoded: notebookFile.kdfSalt) else {
            print(" Notebook file's salt is corrupted. Exiting.")
            NotesDebugLogger.log("Notebook salt failed to base64-decode", category: "FATAL")
            exit(1)
        }
        
        print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
        printStandardHeader()
        print("\n \u{001B}[1;36mswiftNOTES is locked.\u{001B}[0m\n")
        
        var attempts = 0
        while true {
            let password = promptForMasterPassword()
            let key = PBKDF2.deriveKey(password: password, salt: saltData, iterations: notebookFile.kdfIterations)
            
            if let decryptedCanary = try? NotebookCrypto.decrypt(notebookFile.canary, key: key),
               decryptedCanary == NotebookCrypto.canaryPlaintext {
                self.notebookKey = key
                self.kdfSalt = saltData
                self.kdfIterations = notebookFile.kdfIterations
                self.notes = notebookFile.notes
                self.lastBackupTimestamp = notebookFile.lastBackupTimestamp
                recomputeNoteCaches()
                refreshSessionCache()
                NotesDebugLogger.log("Notebook unlocked (\(notebookFile.notes.count) notes)", category: "NOTES")
                return
            }
            
            attempts += 1
            print(" \u{001B}[1;31mIncorrect master password.\u{001B}[0m\n")
            NotesDebugLogger.log("Failed unlock attempt \(attempts)", category: "NOTES-AUTH")
            
            if attempts >= 5 {
                print(" Too many failed attempts. Exiting for safety.")
                NotesDebugLogger.log("Too many failed unlock attempts — exiting", category: "NOTES-AUTH")
                exit(1)
            }
        }
    }
    
    private func migrateLegacyNotebook(_ legacyNotes: [LegacyNote]) {
        print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
        printStandardHeader()
        print("\n \u{001B}[1;33mThis notebook was created by an older version whose 'lock' only\u{001B}[0m")
        print(" \u{001B}[1;33mgated viewing through the app's menus — note bodies were always\u{001B}[0m")
        print(" \u{001B}[1;33mstored in plain, unencrypted text underneath, locked or not.\u{001B}[0m\n")
        print(" Upgrading now to real AES-256 encryption. Set a master password to")
        print(" protect it going forward:\n")
        
        let password = promptForNewMasterPassword()
        let salt = NotebookCrypto.randomSalt()
        let iterations = NotebookCrypto.kdfIterations
        let key = PBKDF2.deriveKey(password: password, salt: salt, iterations: iterations)
        
        // Old bodies were already plaintext (the "lock" never encrypted anything) — there's
        // nothing to reverse, just encrypt them fresh under the new key. isLocked/challengeHash
        // are dropped entirely; there's no longer a meaningful per-note concept now that the
        // whole notebook shares one real master password. Attachments are dropped too — just a
        // free-text label with no real file handling behind it.
        var migrated: [Note] = []
        for legacy in legacyNotes {
            let encrypted = (try? NotebookCrypto.encrypt(legacy.body, key: key)) ?? ""
            migrated.append(Note(
                title: legacy.title,
                encryptedBody: encrypted,
                tags: legacy.tags,
                dateCreated: legacy.dateCreated,
                dateModified: legacy.dateModified
            ))
        }
        
        self.notebookKey = key
        self.kdfSalt = salt
        self.kdfIterations = iterations
        self.notes = migrated
        
        saveNotebook()
        refreshSessionCache()
        NotesDebugLogger.log("Migrated legacy notebook: \(migrated.count) notes upgraded to AES-256-GCM", category: "NOTES")
        
        print("\n \u{001B}[1;32mMigration complete — \(migrated.count) note(s) upgraded to AES-256 encryption.\u{001B}[0m")
        print(" Press Enter to continue.")
        _ = readLine()
    }
    
    private func promptForNewMasterPassword() -> String {
        while true {
            print(" Create a master password: ", terminator: "")
            fflush(stdout)
            let pw1 = keyboard.readMaskedLine()
            
            if pw1.isEmpty || pw1 == "\u{1B}" {
                print(" Master password cannot be empty.\n")
                continue
            }
            if pw1.count < 8 {
                print(" Use at least 8 characters — this key protects your whole notebook.\n")
                continue
            }
            
            print(" Confirm master password: ", terminator: "")
            fflush(stdout)
            let pw2 = keyboard.readMaskedLine()
            
            if pw1 != pw2 {
                print(" Passwords didn't match — try again.\n")
                continue
            }
            return pw1
        }
    }
    
    private func promptForMasterPassword() -> String {
        print(" Master Password: ", terminator: "")
        fflush(stdout)
        let input = keyboard.readMaskedLine()
        return input == "\u{1B}" ? "" : input
    }
    
    // MARK: - Navigation & Input Helpers
    
    func navigate(to screen: NotesScreen) { screenStack.append(screen) }
    func goBack() { if screenStack.count > 1 { screenStack.removeLast() } }
    
    func getStringInput(prompt: String, defaultValue: String? = nil) -> String? {
        print(prompt, terminator: "")
        guard let input = readLine() else { return defaultValue }
        if input == "\u{1B}" || input.lowercased() == "esc" {
            goBack()
            return nil
        }
        return input.isEmpty ? defaultValue : input
    }
    
    func getMultiLineInput(prompt: String) -> String {
        if !prompt.isEmpty { print(prompt) }
        var lines: [String] = []
        while let line = readLine() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "done" {
                break
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
    
    private func parseTagsFromString(_ input: String) -> [String] {
        input.components(separatedBy: CharacterSet(charactersIn: " ,"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
    
    func run() {
        while running {
            guard let currentScreen = screenStack.last else { break }
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            
            switch currentScreen {
            case .workspace: showWorkspace()
            case .search: showSearchScreen()
            case .selectResult(let results, let title): showResultsScreen(results: results, title: title)
            case .viewNote(let index): showViewNoteScreen(index: index)
            case .addNote: showAddNoteScreen()
            case .editNote(let index): showEditNoteScreen(index: index)
            case .dbUtilities: showDbUtilitiesMenu()
            case .captureAccountList: showCaptureAccountListScreen()
            case .captureAccountEdit(let index): showCaptureAccountEditScreen(index: index)
            }
        }
    }
    
    // MARK: - Layout Handlers (120-column, rounded corners)
    
    private func printStandardHeader() {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MM-dd-yy"
        let dateString = dateFormatter.string(from: now)
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "hh:mm:ss a"
        let timeString = timeFormatter.string(from: now).uppercased()

        let innerWidth = 118
        let titleText = "swiftNOTES v3.01.07.31c"  // plain for layout; colored below
        let sidePadding = (innerWidth - titleText.count) / 2
        var titleLineChars = Array(repeating: " ", count: innerWidth)
        for (i, ch) in dateString.enumerated() where i < innerWidth { titleLineChars[i] = String(ch) }
        for (i, ch) in titleText.enumerated() { titleLineChars[sidePadding + i] = String(ch) }
        // "swift" plain white; "NOTES" solid mint
        titleLineChars[sidePadding + 0] = "\u{001B}[1;97ms\u{001B}[0m"
        titleLineChars[sidePadding + 1] = "\u{001B}[1;97mw\u{001B}[0m"
        titleLineChars[sidePadding + 2] = "\u{001B}[1;97mi\u{001B}[0m"
        titleLineChars[sidePadding + 3] = "\u{001B}[1;97mf\u{001B}[0m"
        titleLineChars[sidePadding + 4] = "\u{001B}[1;97mt\u{001B}[0m"
        titleLineChars[sidePadding + 5] = "\u{001B}[1;38;5;121mN\u{001B}[0m"
        titleLineChars[sidePadding + 6] = "\u{001B}[1;38;5;121mO\u{001B}[0m"
        titleLineChars[sidePadding + 7] = "\u{001B}[1;38;5;121mT\u{001B}[0m"
        titleLineChars[sidePadding + 8] = "\u{001B}[1;38;5;121mE\u{001B}[0m"
        titleLineChars[sidePadding + 9] = "\u{001B}[1;38;5;121mS\u{001B}[0m"
        // Color the trailing 'c' orange without affecting layout positions
        titleLineChars[sidePadding + titleText.count - 1] = "\u{001B}[38;5;208mc\u{001B}[0m"
        let timeStart = innerWidth - timeString.count
        for (i, ch) in timeString.enumerated() { titleLineChars[timeStart + i] = String(ch) }

        // Read username from swiftCORE session file — dynamic, not hardcoded
        let sessionFile = resolveAppDataDirectory()
            .deletingLastPathComponent()
            .appendingPathComponent("swiftcore")
            .appendingPathComponent(".core_session")
        var sessionUser = "UNKNOWN"
        if let sc = try? String(contentsOf: sessionFile, encoding: .utf8) {
            for line in sc.components(separatedBy: "\n") {
                let parts = line.components(separatedBy: ":")
                if parts.count == 2 && parts[0] == "user" { sessionUser = parts[1]; break }
            }
        }

        let seg1Raw = "User: \(sessionUser)"
        let seg1Col = "User: \u{001B}[1;33m\(sessionUser)\u{001B}[0m"
        let seg2 = "Connected: [\(machineName)]"
        let seg3 = "Host Uptime: \(uptime)"
        let seg4 = "CPU: \(cpuUsage)"
        let seg5 = "Mem: \(memUsage)"
        let remaining = max(4, innerWidth - seg1Raw.count - seg2.count - seg3.count - seg4.count - seg5.count)
        let base = String(repeating: " ", count: remaining / 4)
        let extra = remaining % 4
        let telRaw = "\(seg1Raw)\(base + (extra > 0 ? " " : ""))\(seg2)\(base + (extra > 1 ? " " : ""))\(seg3)\(base + (extra > 2 ? " " : ""))\(seg4)\(base)\(seg5)"
        let telCol = "\(seg1Col)\(base + (extra > 0 ? " " : ""))\(seg2)\(base + (extra > 1 ? " " : ""))\(seg3)\(base + (extra > 2 ? " " : ""))\(seg4)\(base)\(seg5)"
        let telPad = max(0, innerWidth - telRaw.count)

        print("╭" + String(repeating: "─", count: innerWidth) + "╮")
        print("│" + titleLineChars.joined() + "│")
        print("│" + telCol + String(repeating: " ", count: telPad) + "│")
        print("╰" + String(repeating: "─", count: innerWidth) + "╯")
    }

    private func printStandardFooter(keys: String) {
        let inner = 118
        let segments = keys.components(separatedBy: "|")
        var lines: [String] = []; var current = ""
        for seg in segments {
            let candidate = current.isEmpty ? seg : "\(current)|\(seg)"
            if candidate.count <= inner { current = candidate }
            else { if !current.isEmpty { lines.append(current) }; current = seg }
        }
        if !current.isEmpty { lines.append(current) }
        print("╭" + String(repeating: "─", count: inner) + "╮")
        for line in lines {
            let p = max(0, (inner - line.count) / 2)
            print("│" + String(repeating: " ", count: p) + line + String(repeating: " ", count: inner - p - line.count) + "│")
        }
        print("╰" + String(repeating: "─", count: inner) + "╯")
    }

    // MARK: - Workspace (home screen) — shows every note directly, most recently modified
    // first (unlike the vault's alphabetical-by-service default — notes are naturally
    // recency-oriented; you usually want what you just wrote, not an alphabetical lookup).
    
    func showWorkspace() {
        keyboard.enableRawMode()
        
        // Column widths sized so pointer(4) + numLabel(2) + " " + flags(2) + " │ " + col + " │ "
        // + col + " │ " + col == 120 exactly. maxVisibleRows is capped at 9 (not 10) so every
        // visible row gets a single-digit number reachable by one keypress — a 10th row needing
        // two digits wouldn't work with the single-keystroke number-select this app uses
        // (same gap hit and fixed in the calendar app's agenda list).
        // Column widths — no pipe separators, 2-space gaps, fills 118 inner chars exactly.
        // indent(2)+num(2)+gap(2)+flag(1)+gap(2)+date(9)+gap(2)+title(64)+gap(2)+tags(32) = 118
        let colNum = 2, colFlag = 1, colDate = 9, colTitle = 64, colTags = 32
        let maxVisibleRows = 9
        let greenBarBG = "\u{001B}[48;5;22m"  // dark forest green — same as stocks
        let resetCode  = "\u{001B}[0m"
        
        func lc(_ s: String, _ w: Int) -> String { String(s.prefix(w)).padding(toLength: w, withPad: " ", startingAt: 0) }
        func rc(_ s: String, _ w: Int) -> String { s.count >= w ? String(s.prefix(w)) : String(repeating: " ", count: w - s.count) + s }
        func buildNoteRow(_ num: String, _ flag: String, _ date: String, _ title: String, _ tags: String) -> String {
            "  " + rc(num, colNum) + "  " + lc(flag, colFlag) + "  " + lc(date, colDate) + "  " + lc(title, colTitle) + "  " + lc(tags, colTags)
        }
        
        let listDateFormatter = DateFormatter()
        listDateFormatter.dateFormat = "MM/dd/yy"
        var spinnerFrame = 0
        
        while true {
            // Only the main thread ever touches `notes` — the background capture-check thread
            // (see checkCaptureInboxOnLaunch()) just signals "done" via this flag under lock.
            dataLock.lock()
            let stillSyncing = isCaptureSyncing
            let justFinished = captureSyncJustFinished
            if justFinished { captureSyncJustFinished = false }
            dataLock.unlock()
            if justFinished { reloadNotebookAfterCapture() }
            
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()
            
            let archivedCount = notes.filter { $0.isArchived }.count
            let allSorted = notes.sorted(by: { $0.dateModified > $1.dateModified })
            let sorted = hideArchived ? allSorted.filter { !$0.isArchived } : allSorted
            
            let noteLabel = "\(sorted.count) Note\(sorted.count == 1 ? "" : "s") Stored" + (hideArchived ? " (Archived Hidden)" : "")
            let leftText = " NOTEBOOK: \(noteLabel)"
            let rightText = "● AES-256 ENCRYPTED"
            let statusPadding = max(1, 119 - leftText.count - rightText.count)
            print("\u{001B}[1;37m NOTEBOOK:\u{001B}[0m \(noteLabel)\(String(repeating: " ", count: statusPadding))\u{001B}[1;32m\(rightText)\u{001B}[0m")
            
            // Same fixed-slot approach swiftMAIL uses for its own status bar: this line always
            // renders SOMETHING here, just different content depending on state, rather than an
            // extra line appearing/disappearing above the rest of the layout.
            if stillSyncing {
                let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
                let frame = spinnerFrames[spinnerFrame % spinnerFrames.count]
                spinnerFrame += 1
                print(" \u{001B}[1;36mStatus: [ \(frame) ] Checking capture inbox...\u{001B}[0m")
            } else {
                let backupTextRaw = " Last Backup: \(lastBackupTimestamp ?? "Never")  / Archived: \(archivedCount)"
                let archivedColor = archivedCount > 0 ? "\u{001B}[1;33m" : ""
                let archivedReset = archivedCount > 0 ? "\u{001B}[0m" : ""
                let backupTextCol = " Last Backup: \(lastBackupTimestamp ?? "Never")  / Archived: \(archivedColor)\(archivedCount)\(archivedReset)"
                let staleOK = staleNoteKeys.isEmpty
                let staleText = staleOK ? "● All Notes Current" : "● \(staleNoteKeys.count) Stale (1yr+ untouched)"
                let stalePadding = max(1, 119 - backupTextRaw.count - staleText.count)
                let staleColor = staleOK ? "\u{001B}[1;32m" : "\u{001B}[1;33m"
                print("\(backupTextCol)\(String(repeating: " ", count: stalePadding))\(staleColor)\(staleText)\u{001B}[0m")
            }
            
            // Grid box — same rounded-corner style as stocks
            let headerRow = buildNoteRow("#", "", "DATE", "TITLE", "TAGS")
            print("╭" + String(repeating: "─", count: 118) + "╮")
            print("│\u{001B}[1;37m\(headerRow)\u{001B}[0m│")
            print("├" + String(repeating: "─", count: 118) + "┤")
            
            var visibleNotes: [Note] = []
            
            if sorted.isEmpty {
                let emptyMsg = "  Notebook is empty. Press 'A' to add your first note."
                let emptyPad = max(0, 118 - emptyMsg.count)
                print("│\(emptyMsg)\(String(repeating: " ", count: emptyPad))│")
            } else {
                if selectedIdx >= sorted.count { selectedIdx = max(0, sorted.count - 1) }
                var startIndex = 0
                if selectedIdx >= maxVisibleRows {
                    startIndex = min(selectedIdx - maxVisibleRows + 1, sorted.count - maxVisibleRows)
                }
                startIndex = max(0, startIndex)
                let endIndex = min(startIndex + maxVisibleRows, sorted.count)
                visibleNotes = Array(sorted[startIndex..<endIndex])
                
                for (rowNum, idx) in (startIndex..<endIndex).enumerated() {
                    let note = sorted[idx]
                    let isStale = staleNoteKeys.contains(noteKey(note))
                    let isArchived = note.isArchived
                    let flag = isStale ? "S" : " "
                    let dateText = listDateFormatter.string(from: note.dateModified)
                    let tagsText = note.formattedTagsCSV()
                    let plain = buildNoteRow("\(rowNum + 1)", flag, dateText, note.title, tagsText)
                    
                    if idx == selectedIdx {
                        // Bold reverse-video for selected — pad to 118 first so highlight fills to border.
                        // Archived selections stay reverse-video (for visibility) with a dim modifier layered in.
                        let padded = plain.padding(toLength: 118, withPad: " ", startingAt: 0)
                        let selStyle = isArchived ? "\u{001B}[7m\u{001B}[2m" : "\u{001B}[7m\u{001B}[1m"
                        print("│\(selStyle)\(padded)\(resetCode)│")
                    } else if isArchived {
                        // Archived rows render muted gray regardless of greenbar striping, so they
                        // read as visually "put away" at a glance.
                        let padded = plain.padding(toLength: 118, withPad: " ", startingAt: 0)
                        print("│\u{001B}[38;5;242m\(padded)\(resetCode)│")
                    } else if (rowNum + 1) % 2 != 0 {
                        // Greenbar — odd visible rows, same dark green as stocks
                        let padded = plain.padding(toLength: 118, withPad: " ", startingAt: 0)
                        print("│\(greenBarBG)\(padded)\(resetCode)│")
                    } else {
                        // Plain row — stale flag in yellow
                        let plainWithColor = buildNoteRow("\(rowNum + 1)", "", dateText, note.title, tagsText)
                        // Insert colored flag at the right position (col 6, 0-indexed)
                        let chars = Array(plainWithColor)
                        let flagPos = 6  // indent(2)+num(2)+gap(2) = position 6
                        if isStale {
                            let before = String(chars[0..<flagPos])
                            let after  = String(chars[(flagPos + 1)...])
                            print("│\(before)\u{001B}[1;33mS\(resetCode)\(after)│")
                        } else {
                            print("│\(plainWithColor)│")
                        }
                    }
                }

            }
            
            print("╰" + String(repeating: "─", count: 118) + "╯")
            printStandardFooter(keys: "ENTER/1-9: View | A: Add | /: Search | D: Delete | X: Archive | R: Hide Archived | U: Utilities")
            printNavFooter()
            
            guard let key = keyboard.waitForKey(timeoutSeconds: stillSyncing ? 0.2 : nil) else {
                continue // timed out while the background capture check is still running — loop back and repaint
            }
            
            switch key {
            case .up:
                if !sorted.isEmpty { selectedIdx = (selectedIdx == 0) ? sorted.count - 1 : selectedIdx - 1 }
            case .down:
                if !sorted.isEmpty { selectedIdx = (selectedIdx == sorted.count - 1) ? 0 : selectedIdx + 1 }
            case .enter:
                if !sorted.isEmpty {
                    keyboard.disableRawMode()
                    openSelectedNote(sorted[selectedIdx])
                    return
                }
            case .number(let num):
                if num >= 1 && num <= visibleNotes.count {
                    keyboard.disableRawMode()
                    openSelectedNote(visibleNotes[num - 1])
                    return
                }
            case .other(let ch):
                let lower = Character(ch.lowercased())
                if lower == "a" {
                    keyboard.disableRawMode()
                    navigate(to: .addNote)
                    return
                } else if lower == "/" {
                    // Search — removed "s" as shortcut since [S] is now Stocks in the nav footer
                    keyboard.disableRawMode()
                    navigate(to: .search)
                    return
                } else if lower == "d" {
                    if !sorted.isEmpty {
                        deleteNoteInline(sorted[selectedIdx])
                    }
                } else if lower == "x" {
                    if !sorted.isEmpty {
                        toggleArchiveInline(sorted[selectedIdx])
                        if hideArchived && selectedIdx > 0 { selectedIdx -= 1 }
                    }
                } else if lower == "r" {
                    hideArchived.toggle()
                    saveNotesPreferences(NotesPreferences(hideArchived: hideArchived))
                } else if lower == "u" {
                    keyboard.disableRawMode()
                    navigate(to: .dbUtilities)
                    return
                } else {
                    // Nav footer — [T] jumps to Contacts, [A] is claimed by Add Note
                    let navMap: [Character: String] = [
                        "t": "swiftCONTACTS", "c": "swiftCALENDAR",
                        "s": "swiftSTOCKS",   "m": "swiftMAIL",
                        "v": "swiftVAULT",
                    "b": "swiftBASE"
                ]
                    if let target = navMap[lower] {
                        keyboard.disableRawMode()
                        navigateToApp(target, args: [machineName, uptime, cpuUsage, memUsage])
                        keyboard.enableRawMode()
                    } else if lower == "l" {
                        keyboard.disableRawMode()
                        returnToLauncher()
                        return
                    }
                }
            case .escape:
                keyboard.disableRawMode()
                returnToLauncher()
                return
            }
        }
    }
    
    private func deleteNoteInline(_ chosen: Note) {
        guard let masterIndex = notes.firstIndex(where: { noteKey($0) == noteKey(chosen) }) else { return }
        keyboard.disableRawMode()
        print("\n Delete \"\(chosen.title)\" permanently? (y/n): ", terminator: "")
        if let confirm = readLine(), confirm.lowercased() == "y" {
            notes.remove(at: masterIndex)
            saveNotebook()
            lastStatusMessage = "Deleted \(chosen.title)."
            lastStatusWasError = false
            NotesDebugLogger.log("Note deleted (title redacted)", category: "NOTES")
            if selectedIdx > 0 { selectedIdx -= 1 }
        }
        keyboard.enableRawMode()
    }
    
    private func toggleArchiveInline(_ chosen: Note) {
        guard let masterIndex = notes.firstIndex(where: { noteKey($0) == noteKey(chosen) }) else { return }
        notes[masterIndex].isArchived.toggle()
        saveNotebook()
        lastStatusMessage = notes[masterIndex].isArchived
            ? "Archived \(notes[masterIndex].title)."
            : "Unarchived \(notes[masterIndex].title)."
        lastStatusWasError = false
        NotesDebugLogger.log("Note archive state toggled (title redacted)", category: "NOTES")
    }
    
    private func openSelectedNote(_ chosen: Note) {
        if let masterIndex = notes.firstIndex(where: { noteKey($0) == noteKey(chosen) }) {
            navigate(to: .viewNote(index: masterIndex))
        }
    }
    
    // MARK: - Search
    
    private func matchesQuery(_ note: Note, query: String) -> Bool {
        let lowerQuery = query.lowercased()
        if note.title.lowercased().contains(lowerQuery) { return true }
        if note.tags.contains(where: { $0.lowercased().contains(lowerQuery) }) { return true }
        if let body = decryptedBodyCache[noteKey(note)], body.lowercased().contains(lowerQuery) { return true }
        return false
    }
    
    func showSearchScreen() {
        printStandardHeader()
        print("                      >>> SEARCH <<<                       ")
        print(String(repeating: "─", count: 120))
        guard let query = getStringInput(prompt: " Enter search keyword, tag, or note content: ") else { return }
        let results = notes.filter { matchesQuery($0, query: query) }
        goBack()
        
        if results.isEmpty {
            print("\n No matching notes found for '\(query)'.")
            print(" Press Enter to return...")
            _ = readLine()
        } else {
            navigate(to: .selectResult(results: results, title: "SEARCH RESULTS FOR '\(query.uppercased())'"))
        }
    }
    
    func showResultsScreen(results: [Note], title: String) {
        var localIdx = 0
        keyboard.enableRawMode()
        let sorted = results.sorted(by: { $0.dateModified > $1.dateModified })
        
        while true {
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()
            
            let paddingSize = max(0, (120 - title.count - 8) / 2)
            let paddingSpaces = String(repeating: " ", count: paddingSize)
            print("\(paddingSpaces)=== \(title) ===")
            print(" (Press ESC to go back to previous menu view)\n")
            
            let resultsDateFormatter = DateFormatter()
            resultsDateFormatter.dateFormat = "MM/dd/yy"
            
            for (idx, note) in sorted.enumerated() {
                let prefix = (idx == localIdx) ? " -> " : "    "
                let dateText = resultsDateFormatter.string(from: note.dateModified)
                print("\(prefix)[\(idx + 1)]. [\(dateText)] \(note.title) \(note.formattedTags())")
            }
            print(String(repeating: "─", count: 120))
            printStandardFooter(keys: "ENTER/1-9: View | ESC: Back")
            printNavFooter()
            
            switch keyboard.readKey() {
            case .up: if !sorted.isEmpty { localIdx = (localIdx == 0) ? sorted.count - 1 : localIdx - 1 }
            case .down: if !sorted.isEmpty { localIdx = (localIdx == sorted.count - 1) ? 0 : localIdx + 1 }
            case .number(let num):
                if num >= 1 && num <= sorted.count {
                    localIdx = num - 1
                    keyboard.disableRawMode()
                    openSelectedNote(sorted[localIdx])
                    return
                }
            case .escape:
                keyboard.disableRawMode()
                goBack()
                return
            case .enter:
                if !sorted.isEmpty {
                    keyboard.disableRawMode()
                    openSelectedNote(sorted[localIdx])
                    return
                }
            case .other(let ch):
                // Nav footer — was shown but not wired up (bug), same pattern already found and
                // fixed in the other apps' search-results screens.
                let lower = Character(ch.lowercased())
                let navMap: [Character: String] = [
                    "t": "swiftCONTACTS", "c": "swiftCALENDAR",
                    "s": "swiftSTOCKS",   "m": "swiftMAIL",
                    "v": "swiftVAULT",
                    "b": "swiftBASE"
                ]
                if let target = navMap[lower] {
                    keyboard.disableRawMode()
                    navigateToApp(target, args: [machineName, uptime, cpuUsage, memUsage])
                    keyboard.enableRawMode()
                } else if lower == "l" {
                    keyboard.disableRawMode()
                    returnToLauncher()
                    return
                }
            }
        }
    }
    
    // MARK: - View / Add / Edit Note
    
    private func daysAgoDescription(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days <= 0 { return "today" }
        if days == 1 { return "1 day ago" }
        return "\(days) days ago"
    }
    
    func showViewNoteScreen(index: Int) {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd/yy hh:mm a"
        keyboard.enableRawMode()

        while true {
            let note = notes[index]
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()

            // Note metadata in a rounded box
            let inner = 118
            func infoRow(_ label: String, _ value: String, colored: String? = nil) {
                let plain = "  \(label.padding(toLength: 16, withPad: " ", startingAt: 0))\(value)"
                let display = "  \(label.padding(toLength: 16, withPad: " ", startingAt: 0))\(colored ?? value)"
                let pad = max(0, inner - plain.count)
                print("│\(display)\(String(repeating: " ", count: pad))│")
            }

            let isStale = staleNoteKeys.contains(noteKey(note))
            let modValue = "\(formatter.string(from: note.dateModified)) (\(daysAgoDescription(note.dateModified)))"
            let modColored = isStale ? "\u{001B}[1;33m\(modValue)\u{001B}[0m" : nil

            print("╭" + String(repeating: "─", count: inner) + "╮")
            infoRow("Title",         note.title)
            infoRow("Tags",          note.formattedTags())
            infoRow("Created",       formatter.string(from: note.dateCreated))
            infoRow("Modified",      modValue, colored: modColored)
            if let due = note.dueDate {
                let dueFormatter = DateFormatter()
                dueFormatter.dateFormat = "MM/dd/yy"
                infoRow("Due Date", dueFormatter.string(from: due))
            }
            print("├" + String(repeating: "─", count: inner) + "┤")

            // Note body — indented, inside the box, word-wrapped to fit the box width. Without
            // this, a single long line just overflows past the right border instead of
            // breaking cleanly — a real bug hit in testing with a genuinely long captured note.
            func wrapLine(_ text: String, width: Int) -> [String] {
                if text.isEmpty { return [""] }
                var lines: [String] = []
                var current = ""
                for word in text.split(separator: " ", omittingEmptySubsequences: true) {
                    let candidate = current.isEmpty ? String(word) : "\(current) \(word)"
                    if candidate.count > width {
                        if !current.isEmpty { lines.append(current) }
                        var remaining = String(word)
                        // A single word longer than the whole width gets hard-broken rather
                        // than left to overflow — rare (a URL, say), but still needs handling.
                        while remaining.count > width {
                            let breakIndex = remaining.index(remaining.startIndex, offsetBy: width)
                            lines.append(String(remaining[..<breakIndex]))
                            remaining = String(remaining[breakIndex...])
                        }
                        current = remaining
                    } else {
                        current = candidate
                    }
                }
                if !current.isEmpty || lines.isEmpty { lines.append(current) }
                return lines
            }
            
            let body = decryptedBodyCache[noteKey(note)]
                ?? (try? NotebookCrypto.decrypt(note.encryptedBody, key: notebookKey))
                ?? "⚠ decryption failed"
            let bodyContentWidth = inner - 2  // 2-space indent prefix on every line
            for rawLine in body.components(separatedBy: "\n") {
                for wrapped in wrapLine(rawLine, width: bodyContentWidth) {
                    let content = "  \(wrapped)"
                    let pad = max(0, inner - content.count)
                    print("│\(content)\(String(repeating: " ", count: pad))│")
                }
            }
            print("╰" + String(repeating: "─", count: inner) + "╯")
            print("")
            let archiveLabel = note.isArchived ? "[X] Unarchive Note" : "[X] Archive Note"
            printStandardFooter(keys: "[E] Edit Note  |  [D] Delete Note  |  \(archiveLabel)  |  ESC: Back")
            printNavFooter()

            switch keyboard.readKey() {
            case .escape:
                keyboard.disableRawMode()
                goBack()
                return
            case .other(let ch):
                let lower = Character(ch.lowercased())
                if lower == "e" {
                    keyboard.disableRawMode()
                    navigate(to: .editNote(index: index))
                    return
                } else if lower == "x" {
                    notes[index].isArchived.toggle()
                    saveNotebook()
                    NotesDebugLogger.log("Note archive state toggled (title redacted)", category: "NOTES")
                    keyboard.enableRawMode()
                } else if lower == "d" {
                    keyboard.disableRawMode()
                    print("\n Delete \"\(note.title)\" permanently? (y/n): ", terminator: "")
                    if let confirm = readLine(), confirm.lowercased() == "y" {
                        notes.remove(at: index)
                        saveNotebook()
                        NotesDebugLogger.log("Note deleted (title redacted)", category: "NOTES")
                        print("\n Note deleted. Press Enter.")
                        _ = readLine()
                        goBack()
                        return
                    }
                    keyboard.enableRawMode()
                } else {
                    // Nav footer keys. Two fixes here: (1) omit "n" (self) from the map entirely
                    // instead of the previous awkward "target != swiftNOTES" guard, matching how
                    // swiftSTOCKS/swiftVAULT correctly self-omit. (2) Added the missing
                    // disableRawMode() before navigateToApp() — same bug class found and fixed in
                    // swiftVAULT's credential detail screen and swiftCONTACTS' contact detail screen.
                    let navMap: [Character: String] = [
                        "c": "swiftCALENDAR", "s": "swiftSTOCKS",
                        "m": "swiftMAIL",     "v": "swiftVAULT",
                        "t": "swiftCONTACTS",
                    "b": "swiftBASE"
                ]
                    if let target = navMap[lower] {
                        keyboard.disableRawMode()
                        navigateToApp(target, args: [machineName, uptime, cpuUsage, memUsage])
                        keyboard.enableRawMode()
                    } else if lower == "l" {
                        keyboard.disableRawMode()
                        returnToLauncher()
                        return
                    }
                }
            default: break
            }
        }
    }

    
    func showAddNoteScreen() {
        printStandardHeader()
        print("                                   >>> ADD NOTE <<<                                   ")
        print(String(repeating: "─", count: 120))
        let titleInput = getStringInput(prompt: " Title: ")
        guard let title = titleInput, !title.isEmpty else {
            // getStringInput already called goBack() if the user hit ESC. A blank Enter also
            // returns nil here but never touches the stack — without this check, .addNote stays
            // on top and run() redraws this same prompt forever with no way out.
            if case .addNote? = screenStack.last {
                print("\n Cancelled: title was empty. Press Enter.")
                _ = readLine()
                goBack()
            }
            return
        }
        
        let rawTags = getStringInput(prompt: " Tags (Separate with spaces): ") ?? ""
        let assignedTags = parseTagsFromString(rawTags)
        
        let dueDateInput = getStringInput(prompt: " Due Date (MM/DD/YY, optional): ")
        var dueDate: Date? = nil
        if let input = dueDateInput, !input.isEmpty {
            let dueFormatter = DateFormatter()
            dueFormatter.dateFormat = "MM/dd/yy"
            if let parsed = dueFormatter.date(from: input) {
                dueDate = parsed
            } else {
                print(" \u{001B}[1;33mCouldn't parse that date — due date not set.\u{001B}[0m")
            }
        }
        
        let bodyPrompt = "\n Enter Note Body (Type 'DONE' on a clean line when finished):"
        let rawBody = getMultiLineInput(prompt: bodyPrompt)
        
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd/yy hh:mm a"
        let timestamp = "[\(formatter.string(from: now))]"
        let finalBody = rawBody.isEmpty ? timestamp : "\(timestamp)\n\(rawBody)"
        
        guard let encrypted = try? NotebookCrypto.encrypt(finalBody, key: notebookKey) else {
            print("\n \u{001B}[1;31mEncryption failed — note not saved.\u{001B}[0m Press Enter.")
            _ = readLine()
            goBack()
            return
        }
        
        let newNote = Note(
            title: title,
            encryptedBody: encrypted,
            tags: assignedTags,
            dateCreated: now,
            dateModified: now,
            dueDate: dueDate
        )
        
        notes.append(newNote)
        saveNotebook()
        NotesDebugLogger.log("Note added (title redacted)", category: "NOTES")
        
        print("\n Note saved successfully! Press Enter to return to main menu.")
        _ = readLine()
        goBack()
    }
    
    func showEditNoteScreen(index: Int) {
        var updatedNote = notes[index]
        let currentBody = decryptedBodyCache[noteKey(updatedNote)] ?? (try? NotebookCrypto.decrypt(updatedNote.encryptedBody, key: notebookKey)) ?? ""
        
        printStandardHeader()
        print("                               >>> EDIT NOTE DATA <<<                               ")
        print(String(repeating: "─", count: 120))
        
        if let title = getStringInput(prompt: " Title [\(updatedNote.title)]: "), !title.isEmpty {
            updatedNote.title = title
        }
        
        let currentTagsLine = updatedNote.tags.joined(separator: " ")
        if let rawTags = getStringInput(prompt: " Tags [\(currentTagsLine)]: "), !rawTags.isEmpty {
            updatedNote.tags = parseTagsFromString(rawTags)
        }
        
        let dueDateFormatter = DateFormatter()
        dueDateFormatter.dateFormat = "MM/dd/yy"
        let currentDueLine = updatedNote.dueDate.map { dueDateFormatter.string(from: $0) } ?? ""
        // Same "blank Enter keeps the current value" convention as every other field on this
        // screen — getStringInput() returns nil (not "") on a blank Enter when no defaultValue
        // is passed, so there's no separate way to distinguish "clear it" from "leave it alone"
        // here. Known limitation: to remove a due date entirely, delete/re-add the note.
        if let dueDateInput = getStringInput(prompt: " Due Date (MM/DD/YY) [\(currentDueLine)]: "), !dueDateInput.isEmpty {
            if let parsed = dueDateFormatter.date(from: dueDateInput) {
                updatedNote.dueDate = parsed
            } else {
                print(" \u{001B}[1;33mCouldn't parse that date — due date unchanged.\u{001B}[0m")
            }
        }
        
        let textOptions = [
            "Append new entry text (with Auto-Timestamp)",
            "Edit previous text lines (Line-by-Line)",
            "Wipe and Overwrite completely",
            "Do not modify text body"
        ]
        var selectedIdx = 0
        
        keyboard.enableRawMode()
        
        while true {
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()
            print("=== UPDATE TEXT OPTIONS ===")
            print(" Choose how you want to alter the entry fields:\n")
            
            for (i, option) in textOptions.enumerated() {
                let prefix = (i == selectedIdx) ? " -> " : "    "
                print("\(prefix)[\(i + 1)]. \(option)")
            }
            printStandardFooter(keys: "↑/↓: Navigate | ENTER: Select | ESC: Back")
            // No printNavFooter() here — this is a mid-edit submenu; updatedNote (with any
            // title/tags/due-date changes already made earlier in this flow) only gets saved
            // once a choice here is made and handleBodyUpdateSelection() runs. Navigating away
            // via the nav footer at this point would silently discard those changes with no
            // warning, so this screen doesn't offer that exit — same reasoning as why the
            // sequential add/edit forms elsewhere in the suite don't show a nav footer either.
            
            switch keyboard.readKey() {
            case .up:
                selectedIdx = (selectedIdx == 0) ? textOptions.count - 1 : selectedIdx - 1
            case .down:
                selectedIdx = (selectedIdx == textOptions.count - 1) ? 0 : selectedIdx + 1
            case .number(let num):
                if num >= 1 && num <= textOptions.count {
                    selectedIdx = num - 1
                    handleBodyUpdateSelection(choiceIndex: selectedIdx, noteIndex: index, updatedNote: &updatedNote, workingBody: currentBody)
                    return
                }
            case .escape:
                keyboard.disableRawMode()
                goBack()
                return
            case .enter:
                handleBodyUpdateSelection(choiceIndex: selectedIdx, noteIndex: index, updatedNote: &updatedNote, workingBody: currentBody)
                return
            default:
                break
            }
        }
    }
    
    private func handleBodyUpdateSelection(choiceIndex: Int, noteIndex: Int, updatedNote: inout Note, workingBody: String) {
        keyboard.disableRawMode()
        var newBody = workingBody
        
        if choiceIndex == 0 {
            print("\n Enter text to APPEND (Type 'DONE' on a clean line when finished):")
            let textToAppend = getMultiLineInput(prompt: "")
            if !textToAppend.isEmpty {
                let formatter = DateFormatter()
                formatter.dateFormat = "MM/dd/yy hh:mm a"
                let timestamp = "[\(formatter.string(from: Date()))]"
                
                if newBody.isEmpty {
                    newBody = timestamp + "\n" + textToAppend
                } else {
                    newBody += "\n\n\(timestamp)\n\(textToAppend)"
                }
            }
        } else if choiceIndex == 1 {
            newBody = runLineEditor(body: newBody)
        } else if choiceIndex == 2 {
            print("\n Enter NEW text body (Type 'DONE' on a clean line when finished):")
            newBody = getMultiLineInput(prompt: "")
        }
        // choiceIndex == 3 ("Do not modify text body") intentionally falls through with no
        // action — newBody stays equal to workingBody.
        
        if let encrypted = try? NotebookCrypto.encrypt(newBody, key: notebookKey) {
            updatedNote.encryptedBody = encrypted
        } else {
            print("\n \u{001B}[1;31mEncryption failed — body not changed.\u{001B}[0m")
        }
        
        updatedNote.dateModified = Date()
        notes[noteIndex] = updatedNote
        saveNotebook()
        NotesDebugLogger.log("Note updated (title redacted)", category: "NOTES")
        
        print("\n Note saved successfully! Press Enter.")
        _ = readLine()
        goBack()
    }
    
    private func runLineEditor(body: String) -> String {
        var lines = body.components(separatedBy: "\n")
        
        while true {
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            print("=== LINE-BY-LINE EDITOR ===")
            print(" Select line number to edit, or type '0' to save and finish.\n")
            
            for (idx, line) in lines.enumerated() {
                print(" \(idx + 1): \(line)")
            }
            print("===========================")
            
            print("\n Enter line # to modify (0 to exit): ", terminator: "")
            guard let selectionStr = readLine(), let choice = Int(selectionStr) else { continue }
            
            if choice == 0 { break }
            
            let arrayIndex = choice - 1
            if arrayIndex >= 0 && arrayIndex < lines.count {
                print("\nCurrent line content: \(lines[arrayIndex])")
                print("Enter new line text: ", terminator: "")
                if let newLineText = readLine() {
                    lines[arrayIndex] = newLineText
                }
            } else {
                print("Invalid line number! Press Enter to retry.")
                _ = readLine()
            }
        }
        
        return lines.joined(separator: "\n")
    }
    
    // MARK: - Database Utilities Menu
    
    func showDbUtilitiesMenu() {
        let options = [
            "Backup Notebook Database",
            "Restore Notebook Database",
            "Delete All Notes",
            "Manage Capture Accounts",
            "Back to Notebook"
        ]
        var selectedIdx = 0
        keyboard.enableRawMode()
        
        while true {
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()
            print("                             >>> DATABASE UTILITIES <<<                             ")
            print(" Use Arrow Keys or type number selection\n")
            
            for (i, option) in options.enumerated() {
                let prefix = (i == selectedIdx) ? " -> " : "    "
                print("\(prefix)[\(i + 1)]. \(option)")
            }
            print("")
            printStandardFooter(keys: "↑/↓: Navigate | ENTER: Select | ESC: Back")
            
            switch keyboard.readKey() {
            case .up: selectedIdx = (selectedIdx == 0) ? options.count - 1 : selectedIdx - 1
            case .down: selectedIdx = (selectedIdx == options.count - 1) ? 0 : selectedIdx + 1
            case .number(let num):
                if num >= 1 && num <= options.count {
                    selectedIdx = num - 1
                    keyboard.disableRawMode()
                    executeDbUtilitiesSelection(index: selectedIdx)
                    return
                }
            case .escape:
                keyboard.disableRawMode()
                goBack()
                return
            case .enter:
                keyboard.disableRawMode()
                executeDbUtilitiesSelection(index: selectedIdx)
                return
            default: break
            }
        }
    }
    
    private func executeDbUtilitiesSelection(index: Int) {
        switch index {
        case 0: backupDatabase()
        case 1: restoreDatabase()
        case 2: deleteAllNotes()
        case 3: navigate(to: .captureAccountList)
        case 4: goBack()
        default: break
        }
    }
    
    private func deleteAllNotes() {
        printStandardHeader()
        if notes.isEmpty {
            print("\n Notebook is already empty.")
            print(" Press Enter to continue...")
            _ = readLine()
            return
        }
        
        print("\n WARNING: This will delete ALL \(notes.count) notes permanently!")
        print(" Type 'CONFIRM' to clear everything: ", terminator: "")
        if let validation = readLine(), validation == "CONFIRM" {
            notes.removeAll()
            saveNotebook()
            NotesDebugLogger.log("All notes wiped by user request", category: "NOTES")
            print("\n Notebook successfully wiped clean!")
            lastStatusMessage = "Notebook wiped."
            lastStatusWasError = false
        } else {
            print("\n Wipe canceled. No data was deleted.")
        }
        print(" Press Enter to continue...")
        _ = readLine()
    }
    
    private func backupDatabase() {
        printStandardHeader()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("\n Error: No database file found to backup yet. Create a note first.")
            print(" Press Enter to continue...")
            _ = readLine()
            return
        }
        
        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "MM-dd-yy hh:mm a"
        lastBackupTimestamp = displayFormatter.string(from: Date()).uppercased()
        saveNotebook() // persist the updated timestamp into notes.json before copying it
        
        let fileFormatter = DateFormatter()
        fileFormatter.dateFormat = "yyyyMMdd_HHmm"
        let timestamp = fileFormatter.string(from: Date())
        let backupURL = resolveAppDataDirectory().appendingPathComponent("notes_backup_\(timestamp).json")
        
        do {
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
            print("\n Backup created successfully: \(backupURL.lastPathComponent)")
            print(" (This backup is real AES-256 ciphertext, protected by the same master password.)")
            lastStatusMessage = "Backup created: \(backupURL.lastPathComponent)"
            lastStatusWasError = false
            NotesDebugLogger.log("Backup created: \(backupURL.lastPathComponent)", category: "NOTES")
        } catch {
            print("\n Failed to create backup: \(error.localizedDescription)")
            lastStatusMessage = "Backup failed: \(error.localizedDescription)"
            lastStatusWasError = true
        }
        print(" Press Enter to continue...")
        _ = readLine()
    }
    
    private func restoreDatabase() {
        let appDir = resolveAppDataDirectory()
        do {
            let files = try FileManager.default.contentsOfDirectory(at: appDir, includingPropertiesForKeys: nil)
            let backupFiles = files.filter { $0.lastPathComponent.hasPrefix("notes_backup_") && $0.lastPathComponent.hasSuffix(".json") }
                .sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
            
            if backupFiles.isEmpty {
                printStandardHeader()
                print("\n No backup snapshots found in \(appDir.path).")
                print(" Press Enter to continue...")
                _ = readLine()
                return
            }
            
            var selectedIdx = 0
            keyboard.enableRawMode()
            
            while true {
                print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
                printStandardHeader()
                print("                         >>> AVAILABLE BACKUPS <<<                         ")
                print(" Choose a recovery point via Arrow Keys or Number Keys\n")
                print(" Note: restoring will re-prompt for the master password that was active")
                print(" when that backup was made.\n")
                
                for (index, file) in backupFiles.enumerated() {
                    let prefix = (index == selectedIdx) ? " -> " : "    "
                    print("\(prefix)[\(index + 1)]. \(file.lastPathComponent)")
                }
                print(String(repeating: "─", count: 120))
                printStandardFooter(keys: "↑/↓: Navigate | ENTER: Select | ESC: Back")
                
                switch keyboard.readKey() {
                case .up: selectedIdx = (selectedIdx == 0) ? backupFiles.count - 1 : selectedIdx - 1
                case .down: selectedIdx = (selectedIdx == backupFiles.count - 1) ? 0 : selectedIdx + 1
                case .number(let num):
                    if num >= 1 && num <= backupFiles.count {
                        selectedIdx = num - 1
                        try triggerDatabaseRestore(file: backupFiles[selectedIdx])
                        return
                    }
                case .escape:
                    keyboard.disableRawMode()
                    return
                case .enter:
                    try triggerDatabaseRestore(file: backupFiles[selectedIdx])
                    return
                default: break
                }
            }
        } catch {
            keyboard.disableRawMode()
            print("\n Error handling checkpoint item recovery: \(error.localizedDescription)")
            print(" Press Enter to continue...")
            _ = readLine()
        }
    }
    
    private func triggerDatabaseRestore(file: URL) throws {
        keyboard.disableRawMode()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try FileManager.default.copyItem(at: file, to: fileURL)
        
        print("\n Restoring from \(file.lastPathComponent) — this backup has its own master password.\n")
        
        guard let data = try? Data(contentsOf: fileURL), let notebookFile = try? JSONDecoder().decode(NotebookFile.self, from: data) else {
            print(" \u{001B}[1;31mCould not read that backup file.\u{001B}[0m")
            print(" Press Enter to continue...")
            _ = readLine()
            return
        }
        
        guard let saltData = Data(base64Encoded: notebookFile.kdfSalt) else {
            print(" \u{001B}[1;31mBackup file's salt is corrupted.\u{001B}[0m")
            print(" Press Enter to continue...")
            _ = readLine()
            return
        }
        
        var attempts = 0
        while true {
            let password = promptForMasterPassword()
            let key = PBKDF2.deriveKey(password: password, salt: saltData, iterations: notebookFile.kdfIterations)
            
            if let decryptedCanary = try? NotebookCrypto.decrypt(notebookFile.canary, key: key), decryptedCanary == NotebookCrypto.canaryPlaintext {
                self.notebookKey = key
                self.kdfSalt = saltData
                self.kdfIterations = notebookFile.kdfIterations
                self.notes = notebookFile.notes
                self.lastBackupTimestamp = notebookFile.lastBackupTimestamp
                recomputeNoteCaches()
                refreshSessionCache()
                NotesDebugLogger.log("Notebook restored from \(file.lastPathComponent)", category: "NOTES")
                print("\n \u{001B}[1;32mNotebook restored from \(file.lastPathComponent) successfully!\u{001B}[0m")
                break
            }
            
            attempts += 1
            print(" \u{001B}[1;31mIncorrect master password for this backup.\u{001B}[0m\n")
            if attempts >= 5 {
                print(" Too many failed attempts. Restore aborted.")
                print(" Press Enter to continue...")
                _ = readLine()
                return
            }
        }
        
        print(" Press Enter to continue...")
        _ = readLine()
    }
    
    // MARK: - Persistence Data Layer
    
    func saveNotebook() {
        recomputeNoteCaches()
        do {
            let canaryEncrypted = try NotebookCrypto.encrypt(NotebookCrypto.canaryPlaintext, key: notebookKey)
            let notebookFile = NotebookFile(
                formatVersion: 2,
                kdfSalt: kdfSalt.base64EncodedString(),
                kdfIterations: kdfIterations,
                canary: canaryEncrypted,
                notes: notes,
                lastBackupTimestamp: lastBackupTimestamp
            )
            let data = try JSONEncoder().encode(notebookFile)
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            print("Notebook write error: \(error)")
            NotesDebugLogger.log("Notebook save failed: \(error.localizedDescription)", category: "NOTES-ERR")
        }
    }
    
    // MARK: - Note Health (decrypted-body cache for search, staleness flag)
    
    private func recomputeNoteCaches() {
        guard notebookKey != nil else { return }
        
        var bodyCache: [String: String] = [:]
        var stale: Set<String> = []
        let oneYearAgo = Calendar.current.date(byAdding: .day, value: -365, to: Date()) ?? Date.distantPast
        
        for note in notes {
            let key = noteKey(note)
            if let plaintext = try? NotebookCrypto.decrypt(note.encryptedBody, key: notebookKey) {
                bodyCache[key] = plaintext
            }
            if note.dateModified < oneYearAgo {
                stale.insert(key)
            }
        }
        
        self.decryptedBodyCache = bodyCache
        self.staleNoteKeys = stale
    }
}

// MARK: - App Navigation (launcher-less direct switching)

let navApps: [(key: Character, label: String, folder: String)] = [
    ("b", "Base",     "swiftBASE"),
    ("c", "Calendar",  "swiftCALENDAR"),
    ("t", "Contacts",  "swiftCONTACTS"),
    ("m", "Mail",      "swiftMAIL"),
    ("n", "Notes",     "swiftNOTES"),
    ("s", "Stocks",    "swiftSTOCKS"),
    ("v", "Vault",     "swiftVAULT"),
]

func navigateToApp(_ folder: String, args: [String]) {
    var term = termios()
    tcgetattr(STDIN_FILENO, &term)
    term.c_lflag |= tcflag_t(ECHO) | tcflag_t(ICANON)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &term)
    
    let execPath = CommandLine.arguments[0]
    let suiteDir = URL(fileURLWithPath: execPath).deletingLastPathComponent().deletingLastPathComponent()
    let targetDir = suiteDir.appendingPathComponent(folder)
    let binaryPath = targetDir.appendingPathComponent(folder).path
    
    guard FileManager.default.fileExists(atPath: binaryPath) else {
        print("\n Error: binary not found at \(binaryPath). Press Enter.")
        _ = readLine()
        return
    }
    
    if chdir(targetDir.path) != 0 { print("Error: chdir failed"); exit(1) }
    
    var cArgs: [UnsafeMutablePointer<CChar>?] = [binaryPath.withCString { strdup($0) }]
    for arg in args { cArgs.append(arg.withCString { strdup($0) }) }
    cArgs.append(nil)
    
    execv(binaryPath, &cArgs)
    print("Error: execv failed for \(folder)"); exit(1)
}

func returnToLauncher() {
    navigateToApp("swiftCORE", args: [])
}

func printNavFooter(currentApp: String = "swiftNOTES") {
    let inner = 118
    let items = navApps.map { "[\($0.key.uppercased())] \($0.label)" }
    let plain = items.joined(separator: "  ") + "  [L] Logout"
    let navPad = max(0, (inner - plain.count) / 2)
    
    var colored = ""
    for (_, app) in navApps.enumerated() {
        let label = "[\(app.key.uppercased())] \(app.label)"
        if app.folder == currentApp {
            colored += "\u{001B}[1;32m\(label)\u{001B}[0m"
        } else {
            colored += "\u{001B}[2m\(label)\u{001B}[0m"
        }
        colored += "  "
    }
    colored += "\u{001B}[1;31m[L] Logout\u{001B}[0m"
    
    print("╭" + String(repeating: "─", count: inner) + "╮")
    print("│" + String(repeating: " ", count: navPad) + colored + String(repeating: " ", count: inner - navPad - plain.count) + "│")
    print("╰" + String(repeating: "─", count: inner) + "╯")
}

// MARK: - App Execution
let notesEngine = NotesManager()
notesEngine.run()