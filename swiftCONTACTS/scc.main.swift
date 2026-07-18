import Foundation
import CryptoKit

// MARK: - App Storage Location

/// Resolves the directory the compiled binary itself lives in — not the current working
/// directory, which varies by how the app is launched. Kept consistent with the rest of the
/// suite so a folder-sync tool like Syncthing can carry contacts.json between machines if you
/// want that.
func resolveAppDataDirectory() -> URL {
    let executablePath = CommandLine.arguments.first ?? "."
    return URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().deletingLastPathComponent()
}

// MARK: - Debug Logger
//
// IMPORTANT: this must never be passed decrypted contact details or the master password — only
// operation descriptions (e.g. "contact added", "notebook unlocked"). Names are also treated as
// sensitive here and redacted from log messages, even though they're stored in plaintext —
// there's no reason for them to also end up duplicated into a log file.

class ContactsDebugLogger {
    static let logURL: URL = resolveAppDataDirectory().appendingPathComponent("swiftcontacts_debug.log")
    
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
    }
}

// MARK: - Cryptography
//
// The original app stored every field — including address, phone, and date of birth — in
// completely plain, unencrypted JSON. This implements real encryption for the fields that
// actually warrant it:
//   - PBKDF2-HMAC-SHA256, 600,000 iterations (OWASP's current minimum recommendation for
//     PBKDF2-SHA256 as of 2023-2026), turning the master password into a 256-bit key.
//   - AES-256-GCM (authenticated encryption) for a bundled "details" blob per contact, via
//     CryptoKit.
//   - A random 16-byte salt per contact book (not secret — its job is only to stop precomputed
//     rainbow-table attacks).
// Name and email are deliberately left unencrypted (see the Contact model below) so mail's
// autocomplete can read them directly without ever needing this app's master password.

enum ContactsCryptoError: Error {
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

enum ContactsCrypto {
    /// OWASP's current (2023-2026) minimum recommendation for PBKDF2-HMAC-SHA256.
    static let kdfIterations = 100_000
    /// Encrypted at creation and decrypted on every unlock attempt — if it doesn't come back
    /// exactly matching this, the master password was wrong.
    static let canaryPlaintext = "swiftCONTACTS-OK"
    
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
        guard let combined = sealedBox.combined else { throw ContactsCryptoError.decryptionFailed }
        return combined.base64EncodedString()
    }
    
    static func decrypt(_ base64: String, key: SymmetricKey) throws -> String {
        guard let data = Data(base64Encoded: base64) else { throw ContactsCryptoError.invalidCiphertext }
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        let decryptedData = try AES.GCM.open(sealedBox, using: key)
        guard let text = String(data: decryptedData, encoding: .utf8) else { throw ContactsCryptoError.invalidCiphertext }
        return text
    }
}

// MARK: - Models

/// The fields bundled into each contact's encrypted blob — everything except name/email/tags.
struct ContactDetails: Codable {
    var spouseName: String = ""
    var dob: String = ""
    var street: String = ""
    var city: String = ""
    var state: String = ""
    var zip: String = ""
    var phone: String = ""      // personal phone
    var workPhone: String = ""  // work phone
    var website: String = ""
    var twitter: String = ""
    var facebook: String = ""
    var company: String = ""
}

struct Contact: Codable {
    // Deliberately plaintext — this is exactly what mail's autocomplete reads directly from
    // contacts.json without ever needing this app's master password.
    var firstName: String = ""
    var lastName: String = ""
    var personalEmail: String = ""
    var workEmail: String = ""
    var tags: [String] = []
    
    // Everything else, bundled and encrypted as one blob.
    var encryptedDetails: String = "" // base64 AES-256-GCM ciphertext of JSON-encoded ContactDetails
    
    var dateModified: Date = Date()
    
    var displayName: String {
        "\(firstName) \(lastName)".trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    var primaryEmail: String {
        !personalEmail.isEmpty ? personalEmail : workEmail
    }
}

/// Pre-encryption-overhaul contacts.json shape: a bare array with every field in plain,
/// unencrypted JSON. Used only to detect and migrate old data.
private struct LegacyContact: Codable {
    var firstName: String = ""
    var lastName: String = ""
    var spouseName: String = ""
    var dob: String = ""
    var street: String = ""
    var city: String = ""
    var state: String = ""
    var zip: String = ""
    var phone: String = ""
    var workEmail: String = ""
    var personalEmail: String = ""
    var website: String = ""
    var twitter: String = ""
    var facebook: String = ""
    var company: String = ""
    var tags: [String] = []
    var dateModified: Date = Date()
}

/// The on-disk contacts format. `formatVersion` exists so a future change to this layout (or KDF
/// parameters) has somewhere to hang a migration off of, the way this version migrates the old
/// pre-encryption format.
struct ContactsFile: Codable {
    var formatVersion: Int = 2
    var kdfSalt: String       // base64
    var kdfIterations: Int
    var canary: String        // base64 AES-GCM ciphertext of ContactsCrypto.canaryPlaintext
    var contacts: [Contact]
    var lastBackupTimestamp: String? = nil
}

/// Lets a launch skip the master password prompt if unlocked within the last 30 minutes — even
/// across a separate process launch, since this suite's launcher (swiftCORE) relaunches each app
/// fresh via execv rather than keeping anything resident in memory between app switches. Same
/// deliberate, lower-friction tradeoff as swiftNOTES (not applied to swiftVAULT).
private struct ContactsSessionCache: Codable {
    var keyBase64: String
    var kdfSaltBase64: String
    var expiresAt: Date
}

// MARK: - Navigation State

enum ContactsScreen {
    case workspace
    case search
    case selectResult(results: [Contact], title: String)
    case viewContact(index: Int)
    case addContact
    case editContact(index: Int)
    case dbUtilities
}

// MARK: - Keyboard Handling Engine (POSIX Raw Mode)

enum ContactsKey {
    case up, down, enter, escape
    case number(Int)
    case other(Character)
}

class ContactsKeyboardReader {
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

    func readKey() -> ContactsKey {
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
    
    /// Reads a line with "*" echoed instead of the typed character — used only for the master
    /// password. Temporarily engages raw mode for the read and restores canonical mode
    /// afterward. Typing ESC cancels and returns the sentinel "\u{1B}".
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

// MARK: - Contacts Manager

class ContactsManager {
    var contacts: [Contact] = []
    var screenStack: [ContactsScreen] = [.workspace]
    var running = true
    var selectedIdx = 0
    
    let fileURL = resolveAppDataDirectory().appendingPathComponent("contacts.json")
    let keyboard = ContactsKeyboardReader()
    
    // The book's encryption key, held only in memory for the life of the process — set once
    // after a successful unlock/creation/migration and never written to disk (except inside the
    // time-boxed session cache — see below).
    private var contactsKey: SymmetricKey!
    private var kdfSalt: Data = Data()
    private var kdfIterations: Int = ContactsCrypto.kdfIterations
    
    var lastStatusMessage: String? = nil
    var lastStatusWasError = false
    
    private var lastBackupTimestamp: String? = nil
    
    // Recomputed after every save — decrypting every contact's details is required for
    // full-text search (phone/address/company aren't otherwise searchable) and the stale-contact
    // flag, so it's done once per save rather than repeatedly per keystroke.
    private var decryptedDetailsCache: [String: ContactDetails] = [:]
    private var staleContactKeys: Set<String> = []
    
    // Telemetry properties imported securely from swiftCORE launcher Matrix
    var machineName: String = "macOS"
    var uptime: String = "Unknown"
    var cpuUsage: String = "0%"
    var memUsage: String = "0G"
    
    init() {
        parseLauncherArguments()
        unlockOrCreateContacts()
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
    
    /// dateModified never changes identity-relevant fields on its own, but it's still the most
    /// stable available key here — this app has no separate UUID. Combined with name+email it's
    /// stable enough in practice for lookups within a single loaded session.
    private func contactKey(_ contact: Contact) -> String {
        "\(contact.firstName)|\(contact.lastName)|\(contact.personalEmail)|\(contact.workEmail)"
    }
    
    // MARK: - Unlock / Create / Migrate
    
    private let sessionCacheURL = resolveAppDataDirectory().appendingPathComponent(".contacts_session")
    private static let sessionWindow: TimeInterval = 30 * 60 // 30 minutes
    
    private func loadValidSessionKey(contactsFile: ContactsFile) -> SymmetricKey? {
        guard let data = try? Data(contentsOf: sessionCacheURL),
              let cache = try? JSONDecoder().decode(ContactsSessionCache.self, from: data) else {
            return nil
        }
        
        guard cache.expiresAt > Date() else {
            try? FileManager.default.removeItem(at: sessionCacheURL)
            return nil
        }
        
        guard cache.kdfSaltBase64 == contactsFile.kdfSalt,
              let keyData = Data(base64Encoded: cache.keyBase64) else {
            return nil
        }
        
        let candidateKey = SymmetricKey(data: keyData)
        guard let decryptedCanary = try? ContactsCrypto.decrypt(contactsFile.canary, key: candidateKey),
              decryptedCanary == ContactsCrypto.canaryPlaintext else {
            return nil
        }
        
        return candidateKey
    }
    
    private func refreshSessionCache() {
        let keyBytes = contactsKey.withUnsafeBytes { Data($0) }
        let cache = ContactsSessionCache(
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

    private func unlockOrCreateContacts() {
        // v2.5 unified auth: try swiftCORE session key first
        if let sessionKey = readCoreSessionKey(appID: "swiftCONTACTS") {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                self.contactsKey = sessionKey
                self.kdfSalt = ContactsCrypto.randomSalt()
                self.kdfIterations = ContactsCrypto.kdfIterations
                self.contacts = []
                saveContacts()
                ContactsDebugLogger.log("New contacts book created via unified auth", category: "CONTACTS")
                return
            }
            if let data = try? Data(contentsOf: fileURL),
               let contactsFile = try? JSONDecoder().decode(ContactsFile.self, from: data),
               let decryptedCanary = try? ContactsCrypto.decrypt(contactsFile.canary, key: sessionKey),
               decryptedCanary == ContactsCrypto.canaryPlaintext {
                self.contactsKey = sessionKey
                self.kdfSalt = Data(base64Encoded: contactsFile.kdfSalt) ?? Data()
                self.kdfIterations = contactsFile.kdfIterations
                self.contacts = contactsFile.contacts
                self.lastBackupTimestamp = contactsFile.lastBackupTimestamp
                recomputeContactCaches()
                ContactsDebugLogger.log("Contacts unlocked via swiftCORE session (\(contacts.count) contacts)", category: "CONTACTS")
                return
            } else if FileManager.default.fileExists(atPath: fileURL.path) {
                print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
                printStandardHeader()
                print("\n \u{001B}[1;33mswiftCONTACTS v2.5 upgrade:\u{001B}[0m Your contacts were encrypted with a")
                print(" per-app password (pre-v2.5). They will be reset to use your swiftCORE")
                print(" login password instead. Any existing contacts will be cleared.\n")
                print(" Press Enter to continue and re-initialize your contacts book.")
                _ = readLine()
                try? FileManager.default.removeItem(at: fileURL)
                self.contactsKey = sessionKey
                self.kdfSalt = ContactsCrypto.randomSalt()
                self.kdfIterations = ContactsCrypto.kdfIterations
                self.contacts = []
                saveContacts()
                ContactsDebugLogger.log("Contacts reset for unified auth migration", category: "CONTACTS")
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
            createNewContactsBook()
            return
        }
        
        guard let data = try? Data(contentsOf: fileURL) else {
            print(" Could not read contacts file at \(fileURL.path). Exiting.")
            exit(1)
        }
        
        if let contactsFile = try? JSONDecoder().decode(ContactsFile.self, from: data) {
            if let cachedKey = loadValidSessionKey(contactsFile: contactsFile) {
                self.contactsKey = cachedKey
                self.kdfSalt = Data(base64Encoded: contactsFile.kdfSalt) ?? Data()
                self.kdfIterations = contactsFile.kdfIterations
                self.contacts = contactsFile.contacts
                self.lastBackupTimestamp = contactsFile.lastBackupTimestamp
                recomputeContactCaches()
                refreshSessionCache()
                lastStatusMessage = "Unlocked automatically (active session — no password needed)."
                lastStatusWasError = false
                ContactsDebugLogger.log("Contacts unlocked via cached session (\(contactsFile.contacts.count) contacts)", category: "CONTACTS")
                return
            }
            unlockExistingContacts(contactsFile)
            return
        }
        
        if let legacyContacts = try? JSONDecoder().decode([LegacyContact].self, from: data) {
            migrateLegacyContacts(legacyContacts)
            return
        }
        
        print(" Contacts file at \(fileURL.path) is unreadable or corrupted. Exiting.")
        ContactsDebugLogger.log("Contacts file present but unparseable in either current or legacy format", category: "FATAL")
        exit(1)
    }
    
    private func createNewContactsBook() {
        print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
        printStandardHeader()
        print("\n No existing contacts book found — let's set one up.\n")
        print(" Your master password protects the sensitive details on each contact —")
        print(" address, phone, birthday, company, and so on. Name and email stay")
        print(" readable without it, specifically so mail's autocomplete can use them.")
        print(" \u{001B}[1;33mThere is no recovery if you forget it — those details cannot be\u{001B}[0m")
        print(" \u{001B}[1;33mdecrypted without it.\u{001B}[0m\n")
        
        let password = promptForNewMasterPassword()
        let salt = ContactsCrypto.randomSalt()
        let iterations = ContactsCrypto.kdfIterations
        let key = PBKDF2.deriveKey(password: password, salt: salt, iterations: iterations)
        
        self.contactsKey = key
        self.kdfSalt = salt
        self.kdfIterations = iterations
        self.contacts = []
        
        saveContacts()
        refreshSessionCache()
        ContactsDebugLogger.log("New contacts book created", category: "CONTACTS")
        
        print("\n \u{001B}[1;32mContacts book created and unlocked.\u{001B}[0m Press Enter to continue.")
        _ = readLine()
    }
    
    private func unlockExistingContacts(_ contactsFile: ContactsFile) {
        guard let saltData = Data(base64Encoded: contactsFile.kdfSalt) else {
            print(" Contacts file's salt is corrupted. Exiting.")
            ContactsDebugLogger.log("Contacts salt failed to base64-decode", category: "FATAL")
            exit(1)
        }
        
        print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
        printStandardHeader()
        print("\n \u{001B}[1;36mswiftCONTACTS is locked.\u{001B}[0m\n")
        
        var attempts = 0
        while true {
            let password = promptForMasterPassword()
            let key = PBKDF2.deriveKey(password: password, salt: saltData, iterations: contactsFile.kdfIterations)
            
            if let decryptedCanary = try? ContactsCrypto.decrypt(contactsFile.canary, key: key),
               decryptedCanary == ContactsCrypto.canaryPlaintext {
                self.contactsKey = key
                self.kdfSalt = saltData
                self.kdfIterations = contactsFile.kdfIterations
                self.contacts = contactsFile.contacts
                self.lastBackupTimestamp = contactsFile.lastBackupTimestamp
                recomputeContactCaches()
                refreshSessionCache()
                ContactsDebugLogger.log("Contacts unlocked (\(contactsFile.contacts.count) contacts)", category: "CONTACTS")
                return
            }
            
            attempts += 1
            print(" \u{001B}[1;31mIncorrect master password.\u{001B}[0m\n")
            ContactsDebugLogger.log("Failed unlock attempt \(attempts)", category: "CONTACTS-AUTH")
            
            if attempts >= 5 {
                print(" Too many failed attempts. Exiting for safety.")
                ContactsDebugLogger.log("Too many failed unlock attempts — exiting", category: "CONTACTS-AUTH")
                exit(1)
            }
        }
    }
    
    private func migrateLegacyContacts(_ legacyContacts: [LegacyContact]) {
        print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
        printStandardHeader()
        print("\n \u{001B}[1;33mThis contacts book was created by an older version that stored\u{001B}[0m")
        print(" \u{001B}[1;33mevery field — including address, phone, and birthday — in plain,\u{001B}[0m")
        print(" \u{001B}[1;33munencrypted text.\u{001B}[0m\n")
        print(" Upgrading now: name and email will stay readable (so mail's")
        print(" autocomplete can use them), everything else will be encrypted.")
        print(" Set a master password to protect it going forward:\n")
        
        let password = promptForNewMasterPassword()
        let salt = ContactsCrypto.randomSalt()
        let iterations = ContactsCrypto.kdfIterations
        let key = PBKDF2.deriveKey(password: password, salt: salt, iterations: iterations)
        
        var migrated: [Contact] = []
        for legacy in legacyContacts {
            let details = ContactDetails(
                spouseName: legacy.spouseName,
                dob: legacy.dob,
                street: legacy.street,
                city: legacy.city,
                state: legacy.state,
                zip: legacy.zip,
                phone: legacy.phone,
                website: legacy.website,
                twitter: legacy.twitter,
                facebook: legacy.facebook,
                company: legacy.company
            )
            let detailsJSON = (try? JSONEncoder().encode(details)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let encrypted = (try? ContactsCrypto.encrypt(detailsJSON, key: key)) ?? ""
            
            migrated.append(Contact(
                firstName: legacy.firstName,
                lastName: legacy.lastName,
                personalEmail: legacy.personalEmail,
                workEmail: legacy.workEmail,
                tags: legacy.tags,
                encryptedDetails: encrypted,
                dateModified: legacy.dateModified
            ))
        }
        
        self.contactsKey = key
        self.kdfSalt = salt
        self.kdfIterations = iterations
        self.contacts = migrated
        
        saveContacts()
        refreshSessionCache()
        ContactsDebugLogger.log("Migrated legacy contacts: \(migrated.count) records upgraded to AES-256-GCM", category: "CONTACTS")
        
        print("\n \u{001B}[1;32mMigration complete — \(migrated.count) contact(s) upgraded.\u{001B}[0m")
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
                print(" Use at least 8 characters — this key protects your whole contacts book.\n")
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
    
    func navigate(to screen: ContactsScreen) { screenStack.append(screen) }
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
            case .viewContact(let index): showViewContactScreen(index: index)
            case .addContact: showAddContactScreen()
            case .editContact(let index): showEditContactScreen(index: index)
            case .dbUtilities: showDbUtilitiesMenu()
            }
        }
    }
    
    // MARK: - Unified 84-Column Layout Handlers
    
    private func printStandardHeader() {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MM-dd-yy"
        let dateString = dateFormatter.string(from: now)
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "hh:mm:ss a"
        let timeString = timeFormatter.string(from: now).uppercased()

        let innerWidth = 118
        let titleText = "swiftCONTACTS v2.5.07.15c"  // plain for layout; c colored below
        let sidePadding = (innerWidth - titleText.count) / 2
        var titleLineChars = Array(repeating: " ", count: innerWidth)
        for (i, ch) in dateString.enumerated() where i < innerWidth { titleLineChars[i] = String(ch) }
        for (i, ch) in titleText.enumerated() { titleLineChars[sidePadding + i] = String(ch) }
        // Color the trailing 'c' orange without affecting layout positions
        titleLineChars[sidePadding + titleText.count - 1] = "\u{001B}[38;5;208mc\u{001B}[0m"
        let timeStart = innerWidth - timeString.count
        for (i, ch) in timeString.enumerated() { titleLineChars[timeStart + i] = String(ch) }

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
        let telRaw = "\(seg1Raw)\(base+(extra>0 ? " " : ""))\(seg2)\(base+(extra>1 ? " " : ""))\(seg3)\(base+(extra>2 ? " " : ""))\(seg4)\(base)\(seg5)"
        let telCol = "\(seg1Col)\(base+(extra>0 ? " " : ""))\(seg2)\(base+(extra>1 ? " " : ""))\(seg3)\(base+(extra>2 ? " " : ""))\(seg4)\(base)\(seg5)"
        let telPad = max(0, innerWidth - telRaw.count)

        print("╭" + String(repeating: "─", count: innerWidth) + "╮")
        print("│" + titleLineChars.joined() + "│")
        print("│" + telCol + String(repeating: " ", count: telPad) + "│")
        print("╰" + String(repeating: "─", count: innerWidth) + "╯")
    }

    private func printStandardFooter(keys: String) {
        let inner = 118
        let segs = keys.components(separatedBy: "|")
        var lines: [String] = []; var cur = ""
        for seg in segs {
            let cand = cur.isEmpty ? seg : "\(cur)|\(seg)"
            if cand.count <= inner { cur = cand } else { if !cur.isEmpty { lines.append(cur) }; cur = seg }
        }
        if !cur.isEmpty { lines.append(cur) }
        print("╭" + String(repeating: "─", count: inner) + "╮")
        for line in lines {
            let p = max(0, (inner - line.count) / 2)
            print("│" + String(repeating: " ", count: p) + line + String(repeating: " ", count: inner - p - line.count) + "│")
        }
        print("╰" + String(repeating: "─", count: inner) + "╯")
    }



    // MARK: - Workspace (home screen)
    
    func showWorkspace() {
        keyboard.enableRawMode()
        
        // Column widths sized so pointer(4) + numLabel(2) + " " + flags(2) + " │ " + col + " │ "
        // + col + " │ " + col == 84 exactly. maxVisibleRows capped at 9 so every visible row's
        // number is single-digit and reachable by one keypress.
        // indent(2)+num(2)+gap(2)+name(30)+gap(2)+company(24)+gap(2)+email(36)+gap(2)+phone(16) = 118
        let colName = 30, colCompany = 24, colEmail = 36, colPhone = 16
        let maxVisibleRows = 9
        let greenBarBG = "\u{001B}[48;5;22m"
        let cReset     = "\u{001B}[0m"

        func lc(_ s: String, _ w: Int) -> String { String(s.prefix(w)).padding(toLength: w, withPad: " ", startingAt: 0) }
        func rc(_ s: String, _ w: Int) -> String { s.count >= w ? String(s.prefix(w)) : String(repeating: " ", count: w - s.count) + s }
        func buildContactRow(_ num: String, _ name: String, _ company: String, _ email: String, _ phone: String) -> String {
            "  " + rc(num, 2) + "  " + lc(name, colName) + "  " + lc(company, colCompany) + "  " + lc(email, colEmail) + "  " + lc(phone, colPhone)
        }
        
        while true {
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()
            
            let sorted = contacts.sorted(by: { $0.displayName.lowercased() < $1.displayName.lowercased() })
            
            let contactLabel = "\(sorted.count) Contact\(sorted.count == 1 ? "" : "s") Stored"
            let leftText = " CONTACTS: \(contactLabel)"
            let rightText = "● AES-256 ENCRYPTED"
            let statusPadding = max(1, 119 - leftText.count - rightText.count)
            print("\u{001B}[1;37m CONTACTS:\u{001B}[0m \(contactLabel)\(String(repeating: " ", count: statusPadding))\u{001B}[1;32m\(rightText)\u{001B}[0m")
            
            let backupText = " Last Backup: \(lastBackupTimestamp ?? "Never")"
            let staleOK = staleContactKeys.isEmpty
            let staleText = staleOK ? "● All Contacts Current" : "● \(staleContactKeys.count) Stale (1yr+ untouched)"
            let stalePadding = max(1, 119 - backupText.count - staleText.count)
            let staleColor = staleOK ? "\u{001B}[1;32m" : "\u{001B}[1;33m"
            print("\(backupText)\(String(repeating: " ", count: stalePadding))\(staleColor)\(staleText)\u{001B}[0m")
            
            let headerRow = buildContactRow("#", "NAME", "COMPANY", "EMAIL", "PHONE")
            print("╭" + String(repeating: "─", count: 118) + "╮")
            print("│\u{001B}[1;37m\(headerRow)\u{001B}[0m│")
            print("├" + String(repeating: "─", count: 118) + "┤")

            var visibleContacts: [Contact] = []

            if sorted.isEmpty {
                let emptyMsg = "  Contacts book is empty. Press 'A' to add your first contact."
                print("│\(emptyMsg)\(String(repeating: " ", count: max(0, 118 - emptyMsg.count)))│")
            } else {
                if selectedIdx >= sorted.count { selectedIdx = max(0, sorted.count - 1) }
                var startIndex = 0
                if selectedIdx >= maxVisibleRows {
                    startIndex = min(selectedIdx - maxVisibleRows + 1, sorted.count - maxVisibleRows)
                }
                startIndex = max(0, startIndex)
                let endIndex = min(startIndex + maxVisibleRows, sorted.count)
                visibleContacts = Array(sorted[startIndex..<endIndex])

                for (rowNum, idx) in (startIndex..<endIndex).enumerated() {
                    let contact = sorted[idx]
                    let isStale = staleContactKeys.contains(contactKey(contact))
                    let cachedDetails = decryptedDetailsCache[contactKey(contact)]
                    let company = cachedDetails?.company ?? ""
                    let primaryPhone = { () -> String in
                        let p = cachedDetails?.phone ?? ""
                        let w = cachedDetails?.workPhone ?? ""
                        return !p.isEmpty ? p : w
                    }()
                    let plain = buildContactRow("\(rowNum + 1)", contact.displayName, company, contact.primaryEmail, primaryPhone)
                    let padded = plain.padding(toLength: 118, withPad: " ", startingAt: 0)

                    if idx == selectedIdx {
                        print("│\u{001B}[7m\u{001B}[1m\(padded)\(cReset)│")
                    } else if (rowNum + 1) % 2 != 0 {
                        print("│\(greenBarBG)\(padded)\(cReset)│")
                    } else {
                        if isStale {
                            // Stale contacts shown with dim text on plain rows
                            print("│\u{001B}[2m\(plain)\(cReset)│")
                        } else {
                            print("│\(plain)│")
                        }
                    }
                }
            }

            print("╰" + String(repeating: "─", count: 118) + "╯")
            printStandardFooter(keys: "ENTER/1-9: View | A: Add | /: Search | D: Delete | U: Utilities")
            printNavFooter()

            switch keyboard.readKey() {
            case .up:
                if !sorted.isEmpty { selectedIdx = (selectedIdx == 0) ? sorted.count - 1 : selectedIdx - 1 }
            case .down:
                if !sorted.isEmpty { selectedIdx = (selectedIdx == sorted.count - 1) ? 0 : selectedIdx + 1 }
            case .enter:
                if !sorted.isEmpty {
                    keyboard.disableRawMode()
                    openSelectedContact(sorted[selectedIdx])
                    return
                }
            case .number(let num):
                if num >= 1 && num <= visibleContacts.count {
                    keyboard.disableRawMode()
                    openSelectedContact(visibleContacts[num - 1])
                    return
                }
            case .other(let ch):
                let lower = Character(ch.lowercased())
                if lower == "a" {
                    keyboard.disableRawMode()
                    navigate(to: .addContact)
                    return
                } else if lower == "/" {
                    keyboard.disableRawMode()
                    navigate(to: .search)
                    return
                } else if lower == "d" {
                    if !sorted.isEmpty { deleteContactInline(sorted[selectedIdx]) }
                } else if lower == "u" {
                    keyboard.disableRawMode()
                    navigate(to: .dbUtilities)
                    return
                } else {
                    // Nav footer — [A] is Add Contact, [T] is the nav key for Contacts
                    let navMap: [Character: String] = [
                        "t": "swiftCONTACTS", "c": "swiftCALENDAR",
                        "m": "swiftMAIL",     "n": "swiftNOTES",
                        "s": "swiftSTOCKS",   "v": "swiftVAULT"
                    ]
                    if let target = navMap[lower] {
                        keyboard.disableRawMode()
                        navigateToApp(target, args: [machineName, uptime, cpuUsage, memUsage])
                        keyboard.enableRawMode()
                    } else if lower == "l" {
                        keyboard.disableRawMode()
                        returnToLauncher(); return
                    }
                }
            case .escape:
                keyboard.disableRawMode()
                returnToLauncher()
                return
            }
        }
    }
    
    private func deleteContactInline(_ chosen: Contact) {
        guard let masterIndex = contacts.firstIndex(where: { contactKey($0) == contactKey(chosen) }) else { return }
        keyboard.disableRawMode()
        print("\n Delete \"\(chosen.displayName)\" permanently? (y/n): ", terminator: "")
        if let confirm = readLine(), confirm.lowercased() == "y" {
            contacts.remove(at: masterIndex)
            saveContacts()
            lastStatusMessage = "Deleted \(chosen.displayName)."
            lastStatusWasError = false
            ContactsDebugLogger.log("Contact deleted (name redacted)", category: "CONTACTS")
            if selectedIdx > 0 { selectedIdx -= 1 }
        }
        keyboard.enableRawMode()
    }
    
    private func openSelectedContact(_ chosen: Contact) {
        if let masterIndex = contacts.firstIndex(where: { contactKey($0) == contactKey(chosen) }) {
            navigate(to: .viewContact(index: masterIndex))
        }
    }
    
    // MARK: - Search
    
    private func matchesQuery(_ contact: Contact, query: String) -> Bool {
        let lowerQuery = query.lowercased()
        let plainFields = [contact.firstName, contact.lastName, contact.personalEmail, contact.workEmail]
        if plainFields.contains(where: { $0.lowercased().contains(lowerQuery) }) { return true }
        if contact.tags.contains(where: { $0.lowercased().contains(lowerQuery) }) { return true }
        
        if let details = decryptedDetailsCache[contactKey(contact)] {
            let detailFields = [
                details.spouseName, details.dob, details.street, details.city, details.state,
                details.zip, details.phone, details.workPhone, details.website, details.twitter, details.facebook, details.company
            ]
            if detailFields.contains(where: { $0.lowercased().contains(lowerQuery) }) { return true }
        }
        return false
    }
    
    func showSearchScreen() {
        printStandardHeader()
        print("                        >>> swiftCONTACTS SEARCH ENGINE <<<                         ")
        print(String(repeating: "─", count: 120))
        guard let query = getStringInput(prompt: " Enter search phrase or category tag: ") else { return }
        let results = contacts.filter { matchesQuery($0, query: query) }
        goBack()
        
        if results.isEmpty {
            print("\n No contacts matched '\(query)'.")
            print(" Press Enter to return...")
            _ = readLine()
        } else {
            navigate(to: .selectResult(results: results, title: "SEARCH RESULTS FOR '\(query.uppercased())'"))
        }
    }
    
    func showResultsScreen(results: [Contact], title: String) {
        var localIdx = 0
        keyboard.enableRawMode()
        let sorted = results.sorted(by: { $0.displayName.lowercased() < $1.displayName.lowercased() })
        
        while true {
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()
            
            let paddingSize = max(0, (84 - title.count - 8) / 2)
            let paddingSpaces = String(repeating: " ", count: paddingSize)
            print("\(paddingSpaces)=== \(title) ===")
            print(" (Press ESC to go back to previous menu view)\n")
            
            for (idx, contact) in sorted.enumerated() {
                let prefix = (idx == localIdx) ? " -> " : "    "
                let company = decryptedDetailsCache[contactKey(contact)]?.company ?? ""
                let companySuffix = company.isEmpty ? "" : " [\(company)]"
                print("\(prefix)[\(idx + 1)]. \(contact.displayName)\(companySuffix)")
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
                    openSelectedContact(sorted[localIdx])
                    return
                }
            case .escape:
                keyboard.disableRawMode()
                goBack()
                return
            case .enter:
                if !sorted.isEmpty {
                    keyboard.disableRawMode()
                    openSelectedContact(sorted[localIdx])
                    return
                }
            default: break
            }
        }
    }
    
    // MARK: - View / Add / Edit Contact
    
    private func daysAgoDescription(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days <= 0 { return "today" }
        if days == 1 { return "1 day ago" }
        return "\(days) days ago"
    }
    
    func showViewContactScreen(index: Int) {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd/yy HH:mm"
        keyboard.enableRawMode()

        while true {
            let contact = contacts[index]
            let details = decryptedDetailsCache[contactKey(contact)]
                ?? (try? ContactsCrypto.decrypt(contact.encryptedDetails, key: contactsKey))
                    .flatMap { try? JSONDecoder().decode(ContactDetails.self, from: Data($0.utf8)) }
                ?? ContactDetails()

            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()

            let inner = 118
            func infoRow(_ label: String, _ value: String, colored: String? = nil) {
                let plain = "  \(label.padding(toLength: 18, withPad: " ", startingAt: 0))\(value)"
                let display = "  \(label.padding(toLength: 18, withPad: " ", startingAt: 0))\(colored ?? value)"
                print("│\(display)\(String(repeating: " ", count: max(0, inner - plain.count)))│")
            }

            let isStale = staleContactKeys.contains(contactKey(contact))
            let modValue = "\(formatter.string(from: contact.dateModified)) (\(daysAgoDescription(contact.dateModified)))"
            let modColored = isStale ? "\u{001B}[1;33m\(modValue)\u{001B}[0m" : nil

            // Helper to print a blank separator row inside the box
            func blankRow() { print("│" + String(repeating: " ", count: inner) + "│") }

            print("╭" + String(repeating: "─", count: inner) + "╮")

            // ── Personal block ──
            infoRow("Name",           contact.displayName)
            if !contact.personalEmail.isEmpty { infoRow("Personal Email", contact.personalEmail) }
            if !details.phone.isEmpty         { infoRow("Personal Phone", details.phone) }
            if !details.dob.isEmpty           { infoRow("Birthday",       details.dob) }
            if !details.spouseName.isEmpty    { infoRow("Spouse",         details.spouseName) }

            // ── Address block ──
            if !details.street.isEmpty || !details.city.isEmpty {
                blankRow()
                if !details.street.isEmpty { infoRow("Address", details.street) }
                if !details.city.isEmpty {
                    let cityLine = "\(details.city), \(details.state) \(details.zip)".trimmingCharacters(in: .whitespaces)
                    infoRow("", cityLine)
                }
            }

            // ── Work block ──
            let hasWork = !details.company.isEmpty || !contact.workEmail.isEmpty || !details.workPhone.isEmpty
            if hasWork {
                blankRow()
                if !details.company.isEmpty    { infoRow("Company",    details.company) }
                if !contact.workEmail.isEmpty  { infoRow("Work Email", contact.workEmail) }
                if !details.workPhone.isEmpty  { infoRow("Work Phone", details.workPhone) }
            }

            // ── Online / social ──
            let hasSocial = !details.website.isEmpty || !details.twitter.isEmpty || !details.facebook.isEmpty
            if hasSocial {
                blankRow()
                if !details.website.isEmpty  { infoRow("Website",   details.website) }
                if !details.twitter.isEmpty  { infoRow("Twitter/X", details.twitter) }
                if !details.facebook.isEmpty { infoRow("Facebook",  details.facebook) }
            }

            // ── Meta ──
            blankRow()
            infoRow("Tags",          contact.tags.isEmpty ? "—" : contact.tags.joined(separator: ", "))
            infoRow("Last Modified", modValue, colored: modColored)
            print("╰" + String(repeating: "─", count: inner) + "╯")
            print("")
            printStandardFooter(keys: "[E] Edit Contact  |  [D] Delete Contact  |  ESC: Back")
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
                    navigate(to: .editContact(index: index))
                    return
                } else if lower == "d" {
                    keyboard.disableRawMode()
                    print("\n Delete \(contact.displayName) permanently? (y/n): ", terminator: "")
                    if let confirm = readLine(), confirm.lowercased() == "y" {
                        contacts.remove(at: index)
                        saveContacts()
                        ContactsDebugLogger.log("Contact deleted (name redacted)", category: "CONTACTS")
                        print("\n Contact deleted. Press Enter.")
                        _ = readLine()
                        goBack()
                        return
                    }
                    keyboard.enableRawMode()
                } else {
                    let navMap: [Character: String] = [
                        "t": "swiftCONTACTS", "c": "swiftCALENDAR",
                        "m": "swiftMAIL",     "n": "swiftNOTES",
                        "s": "swiftSTOCKS",   "v": "swiftVAULT"
                    ]
                    if let target = navMap[lower], target != "swiftCONTACTS" {
                        navigateToApp(target, args: [machineName, uptime, cpuUsage, memUsage])
                    } else if lower == "l" {
                        keyboard.disableRawMode()
                        returnToLauncher(); return
                    }
                    keyboard.enableRawMode()
                }
            default: break
            }
        }
    }

    

    func showAddContactScreen() {
        printStandardHeader()
        print("                              >>> ADD NEW CONTACT <<<                               ")
        print(String(repeating: "─", count: 120))
        guard let first = getStringInput(prompt: " First Name: ") else { return }
        guard let last = getStringInput(prompt: " Last Name: ") else { return }
        
        if first.isEmpty && last.isEmpty {
            print("\n Cancelled: both name fields were empty. Press Enter.")
            _ = readLine()
            goBack()
            return
        }
        
        let personalEmail = getStringInput(prompt: " Personal Email: ") ?? ""
        let workEmail = getStringInput(prompt: " Work Email: ") ?? ""
        
        var details = ContactDetails()
        details.company = getStringInput(prompt: " Company/Organization: ") ?? ""
        details.phone = getStringInput(prompt: " Personal Phone: ") ?? ""
        details.workPhone = getStringInput(prompt: " Work Phone: ") ?? ""
        details.spouseName = getStringInput(prompt: " Spouse Name: ") ?? ""
        details.dob = getStringInput(prompt: " Date of Birth (MM/DD/YYYY): ") ?? ""
        details.street = getStringInput(prompt: " Street Address: ") ?? ""
        details.city = getStringInput(prompt: " City: ") ?? ""
        details.state = getStringInput(prompt: " State: ") ?? ""
        details.zip = getStringInput(prompt: " Zip/Postal Code: ") ?? ""
        details.website = getStringInput(prompt: " Website: ") ?? ""
        details.twitter = getStringInput(prompt: " Twitter/X Handle: ") ?? ""
        details.facebook = getStringInput(prompt: " Facebook: ") ?? ""
        
        let tagsLine = getStringInput(prompt: " Tags (space separated): ") ?? ""
        let tags = parseTagsFromString(tagsLine)
        
        guard let detailsData = try? JSONEncoder().encode(details),
              let detailsJSON = String(data: detailsData, encoding: .utf8),
              let encrypted = try? ContactsCrypto.encrypt(detailsJSON, key: contactsKey) else {
            print("\n \u{001B}[1;31mEncryption failed — contact not saved.\u{001B}[0m Press Enter.")
            _ = readLine()
            goBack()
            return
        }
        
        let newContact = Contact(
            firstName: first,
            lastName: last,
            personalEmail: personalEmail,
            workEmail: workEmail,
            tags: tags,
            encryptedDetails: encrypted,
            dateModified: Date()
        )
        
        contacts.append(newContact)
        saveContacts()
        ContactsDebugLogger.log("Contact added (name redacted)", category: "CONTACTS")
        
        print("\n Contact saved successfully! Press Enter to return to main menu.")
        _ = readLine()
        goBack()
    }
    
    func showEditContactScreen(index: Int) {
        var contact = contacts[index]
        var details = decryptedDetailsCache[contactKey(contact)]
            ?? (try? ContactsCrypto.decrypt(contact.encryptedDetails, key: contactsKey))
                .flatMap { try? JSONDecoder().decode(ContactDetails.self, from: Data($0.utf8)) }
            ?? ContactDetails()
        
        printStandardHeader()
        print("                                >>> EDIT CONTACT <<<                                ")
        print(String(repeating: "─", count: 120))
        print(" Press Enter to keep existing values.\n")
        
        if let val = getStringInput(prompt: " First Name [\(contact.firstName)]: "), !val.isEmpty { contact.firstName = val }
        if let val = getStringInput(prompt: " Last Name [\(contact.lastName)]: "), !val.isEmpty { contact.lastName = val }
        if let val = getStringInput(prompt: " Personal Email [\(contact.personalEmail)]: ") { contact.personalEmail = val }
        if let val = getStringInput(prompt: " Work Email [\(contact.workEmail)]: ") { contact.workEmail = val }
        if let val = getStringInput(prompt: " Company [\(details.company)]: ") { details.company = val }
        if let val = getStringInput(prompt: " Personal Phone [\(details.phone)]: ") { details.phone = val }
        if let val = getStringInput(prompt: " Work Phone [\(details.workPhone)]: ") { details.workPhone = val }
        if let val = getStringInput(prompt: " Spouse Name [\(details.spouseName)]: ") { details.spouseName = val }
        if let val = getStringInput(prompt: " Date of Birth [\(details.dob)]: ") { details.dob = val }
        if let val = getStringInput(prompt: " Street Address [\(details.street)]: ") { details.street = val }
        if let val = getStringInput(prompt: " City [\(details.city)]: ") { details.city = val }
        if let val = getStringInput(prompt: " State [\(details.state)]: ") { details.state = val }
        if let val = getStringInput(prompt: " Zip [\(details.zip)]: ") { details.zip = val }
        if let val = getStringInput(prompt: " Website [\(details.website)]: ") { details.website = val }
        if let val = getStringInput(prompt: " Twitter/X [\(details.twitter)]: ") { details.twitter = val }
        if let val = getStringInput(prompt: " Facebook [\(details.facebook)]: ") { details.facebook = val }
        
        let currentTagsLine = contact.tags.joined(separator: " ")
        if let val = getStringInput(prompt: " Tags [\(currentTagsLine)]: "), !val.isEmpty {
            contact.tags = parseTagsFromString(val)
        }
        
        if let detailsData = try? JSONEncoder().encode(details),
           let detailsJSON = String(data: detailsData, encoding: .utf8),
           let encrypted = try? ContactsCrypto.encrypt(detailsJSON, key: contactsKey) {
            contact.encryptedDetails = encrypted
        } else {
            print("\n \u{001B}[1;31mEncryption failed — details not changed.\u{001B}[0m")
        }
        
        contact.dateModified = Date()
        contacts[index] = contact
        saveContacts()
        ContactsDebugLogger.log("Contact updated (name redacted)", category: "CONTACTS")
        
        print("\n Contact updated successfully! Press Enter.")
        _ = readLine()
        goBack()
    }
    
    // MARK: - Database Utilities Menu
    
    func showDbUtilitiesMenu() {
        let options = [
            "Backup Contacts Database",
            "Restore Contacts Database",
            "Export CSV Template",
            "Import from CSV",
            "Delete All Contacts",
            "Back to Contacts"
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
            print(String(repeating: "─", count: 120))
            
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
        case 2: exportToCSV()
        case 3: importFromCSV()
        case 4: deleteAllContacts()
        case 5: goBack()
        default: break
        }
    }
    
    private func deleteAllContacts() {
        printStandardHeader()
        if contacts.isEmpty {
            print("\n Contacts book is already empty.")
            print(" Press Enter to continue...")
            _ = readLine()
            return
        }
        
        print("\n WARNING: This will delete ALL \(contacts.count) contacts permanently!")
        print(" Type 'CONFIRM' to clear everything: ", terminator: "")
        if let validation = readLine(), validation == "CONFIRM" {
            contacts.removeAll()
            saveContacts()
            ContactsDebugLogger.log("All contacts wiped by user request", category: "CONTACTS")
            print("\n Contacts book successfully wiped clean!")
            lastStatusMessage = "Contacts book wiped."
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
            print("\n Error: No database file found to backup yet. Add a contact first.")
            print(" Press Enter to continue...")
            _ = readLine()
            return
        }
        
        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "MM-dd-yy hh:mm a"
        lastBackupTimestamp = displayFormatter.string(from: Date()).uppercased()
        saveContacts()
        
        let fileFormatter = DateFormatter()
        fileFormatter.dateFormat = "yyyyMMdd_HHmm"
        let timestamp = fileFormatter.string(from: Date())
        let backupURL = resolveAppDataDirectory().appendingPathComponent("contacts_backup_\(timestamp).json")
        
        do {
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
            print("\n Backup created successfully: \(backupURL.lastPathComponent)")
            print(" (This backup is real AES-256 ciphertext for the sensitive fields, protected")
            print(" by the same master password. Name/email were already stored in plain text.)")
            lastStatusMessage = "Backup created: \(backupURL.lastPathComponent)"
            lastStatusWasError = false
            ContactsDebugLogger.log("Backup created: \(backupURL.lastPathComponent)", category: "CONTACTS")
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
            let backupFiles = files.filter { $0.lastPathComponent.hasPrefix("contacts_backup_") && $0.lastPathComponent.hasSuffix(".json") }
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
                print("                         >>> AVAILABLE CONTACTS BACKUPS <<<                         ")
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
        
        guard let data = try? Data(contentsOf: fileURL), let contactsFile = try? JSONDecoder().decode(ContactsFile.self, from: data) else {
            print(" \u{001B}[1;31mCould not read that backup file.\u{001B}[0m")
            print(" Press Enter to continue...")
            _ = readLine()
            return
        }
        
        guard let saltData = Data(base64Encoded: contactsFile.kdfSalt) else {
            print(" \u{001B}[1;31mBackup file's salt is corrupted.\u{001B}[0m")
            print(" Press Enter to continue...")
            _ = readLine()
            return
        }
        
        var attempts = 0
        while true {
            let password = promptForMasterPassword()
            let key = PBKDF2.deriveKey(password: password, salt: saltData, iterations: contactsFile.kdfIterations)
            
            if let decryptedCanary = try? ContactsCrypto.decrypt(contactsFile.canary, key: key), decryptedCanary == ContactsCrypto.canaryPlaintext {
                self.contactsKey = key
                self.kdfSalt = saltData
                self.kdfIterations = contactsFile.kdfIterations
                self.contacts = contactsFile.contacts
                self.lastBackupTimestamp = contactsFile.lastBackupTimestamp
                recomputeContactCaches()
                refreshSessionCache()
                ContactsDebugLogger.log("Contacts restored from \(file.lastPathComponent)", category: "CONTACTS")
                print("\n \u{001B}[1;32mContacts restored from \(file.lastPathComponent) successfully!\u{001B}[0m")
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
    
    // MARK: - CSV Import / Export
    //
    // A CSV export here contains everything, including the fields that are otherwise encrypted
    // at rest (phone, address, DOB) — that's inherent to CSV as a format, not something this
    // code can avoid. Both directions get an explicit warning about that.
    
    func exportToCSV() {
        printStandardHeader()
        print(" \u{001B}[1;33mWarning: the exported file will contain every field in plain text,\u{001B}[0m")
        print(" \u{001B}[1;33mincluding the ones normally encrypted at rest (phone, address, DOB).\u{001B}[0m")
        print(" \u{001B}[1;33mHandle it accordingly once it's on disk.\u{001B}[0m\n")
        
        let exportURL = resolveAppDataDirectory().appendingPathComponent("contacts.csv")
        var csvString = "FirstName,LastName,DOB,Spouse,Phone,PersonalEmail,Street,City,State,Zip,Company,WorkPhone,WorkEmail,Tags\n"
        
        for c in contacts {
            let details = decryptedDetailsCache[contactKey(c)]
                ?? (try? ContactsCrypto.decrypt(c.encryptedDetails, key: contactsKey))
                    .flatMap { try? JSONDecoder().decode(ContactDetails.self, from: Data($0.utf8)) }
                ?? ContactDetails()
            
            let fields = [
                c.firstName, c.lastName, details.dob, details.spouseName,
                details.phone, c.personalEmail, details.street,
                details.city, details.state, details.zip,
                details.company, details.workPhone, c.workEmail,
                c.tags.joined(separator: " ")
            ]
            let row = fields.map { field -> String in
                let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\""
            }.joined(separator: ",")
            csvString.append("\(row)\n")
        }
        
        do {
            try csvString.write(to: exportURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: exportURL.path)
            print(" Exported successfully to: \(exportURL.path)")
            lastStatusMessage = "Exported \(contacts.count) contact(s) to CSV."
            lastStatusWasError = false
            ContactsDebugLogger.log("Exported \(contacts.count) contacts to CSV", category: "CONTACTS")
        } catch {
            print(" Export failed: \(error)")
            lastStatusMessage = "Export failed: \(error.localizedDescription)"
            lastStatusWasError = true
        }
        print(" Press Enter to continue...")
        _ = readLine()
    }

    func importFromCSV() {
        printStandardHeader()
        let importURL = resolveAppDataDirectory().appendingPathComponent("contacts.csv")
        
        guard FileManager.default.fileExists(atPath: importURL.path) else {
            print("\n Error: 'contacts.csv' was not found in the app data directory.")
            print(" Press Enter to continue...")
            _ = readLine()
            return
        }
        
        print(" \u{001B}[1;33mWarning: contacts.csv is plain text — it will be deleted automatically\u{001B}[0m")
        print(" \u{001B}[1;33mafter a successful import.\u{001B}[0m\n")
        
        do {
            let content = try String(contentsOf: importURL, encoding: .utf8)
            let rows = content.components(separatedBy: .newlines).dropFirst()
            var count = 0
            var skipped = 0
            var skippedNames: [String] = []

            // Build a set of existing contact names for fast duplicate lookup
            let existingNames = Set(contacts.map { "\($0.firstName.lowercased()) \($0.lastName.lowercased())" })
            
            for row in rows where !row.isEmpty {
                let fields = row.components(separatedBy: ",").map { $0.replacingOccurrences(of: "\"", with: "") }
                guard fields.count >= 13 else { continue }
                
                var details = ContactDetails()
                details.dob = fields[2]
                details.spouseName = fields[3]
                details.phone = fields[4]
                details.street = fields[6]
                details.city = fields[7]
                details.state = fields[8]
                details.zip = fields[9]
                details.company = fields[10]
                details.workPhone = fields[11]
                
                guard let detailsData = try? JSONEncoder().encode(details),
                      let detailsJSON = String(data: detailsData, encoding: .utf8),
                      let encrypted = try? ContactsCrypto.encrypt(detailsJSON, key: contactsKey) else {
                    continue
                }
                
                let tags = fields.count >= 14 ? parseTagsFromString(fields[13]) : []
                
                let newContact = Contact(
                    firstName: fields[0],
                    lastName: fields[1],
                    personalEmail: fields[5],
                    workEmail: fields[12],
                    tags: tags,
                    encryptedDetails: encrypted,
                    dateModified: Date()
                )

                // Skip if contact with same name already exists
                let nameKey = "\(fields[0].lowercased()) \(fields[1].lowercased())"
                if existingNames.contains(nameKey) {
                    skipped += 1
                    skippedNames.append("\(fields[0]) \(fields[1])")
                    continue
                }

                contacts.append(newContact)
                count += 1
            }
            saveContacts()
            ContactsDebugLogger.log("Imported \(count) contacts, skipped \(skipped) duplicates", category: "CONTACTS")
            print("\n \u{001B}[1;32m\(count) contact(s) imported and encrypted.\u{001B}[0m")
            if skipped > 0 {
                print(" \u{001B}[2m\(skipped) skipped (already exist): \(skippedNames.joined(separator: ", "))\u{001B}[0m")
            }
            lastStatusMessage = "Imported \(count), skipped \(skipped) duplicate(s)."
            lastStatusWasError = false
            
            // Auto-delete after successful import — no plaintext left on disk
            if let data = try? Data(contentsOf: importURL) {
                let randomOverwrite = Data((0..<data.count).map { _ in UInt8.random(in: 0...255) })
                try? randomOverwrite.write(to: importURL)
            }
            try? FileManager.default.removeItem(at: importURL)
            print(" \u{001B}[1;32mcontacts.csv deleted automatically.\u{001B}[0m")
            ContactsDebugLogger.log("contacts.csv deleted after import", category: "CONTACTS")
        } catch {
            print(" Import error: \(error)")
            lastStatusMessage = "Import failed: \(error.localizedDescription)"
            lastStatusWasError = true
        }
        print(" Press Enter to continue...")
        _ = readLine()
    }
    
    // MARK: - Persistence Data Layer
    
    func saveContacts() {
        recomputeContactCaches()
        do {
            let canaryEncrypted = try ContactsCrypto.encrypt(ContactsCrypto.canaryPlaintext, key: contactsKey)
            let contactsFile = ContactsFile(
                formatVersion: 2,
                kdfSalt: kdfSalt.base64EncodedString(),
                kdfIterations: kdfIterations,
                canary: canaryEncrypted,
                contacts: contacts,
                lastBackupTimestamp: lastBackupTimestamp
            )
            let data = try JSONEncoder().encode(contactsFile)
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            print("Contacts write error: \(error)")
            ContactsDebugLogger.log("Contacts save failed: \(error.localizedDescription)", category: "CONTACTS-ERR")
        }
    }
    
    // MARK: - Contact Health (decrypted-details cache for search/company display, staleness flag)
    
    private func recomputeContactCaches() {
        guard contactsKey != nil else { return }
        
        var detailsCache: [String: ContactDetails] = [:]
        var stale: Set<String> = []
        let oneYearAgo = Calendar.current.date(byAdding: .day, value: -365, to: Date()) ?? Date.distantPast
        
        for contact in contacts {
            let key = contactKey(contact)
            if let plaintext = try? ContactsCrypto.decrypt(contact.encryptedDetails, key: contactsKey),
               let details = try? JSONDecoder().decode(ContactDetails.self, from: Data(plaintext.utf8)) {
                detailsCache[key] = details
            }
            if contact.dateModified < oneYearAgo {
                stale.insert(key)
            }
        }
        
        self.decryptedDetailsCache = detailsCache
        self.staleContactKeys = stale
    }
}

// MARK: - Central Process Relay Handler

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
        _ = readLine(); return
    }
    if chdir(targetDir.path) != 0 { print("Error: chdir failed"); exit(1) }
    var cArgs: [UnsafeMutablePointer<CChar>?] = [binaryPath.withCString { strdup($0) }]
    for arg in args { cArgs.append(arg.withCString { strdup($0) }) }
    cArgs.append(nil)
    execv(binaryPath, &cArgs)
    print("Error: execv failed for \(folder)"); exit(1)
}

func returnToLauncher() { navigateToApp("swiftCORE", args: []) }

func printNavFooter(currentApp: String = "swiftCONTACTS") {
    let inner = 118
    let navItems: [(key: String, label: String, folder: String)] = [
        ("T", "Contacts", "swiftCONTACTS"),
        ("C", "Calendar", "swiftCALENDAR"),
        ("M", "Mail",     "swiftMAIL"),
        ("N", "Notes",    "swiftNOTES"),
        ("S", "Stocks",   "swiftSTOCKS"),
        ("V", "Vault",    "swiftVAULT"),
    ]
    let plainParts = navItems.map { "[\($0.key)] \($0.label)" } + ["[L] Logout"]
    let plainNav   = plainParts.joined(separator: "  ")
    let navPad     = max(0, (inner - plainNav.count) / 2)
    var colored = ""
    for item in navItems {
        let label = "[\(item.key)] \(item.label)"
        colored += item.folder == currentApp
            ? "\u{001B}[1;32m\(label)\u{001B}[0m  "
            : "\u{001B}[2m\(label)\u{001B}[0m  "
    }
    colored += "\u{001B}[1;31m[L] Logout\u{001B}[0m"
    print("╭" + String(repeating: "─", count: inner) + "╮")
    print("│" + String(repeating: " ", count: navPad) + colored +
          String(repeating: " ", count: inner - navPad - plainNav.count) + "│")
    print("╰" + String(repeating: "─", count: inner) + "╯")
}

// MARK: - App Execution
let contactsEngine = ContactsManager()
contactsEngine.run()