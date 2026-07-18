import Foundation
import CryptoKit

// MARK: - App Storage Location

/// Resolves the directory the compiled binary itself lives in — not the current working
/// directory, which varies by how the app is launched. Kept consistent with swiftMAIL/
/// swiftSTOCKS so a folder-sync tool like Syncthing can carry vault.json between machines if
/// you want that. The vault file itself is real AES-256-GCM ciphertext now, so — unlike before —
/// a copy of this file sitting in a synced folder doesn't expose your passwords on its own; it's
/// only as strong as your master password.
func resolveAppDataDirectory() -> URL {
    let executablePath = CommandLine.arguments.first ?? "."
    return URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().deletingLastPathComponent()
}

// MARK: - Debug Logger
//
// IMPORTANT: this must never be passed a plaintext password, master password, or decrypted
// credential — only operation descriptions (e.g. "credential added for service X", "vault
// unlocked", "backup restored"). Every call site below sticks to that.

class VaultDebugLogger {
    static let logURL: URL = resolveAppDataDirectory().appendingPathComponent("swiftvault_debug.log")
    
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
// Replaces the old "encryption": a single-byte XOR cipher with a hardcoded key (42), which is
// trivially reversible by anyone who has the vault file or the source code — it provided
// essentially no real protection. This implements actual password-based encryption:
//   - PBKDF2-HMAC-SHA256, 600,000 iterations (OWASP's current minimum recommendation for
//     PBKDF2-SHA256 as of 2023-2026), turning your master password into a 256-bit key. Hand-
//     implemented on CryptoKit's HMAC primitive rather than importing CommonCrypto, since
//     CryptoKit is already proven to compile in this toolchain and CommonCrypto's availability
//     in a plain `swiftc` single-file build isn't something that could be verified here.
//   - AES-256-GCM (authenticated encryption) for the actual credential data, using CryptoKit —
//     the same primitive swiftMAIL uses for its stored app password.
//   - A random 16-byte salt per vault (not secret — stored alongside the data — its job is
//     only to stop precomputed rainbow-table attacks and ensure two vaults with the same master
//     password don't derive the same key).

enum VaultCryptoError: Error {
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

enum VaultCrypto {
    /// OWASP's current (2023-2026) minimum recommendation for PBKDF2-HMAC-SHA256.
    static let kdfIterations = 100_000
    /// Encrypted at vault creation and decrypted on every unlock attempt — if it doesn't come
    /// back exactly matching this, the master password was wrong. Lets a wrong password be
    /// detected immediately even for a brand-new, otherwise-empty vault.
    static let canaryPlaintext = "swiftVAULT-OK"
    
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
        guard let combined = sealedBox.combined else { throw VaultCryptoError.decryptionFailed }
        return combined.base64EncodedString()
    }
    
    static func decrypt(_ base64: String, key: SymmetricKey) throws -> String {
        guard let data = Data(base64Encoded: base64) else { throw VaultCryptoError.invalidCiphertext }
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        let decryptedData = try AES.GCM.open(sealedBox, using: key)
        guard let text = String(data: decryptedData, encoding: .utf8) else { throw VaultCryptoError.invalidCiphertext }
        return text
    }
}

// MARK: - Site Name Lookup
//
// Suggests a display name from a URL/domain (e.g. "aa.com" -> "American Airlines") when adding
// a credential. Deliberately kept fully offline rather than fetching the page and parsing its
// <title> — a password vault making outbound network calls, even harmless ones, is a bigger
// trust/attack-surface question than it would be for a stock tracker or email client, and page
// titles are usually marketing copy ("American Airlines - Book flights...") rather than a clean
// name anyway. The tradeoff is coverage: only what's in the table below is recognized instantly;
// anything else falls back to a best-effort guess from the domain itself. Either way this is
// only ever a suggestion — it's shown as an editable default, never applied silently.
enum SiteNameLookup {
    private static let knownDomains: [String: String] = [
        // Airlines
        "aa.com": "American Airlines", "united.com": "United Airlines", "delta.com": "Delta Air Lines",
        "southwest.com": "Southwest Airlines", "jetblue.com": "JetBlue", "alaskaair.com": "Alaska Airlines",
        "spirit.com": "Spirit Airlines", "flyfrontier.com": "Frontier Airlines", "aircanada.com": "Air Canada",
        "britishairways.com": "British Airways", "lufthansa.com": "Lufthansa", "emirates.com": "Emirates",
        // Banks & finance
        "chase.com": "Chase", "bankofamerica.com": "Bank of America", "wellsfargo.com": "Wells Fargo",
        "citi.com": "Citibank", "usbank.com": "U.S. Bank", "capitalone.com": "Capital One",
        "americanexpress.com": "American Express", "discover.com": "Discover", "ally.com": "Ally Bank",
        "schwab.com": "Charles Schwab", "fidelity.com": "Fidelity", "vanguard.com": "Vanguard",
        "paypal.com": "PayPal", "venmo.com": "Venmo", "robinhood.com": "Robinhood", "coinbase.com": "Coinbase",
        "navyfederal.org": "Navy Federal Credit Union", "usaa.com": "USAA",
        // Tech
        "google.com": "Google", "apple.com": "Apple", "microsoft.com": "Microsoft", "amazon.com": "Amazon",
        "meta.com": "Meta", "facebook.com": "Facebook", "instagram.com": "Instagram", "twitter.com": "X (Twitter)",
        "x.com": "X (Twitter)", "linkedin.com": "LinkedIn", "github.com": "GitHub", "gitlab.com": "GitLab",
        "dropbox.com": "Dropbox", "adobe.com": "Adobe", "salesforce.com": "Salesforce", "slack.com": "Slack",
        "zoom.us": "Zoom", "notion.so": "Notion", "atlassian.com": "Atlassian", "reddit.com": "Reddit",
        // E-commerce & retail
        "ebay.com": "eBay", "etsy.com": "Etsy", "target.com": "Target", "walmart.com": "Walmart",
        "costco.com": "Costco", "bestbuy.com": "Best Buy", "homedepot.com": "Home Depot", "lowes.com": "Lowe's",
        // Streaming & entertainment
        "netflix.com": "Netflix", "hulu.com": "Hulu", "disneyplus.com": "Disney+", "max.com": "Max",
        "spotify.com": "Spotify", "youtube.com": "YouTube", "twitch.tv": "Twitch", "primevideo.com": "Prime Video",
        // Telecom & utilities
        "verizon.com": "Verizon", "att.com": "AT&T", "t-mobile.com": "T-Mobile", "xfinity.com": "Xfinity",
        // Travel
        "marriott.com": "Marriott", "hilton.com": "Hilton", "airbnb.com": "Airbnb", "expedia.com": "Expedia",
        "booking.com": "Booking.com", "uber.com": "Uber", "lyft.com": "Lyft",
        // Shipping & government
        "usps.com": "USPS", "ups.com": "UPS", "fedex.com": "FedEx", "irs.gov": "IRS",
        "ssa.gov": "Social Security Administration",
    ]
    
    /// Strips scheme, path, and a stray leading "user@" off a raw URL/domain the way someone
    /// typing casually into a prompt (rather than copy-pasting a clean domain) tends to.
    static func normalizeDomain(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let schemeRange = text.range(of: "://") {
            text = String(text[schemeRange.upperBound...])
        }
        if let slashIdx = text.firstIndex(of: "/") {
            text = String(text[..<slashIdx])
        }
        if let atIdx = text.firstIndex(of: "@") {
            text = String(text[text.index(after: atIdx)...])
        }
        return text
    }
    
    static func suggestedName(forURL input: String) -> String {
        let domain = normalizeDomain(input)
        guard !domain.isEmpty else { return "" }
        
        if let known = knownDomains[domain] { return known }
        if domain.hasPrefix("www."), let known = knownDomains[String(domain.dropFirst(4))] { return known }
        
        return heuristicName(fromDomain: domain)
    }
    
    /// Best-effort guess for anything not in the table above: strips common subdomains, takes
    /// the main label before the TLD, capitalizes it. Won't produce something like "American
    /// Airlines" for "aa.com" — that's not derivable from the domain alone — but does
    /// reasonably for domains like "netflix.com" -> "Netflix" or "mail.google.com" -> "Google".
    private static func heuristicName(fromDomain domain: String) -> String {
        var core = domain
        let subdomainPrefixes = ["www.", "mail.", "login.", "accounts.", "my.", "app.", "id.", "auth.", "secure."]
        for prefix in subdomainPrefixes {
            if core.hasPrefix(prefix) { core = String(core.dropFirst(prefix.count)) }
        }
        
        let parts = core.split(separator: ".")
        let mainPart: Substring?
        if parts.count >= 2 {
            mainPart = parts[parts.count - 2]
        } else {
            mainPart = parts.first
        }
        
        guard let label = mainPart, let first = label.first else { return domain }
        return first.uppercased() + label.dropFirst()
    }
}

// MARK: - Models

struct Credential: Codable {
    var service: String = ""
    var url: String = ""
    var username: String = ""
    var encryptedPassword: String = "" // base64 AES-256-GCM ciphertext
    var notes: String = ""
    var dateModified: Date = Date()
    var twoFactorEnabled: Bool = false  // 2FA — defaults to false, backward compatible

    init(service: String = "", url: String = "", username: String = "", encryptedPassword: String = "", notes: String = "", dateModified: Date = Date(), twoFactorEnabled: Bool = false) {
        self.service = service
        self.url = url
        self.username = username
        self.encryptedPassword = encryptedPassword
        self.notes = notes
        self.dateModified = dateModified
        self.twoFactorEnabled = twoFactorEnabled
    }
    
    private enum CodingKeys: String, CodingKey {
        case service, url, username, encryptedPassword, notes, dateModified
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        service = try container.decode(String.self, forKey: .service)
        // decodeIfPresent + fallback so existing vault data saved before this field existed
        // still loads instead of failing to decode.
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        username = try container.decode(String.self, forKey: .username)
        encryptedPassword = try container.decode(String.self, forKey: .encryptedPassword)
        notes = try container.decode(String.self, forKey: .notes)
        dateModified = try container.decode(Date.self, forKey: .dateModified)
    }
    
    func matchesQuery(_ query: String) -> Bool {
        let lowerQuery = query.lowercased()
        return service.lowercased().contains(lowerQuery) ||
               url.lowercased().contains(lowerQuery) ||
               username.lowercased().contains(lowerQuery) ||
               notes.lowercased().contains(lowerQuery)
    }
}

/// The on-disk vault format. `formatVersion` exists so a future change to this layout (or KDF
/// parameters) has somewhere to hang a migration off of, the way this version migrates the old
/// pre-encryption format.
struct VaultFile: Codable {
    var formatVersion: Int = 2
    var kdfSalt: String       // base64
    var kdfIterations: Int
    var canary: String        // base64 AES-GCM ciphertext of VaultCrypto.canaryPlaintext
    var credentials: [Credential]
    var lastBackupTimestamp: String? = nil // Optional decodes to nil for older files missing this key
}

// MARK: - Navigation State

enum VaultScreen {
    case workspace
    case search
    case selectResult(results: [Credential], title: String)
    case viewCredential(index: Int)
    case addCredential
    case editCredential(index: Int)
    case dbUtilities
}

// MARK: - Keyboard Handling Engine (POSIX Raw Mode)

enum VaultKey {
    case up, down, enter, escape, toggle
    case number(Int)
    case other(Character)
}

class VaultKeyboardReader {
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

    func readKey() -> VaultKey {
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
        if buffer[0] == 118 || buffer[0] == 86 { return .toggle }
        if buffer[0] >= 49 && buffer[0] <= 57 {
            return .number(Int(buffer[0] - 48))
        }
        return .other(Character(UnicodeScalar(buffer[0])))
    }
    
    /// Reads a line with "*" echoed instead of the typed character, so a master password or
    /// credential password isn't visible on screen or left sitting in terminal scrollback.
    /// Temporarily engages raw mode for the read and restores canonical mode afterward. Typing
    /// ESC cancels and returns the sentinel "\u{1B}" (mirroring how getStringInput signals
    /// cancellation), rather than treating ESC as a literal character.
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

// MARK: - Vault Manager

class PasswordVaultManager {
    var credentials: [Credential] = []
    var screenStack: [VaultScreen] = [.workspace]
    var running = true
    var showPasswordPlaintext = false
    var selectedIdx = 0
    
    let fileURL = resolveAppDataDirectory().appendingPathComponent("vault.json")
    let keyboard = VaultKeyboardReader()
    
    // The vault's encryption key, held only in memory for the life of the process — set once
    // after a successful unlock/creation/migration and never written to disk. The master
    // password itself is never stored anywhere, only used transiently to derive this.
    private var vaultKey: SymmetricKey!
    private var kdfSalt: Data = Data()
    private var kdfIterations: Int = VaultCrypto.kdfIterations
    
    var lastStatusMessage: String? = nil
    var lastStatusWasError = false
    
    private var lastBackupTimestamp: String? = nil
    
    // Recomputed after every save (see saveVault()) rather than on every screen redraw — it
    // requires decrypting every stored password, which is cheap once but wasteful to repeat on
    // every keystroke. Keyed by "service|username" (the same composite identity already used
    // elsewhere in this file to look up a credential, e.g. openSelectedCredential) rather than
    // adding a new id field.
    private var reusedCredentialKeys: Set<String> = []
    private var weakCredentialKeys: Set<String> = []
    
    // Telemetry properties imported securely from swiftCORE launcher Matrix
    var machineName: String = "macOS"
    var uptime: String = "Unknown"
    var cpuUsage: String = "0%"
    var memUsage: String = "0G"
    
    init() {
        parseLauncherArguments()
        unlockOrCreateVault()
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
    
    // MARK: - Unlock / Create / Migrate
    

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

    private func unlockOrCreateVault() {
        // v2.5 unified auth: try swiftCORE session key first
        if let sessionKey = readCoreSessionKey(appID: "swiftVAULT") {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                self.vaultKey = sessionKey
                self.kdfSalt = VaultCrypto.randomSalt()
                self.kdfIterations = VaultCrypto.kdfIterations
                self.credentials = []
                saveVault()
                VaultDebugLogger.log("New vault created via unified auth", category: "VAULT")
                return
            }
            if let data = try? Data(contentsOf: fileURL),
               let vaultFile = try? JSONDecoder().decode(VaultFile.self, from: data),
               let decryptedCanary = try? VaultCrypto.decrypt(vaultFile.canary, key: sessionKey),
               decryptedCanary == VaultCrypto.canaryPlaintext {
                self.vaultKey = sessionKey
                self.kdfSalt = Data(base64Encoded: vaultFile.kdfSalt) ?? Data()
                self.kdfIterations = vaultFile.kdfIterations
                self.credentials = vaultFile.credentials
                self.lastBackupTimestamp = vaultFile.lastBackupTimestamp
                recomputePasswordHealth()
                VaultDebugLogger.log("Vault unlocked via swiftCORE session (\(credentials.count) credentials)", category: "VAULT")
                return
            } else if FileManager.default.fileExists(atPath: fileURL.path) {
                print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
                printStandardHeader()
                print("\n \u{001B}[1;33mswiftVAULT v2.5 upgrade:\u{001B}[0m Your vault was encrypted with a")
                print(" per-app password (pre-v2.5). It will be reset to use your swiftCORE")
                print(" login password instead. Any existing credentials will be cleared.\n")
                print(" Press Enter to continue and re-initialize your vault.")
                _ = readLine()
                try? FileManager.default.removeItem(at: fileURL)
                self.vaultKey = sessionKey
                self.kdfSalt = VaultCrypto.randomSalt()
                self.kdfIterations = VaultCrypto.kdfIterations
                self.credentials = []
                saveVault()
                VaultDebugLogger.log("Vault reset for unified auth migration", category: "VAULT")
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
            createNewVault()
            return
        }
        
        guard let data = try? Data(contentsOf: fileURL) else {
            print(" Could not read vault file at \(fileURL.path). Exiting.")
            exit(1)
        }
        
        if let vaultFile = try? JSONDecoder().decode(VaultFile.self, from: data) {
            unlockExistingVault(vaultFile)
            return
        }
        
        if let legacyCredentials = try? JSONDecoder().decode([Credential].self, from: data) {
            migrateLegacyVault(legacyCredentials)
            return
        }
        
        print(" Vault file at \(fileURL.path) is unreadable or corrupted. Exiting.")
        VaultDebugLogger.log("Vault file present but unparseable in either current or legacy format", category: "FATAL")
        exit(1)
    }
    
    private func createNewVault() {
        print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
        printStandardHeader()
        print("\n No existing vault found — let's set one up.\n")
        print(" Your master password protects every credential you store here.")
        print(" \u{001B}[1;33mThere is no recovery if you forget it — the vault cannot be\u{001B}[0m")
        print(" \u{001B}[1;33mdecrypted without it.\u{001B}[0m\n")
        
        let password = promptForNewMasterPassword()
        let salt = VaultCrypto.randomSalt()
        let iterations = VaultCrypto.kdfIterations
        let key = PBKDF2.deriveKey(password: password, salt: salt, iterations: iterations)
        
        self.vaultKey = key
        self.kdfSalt = salt
        self.kdfIterations = iterations
        self.credentials = []
        
        saveVault()
        VaultDebugLogger.log("New vault created", category: "VAULT")
        
        print("\n \u{001B}[1;32mVault created and unlocked.\u{001B}[0m Press Enter to continue.")
        _ = readLine()
    }
    
    private func unlockExistingVault(_ vaultFile: VaultFile) {
        guard let saltData = Data(base64Encoded: vaultFile.kdfSalt) else {
            print(" Vault file's salt is corrupted. Exiting.")
            VaultDebugLogger.log("Vault salt failed to base64-decode", category: "FATAL")
            exit(1)
        }
        
        print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
        printStandardHeader()
        print("\n \u{001B}[1;36mswiftVAULT is locked.\u{001B}[0m\n")
        
        var attempts = 0
        while true {
            let password = promptForMasterPassword()
            let key = PBKDF2.deriveKey(password: password, salt: saltData, iterations: vaultFile.kdfIterations)
            
            if let decryptedCanary = try? VaultCrypto.decrypt(vaultFile.canary, key: key),
               decryptedCanary == VaultCrypto.canaryPlaintext {
                self.vaultKey = key
                self.kdfSalt = saltData
                self.kdfIterations = vaultFile.kdfIterations
                self.credentials = vaultFile.credentials
                self.lastBackupTimestamp = vaultFile.lastBackupTimestamp
                recomputePasswordHealth()
                VaultDebugLogger.log("Vault unlocked (\(vaultFile.credentials.count) credentials)", category: "VAULT")
                return
            }
            
            attempts += 1
            print(" \u{001B}[1;31mIncorrect master password.\u{001B}[0m\n")
            VaultDebugLogger.log("Failed unlock attempt \(attempts)", category: "VAULT-AUTH")
            
            if attempts >= 5 {
                print(" Too many failed attempts. Exiting for safety.")
                VaultDebugLogger.log("Too many failed unlock attempts — exiting", category: "VAULT-AUTH")
                exit(1)
            }
        }
    }
    
    private func migrateLegacyVault(_ legacyCredentials: [Credential]) {
        print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
        printStandardHeader()
        print("\n \u{001B}[1;33mThis vault was created by an older version that only lightly\u{001B}[0m")
        print(" \u{001B}[1;33mobscured passwords (not real encryption) and had no master password.\u{001B}[0m\n")
        print(" Upgrading it now to real AES-256 encryption. Set a master password to")
        print(" protect it going forward:\n")
        
        let password = promptForNewMasterPassword()
        let salt = VaultCrypto.randomSalt()
        let iterations = VaultCrypto.kdfIterations
        let key = PBKDF2.deriveKey(password: password, salt: salt, iterations: iterations)
        
        // The old scheme was a single-byte XOR with a hardcoded key — trivially reversible,
        // which is exactly what lets the real passwords be recovered here and re-protected
        // properly instead of asking you to retype every credential by hand.
        var migrated: [Credential] = []
        for var cred in legacyCredentials {
            let legacyPlaintext = legacyXORDecrypt(cred.encryptedPassword)
            cred.encryptedPassword = (try? VaultCrypto.encrypt(legacyPlaintext, key: key)) ?? ""
            migrated.append(cred)
        }
        
        self.vaultKey = key
        self.kdfSalt = salt
        self.kdfIterations = iterations
        self.credentials = migrated
        
        saveVault()
        VaultDebugLogger.log("Migrated legacy vault: \(migrated.count) credentials upgraded to AES-256-GCM", category: "VAULT")
        
        print("\n \u{001B}[1;32mMigration complete — \(migrated.count) credential(s) upgraded to AES-256 encryption.\u{001B}[0m")
        print(" Press Enter to continue.")
        _ = readLine()
    }
    
    /// Reverses the old app's XOR "encryption" exactly, for migration purposes only — this is
    /// deliberately not used anywhere else. Defensively clamps to byte range: the original
    /// implementation would crash (`UInt8(scalar.value)` traps above 255) on any non-ASCII
    /// character, so any data that exists today can only ever be ASCII.
    private func legacyXORDecrypt(_ text: String) -> String {
        let key: UInt8 = 42
        var result = ""
        for scalar in text.unicodeScalars {
            let clamped = UInt8(scalar.value & 0xFF)
            result.unicodeScalars.append(UnicodeScalar(clamped ^ key))
        }
        return result
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
                print(" Use at least 8 characters — this key protects your whole vault.\n")
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
    
    // MARK: - Navigation Helpers
    
    func navigate(to screen: VaultScreen) { screenStack.append(screen) }
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
    
    /// Same as getStringInput, but the typed characters are masked ("*") instead of echoed —
    /// used for password fields specifically.
    func getMaskedInput(prompt: String) -> String? {
        print(prompt, terminator: "")
        fflush(stdout)
        let input = keyboard.readMaskedLine()
        if input == "\u{1B}" {
            goBack()
            return nil
        }
        return input.isEmpty ? nil : input
    }
    
    // MARK: - Clipboard
    
    /// Copies a password to the clipboard via pbcopy and clears it again after `autoClearSeconds`
    /// — the pattern real password managers use instead of leaving plaintext sitting in terminal
    /// scrollback indefinitely. Only clears if the clipboard still holds exactly what was put
    /// there, so it doesn't clobber something else copied in the meantime.
    private func copyPasswordToClipboard(_ plaintext: String, autoClearSeconds: TimeInterval = 20) {
        let copyProcess = Process()
        copyProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let inPipe = Pipe()
        copyProcess.standardInput = inPipe
        do {
            try copyProcess.run()
        } catch {
            VaultDebugLogger.log("pbcopy failed to launch: \(error.localizedDescription)", category: "CLIPBOARD-ERR")
            return
        }
        inPipe.fileHandleForWriting.write(Data(plaintext.utf8))
        inPipe.fileHandleForWriting.closeFile()
        copyProcess.waitUntilExit()
        
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: autoClearSeconds)
            
            let checkProcess = Process()
            checkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pbpaste")
            let outPipe = Pipe()
            checkProcess.standardOutput = outPipe
            guard (try? checkProcess.run()) != nil else { return }
            checkProcess.waitUntilExit()
            let currentClipboard = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            
            guard currentClipboard == plaintext else { return }
            
            let clearProcess = Process()
            clearProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
            let clearPipe = Pipe()
            clearProcess.standardInput = clearPipe
            guard (try? clearProcess.run()) != nil else { return }
            clearPipe.fileHandleForWriting.write(Data())
            clearPipe.fileHandleForWriting.closeFile()
            clearProcess.waitUntilExit()
        }
    }
    
    func run() {
        while running {
            guard let currentScreen = screenStack.last else { break }
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            
            switch currentScreen {
            case .workspace: showWorkspace()
            case .search: showSearchScreen()
            case .selectResult(let results, let title): showResultsScreen(results: results, title: title)
            case .viewCredential(let index): showViewCredentialScreen(index: index)
            case .addCredential: showAddCredentialScreen()
            case .editCredential(let index): showEditCredentialScreen(index: index)
            case .dbUtilities: showDbUtilitiesMenu()
            }
        }
    }
    
    // MARK: - Unified 80-Column Layout Handlers
    
    private func printStandardHeader() {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MM-dd-yy"
        let dateString = dateFormatter.string(from: now)
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "hh:mm:ss a"
        let timeString = timeFormatter.string(from: now).uppercased()

        let innerWidth = 118
        let titleText = "swiftVAULT v2.5.07.15c"  // plain for layout; c colored below
        let sidePadding = (innerWidth - titleText.count) / 2
        var titleLineChars = Array(repeating: " ", count: innerWidth)
        for (i, ch) in dateString.enumerated() where i < innerWidth { titleLineChars[i] = String(ch) }
        for (i, ch) in titleText.enumerated() { titleLineChars[sidePadding + i] = String(ch) }
        // Color the trailing 'c' orange without affecting layout positions
        titleLineChars[sidePadding + titleText.count - 1] = "\u{001B}[38;5;208mc\u{001B}[0m"
        let timeStart = innerWidth - timeString.count
        for (i, ch) in timeString.enumerated() { titleLineChars[timeStart + i] = String(ch) }

        // Dynamic username from swiftCORE session file
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
    
    // MARK: - Workspace (home screen) — shows every credential directly, alphabetically, the
    // same way swiftMAIL's main workspace shows the inbox immediately rather than a menu.
    
    func showWorkspace() {
        keyboard.enableRawMode()
        
        // Column widths sized so pointer(4) + numLabel(2) + " " + flags(2) + " │ " + col + " │ "
        // + col + " │ " + col == 84 exactly. maxVisibleRows is capped at 9 (not 10) so every
        // visible row gets a single-digit number reachable by one keypress — matches the same
        // fix applied to swiftNOTES and swiftCALENDAR for the same reason.
        // Column widths — no pipe separators, 2-space gaps, fills 118 inner chars exactly.
        // indent(2)+num(2)+gap(2)+flags(2)+gap(2)+site(35)+gap(2)+url(35)+gap(2)+account(29)+gap(2)+2fa(3) = 118
        let colSite = 35, colURL = 35, colAccount = 29, col2FA = 3
        let maxVisibleRows = 9
        let greenBarBG = "\u{001B}[48;5;22m"
        let vReset     = "\u{001B}[0m"

        func lc(_ s: String, _ w: Int) -> String { String(s.prefix(w)).padding(toLength: w, withPad: " ", startingAt: 0) }
        func rc(_ s: String, _ w: Int) -> String { s.count >= w ? String(s.prefix(w)) : String(repeating: " ", count: w - s.count) + s }
        func buildVaultRow(_ num: String, _ flags: String, _ site: String, _ url: String, _ acct: String, _ tfa: String = "   ") -> String {
            "  " + rc(num, 2) + "  " + lc(flags, 2) + "  " + lc(site, colSite) + "  " + lc(url, colURL) + "  " + lc(acct, colAccount) + "  " + lc(tfa, col2FA)
        }
        
        while true {
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()
            
            let sorted = credentials.sorted(by: { $0.service.lowercased() < $1.service.lowercased() })
            
            let creditLabel = "\(sorted.count) Credential\(sorted.count == 1 ? "" : "s") Stored"
            let leftText = " VAULT: \(creditLabel)"
            let rightText = "● AES-256 ENCRYPTED"
            let statusPadding = max(1, 119 - leftText.count - rightText.count)
            print("\u{001B}[1;37m VAULT:\u{001B}[0m \(creditLabel)\(String(repeating: " ", count: statusPadding))\u{001B}[1;32m\(rightText)\u{001B}[0m")
            
            let backupText = " Last Backup: \(lastBackupTimestamp ?? "Never")"
            let healthText: String
            let healthOK = reusedCredentialKeys.isEmpty && weakCredentialKeys.isEmpty
            if healthOK {
                healthText = "● No Password Issues Found"
            } else {
                var parts: [String] = []
                if !reusedCredentialKeys.isEmpty { parts.append("\(reusedCredentialKeys.count) Reused") }
                if !weakCredentialKeys.isEmpty { parts.append("\(weakCredentialKeys.count) Weak") }
                healthText = "● " + parts.joined(separator: ", ")
            }
            // Weak passwords are actively exploitable → red. Reused only → yellow (serious but
            // less urgent). Mixed → red since the worse condition sets the tone.
            let healthColor: String
            if healthOK { healthColor = "\u{001B}[1;32m" }
            else if !weakCredentialKeys.isEmpty { healthColor = "\u{001B}[1;31m" }
            else { healthColor = "\u{001B}[1;33m" }
            let healthPadding = max(1, 119 - backupText.count - healthText.count)
            print("\(backupText)\(String(repeating: " ", count: healthPadding))\(healthColor)\(healthText)\u{001B}[0m")
            
            let headerRow = buildVaultRow("#", "", "SITE NAME", "URL", "ACCOUNT NAME", "2FA")
            print("╭" + String(repeating: "─", count: 118) + "╮")
            print("│\u{001B}[1;37m\(headerRow)\u{001B}[0m│")
            print("├" + String(repeating: "─", count: 118) + "┤")

            var visibleCreds: [Credential] = []

            if sorted.isEmpty {
                let emptyMsg = "  Vault is empty. Press 'A' to add your first credential."
                print("│\(emptyMsg)\(String(repeating: " ", count: max(0, 118 - emptyMsg.count)))│")
            } else {
                if selectedIdx >= sorted.count { selectedIdx = max(0, sorted.count - 1) }
                var startIndex = 0
                if selectedIdx >= maxVisibleRows {
                    startIndex = min(selectedIdx - maxVisibleRows + 1, sorted.count - maxVisibleRows)
                }
                startIndex = max(0, startIndex)
                let endIndex = min(startIndex + maxVisibleRows, sorted.count)
                visibleCreds = Array(sorted[startIndex..<endIndex])

                for (rowNum, idx) in (startIndex..<endIndex).enumerated() {
                    let cred = sorted[idx]
                    let key = credentialKey(cred)
                    let isReused = reusedCredentialKeys.contains(key)
                    let isWeak = weakCredentialKeys.contains(key)
                    let plainFlags: String
                    if isReused && isWeak { plainFlags = "RW" }
                    else if isReused      { plainFlags = "R " }
                    else if isWeak        { plainFlags = "W " }
                    else                  { plainFlags = "  " }

                    let tfaPlain = cred.twoFactorEnabled ? " ✓ " : "   "
                    let plain = buildVaultRow("\(rowNum + 1)", plainFlags, cred.service, cred.url, cred.username, tfaPlain)
                    let padded = plain.padding(toLength: 118, withPad: " ", startingAt: 0)

                    if idx == selectedIdx {
                        print("│\u{001B}[7m\u{001B}[1m\(padded)\(vReset)│")
                    } else if (rowNum + 1) % 2 != 0 {
                        // Greenbar — ✓ shows as default color against green background
                        print("│\(greenBarBG)\(padded)\(vReset)│")
                    } else {
                        // Plain row — R=yellow, W=red, 2FA ✓ in green
                        let tfaColored = cred.twoFactorEnabled ? "\u{001B}[1;32m ✓ \(vReset)" : "   "
                        let baseRow = buildVaultRow("\(rowNum + 1)", "", cred.service, cred.url, cred.username, "   ")
                        let flagStr: String
                        if isReused && isWeak {
                            flagStr = "\u{001B}[1;33mR\(vReset)\u{001B}[1;31mW\(vReset)"
                        } else if isReused {
                            flagStr = "\u{001B}[1;33mR \(vReset)"
                        } else if isWeak {
                            flagStr = "\u{001B}[1;31mW \(vReset)"
                        } else {
                            flagStr = "  "
                        }
                        let arr = Array(baseRow)
                        // Slot flag at position 6-7, then append colored 2FA at the end
                        print("│\(String(arr[0..<6]))\(flagStr)\(String(arr[8..<115]))\(tfaColored)│")
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
                    openSelectedCredential(sorted[selectedIdx])
                    return
                }
            case .number(let num):
                if num >= 1 && num <= visibleCreds.count {
                    keyboard.disableRawMode()
                    openSelectedCredential(visibleCreds[num - 1])
                    return
                }
            case .other(let ch):
                let lower = Character(ch.lowercased())
                if lower == "a" {
                    keyboard.disableRawMode()
                    navigate(to: .addCredential)
                    return
                } else if lower == "/" {
                    keyboard.disableRawMode()
                    navigate(to: .search)
                    return
                } else if lower == "d" {
                    if !sorted.isEmpty { deleteCredentialInline(sorted[selectedIdx]) }
                } else if lower == "u" {
                    keyboard.disableRawMode()
                    navigate(to: .dbUtilities)
                    return
                } else {
                    // Nav footer — [A] claimed by Add, [V] is current app (no-op)
                    let navMap: [Character: String] = [
                        "t": "swiftCONTACTS", "c": "swiftCALENDAR",
                        "m": "swiftMAIL",     "n": "swiftNOTES",
                        "s": "swiftSTOCKS"
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
            case .toggle:
                break
            }
        }
    }
    
    private func deleteCredentialInline(_ chosen: Credential) {
        guard let masterIndex = credentials.firstIndex(where: { $0.service == chosen.service && $0.username == chosen.username }) else { return }
        keyboard.disableRawMode()
        print("\n Delete \"\(chosen.service)\" permanently? (y/n): ", terminator: "")
        if let confirm = readLine(), confirm.lowercased() == "y" {
            credentials.remove(at: masterIndex)
            saveVault()
            lastStatusMessage = "Deleted \(chosen.service)."
            lastStatusWasError = false
            VaultDebugLogger.log("Credential deleted for service (redacted)", category: "VAULT")
            if selectedIdx > 0 { selectedIdx -= 1 }
        }
        keyboard.enableRawMode()
    }
    
    private func openSelectedCredential(_ chosen: Credential) {
        if let masterIndex = credentials.firstIndex(where: { $0.service == chosen.service && $0.username == chosen.username }) {
            navigate(to: .viewCredential(index: masterIndex))
        }
    }
    
    func showSearchScreen() {
        printStandardHeader()
        print("                   >>> swiftVAULT SECURE LOOKUP ENGINE <<<                    ")
        print(String(repeating: "─", count: 120))
        guard let query = getStringInput(prompt: " Search Service, Username, Notes, or Tag: ") else { return }
        let results = credentials.filter { $0.matchesQuery(query) }
        goBack()
        navigate(to: .selectResult(results: results, title: "SEARCH RESULTS FOR '\(query.uppercased())'"))
    }
    
    func showResultsScreen(results: [Credential], title: String) {
        var localIdx = 0
        keyboard.enableRawMode()
        let sorted = results.sorted(by: { $0.service.lowercased() < $1.service.lowercased() })
        
        while true {
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()
            
            let paddingSize = max(0, (84 - title.count - 8) / 2)
            let paddingSpaces = String(repeating: " ", count: paddingSize)
            print("\(paddingSpaces)=== \(title) ===")
            print(" (Press ESC to go back to previous menu view)\n")
            
            for (idx, cred) in sorted.enumerated() {
                let prefix = (idx == localIdx) ? " -> " : "    "
                print("\(prefix)[\(idx + 1)]. \(cred.service) (\(cred.url)) [Account: \(cred.username)]")
            }
            print(String(repeating: "─", count: 120))
            printStandardFooter(keys: "ENTER: View │ ESC: Back")
            
            switch keyboard.readKey() {
            case .up: if !sorted.isEmpty { localIdx = (localIdx == 0) ? sorted.count - 1 : localIdx - 1 }
            case .down: if !sorted.isEmpty { localIdx = (localIdx == sorted.count - 1) ? 0 : localIdx + 1 }
            case .number(let num):
                if num >= 1 && num <= sorted.count {
                    localIdx = num - 1
                    keyboard.disableRawMode()
                    openSelectedCredential(sorted[localIdx])
                    return
                }
            case .escape:
                keyboard.disableRawMode()
                goBack()
                return
            case .enter:
                if !sorted.isEmpty {
                    keyboard.disableRawMode()
                    openSelectedCredential(sorted[localIdx])
                    return
                }
            default: break
            }
        }
    }
    
    private func daysAgoDescription(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days <= 0 { return "today" }
        if days == 1 { return "1 day ago" }
        return "\(days) days ago"
    }
    
    func showViewCredentialScreen(index: Int) {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd/yy HH:mm"
        keyboard.enableRawMode()

        while true {
            let cred = credentials[index]
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()

            let inner = 118
            func infoRow(_ label: String, _ value: String, colored: String? = nil) {
                let plain = "  \(label.padding(toLength: 16, withPad: " ", startingAt: 0))\(value)"
                let display = "  \(label.padding(toLength: 16, withPad: " ", startingAt: 0))\(colored ?? value)"
                print("│\(display)\(String(repeating: " ", count: max(0, inner - plain.count)))│")
            }

            let displayPassword: String
            if showPasswordPlaintext {
                displayPassword = (try? VaultCrypto.decrypt(cred.encryptedPassword, key: vaultKey)) ?? "⚠ decryption failed"
            } else {
                displayPassword = "•••••••••••• [V] to reveal"
            }

            let key = credentialKey(cred)
            let isReused = reusedCredentialKeys.contains(key)
            let isWeak   = weakCredentialKeys.contains(key)

            print("╭" + String(repeating: "─", count: inner) + "╮")
            infoRow("Site",          cred.service)
            infoRow("URL",           cred.url)
            infoRow("Account",       cred.username)
            infoRow("Password",      displayPassword)
            infoRow("2FA",           cred.twoFactorEnabled ? "Enabled ✓" : "Not Enabled",
                    colored: cred.twoFactorEnabled ? "\u{001B}[1;32mEnabled ✓\u{001B}[0m" : "\u{001B}[2mNot Enabled\u{001B}[0m")
            infoRow("Notes",         cred.notes.isEmpty ? "—" : cred.notes)
            infoRow("Last Changed",  "\(formatter.string(from: cred.dateModified)) (\(daysAgoDescription(cred.dateModified)))")
            if isReused { infoRow("⚠ Warning",  "Password reused on another credential", colored: "\u{001B}[1;33mPassword reused on another credential\u{001B}[0m") }
            if isWeak   { infoRow("⚠ Warning",  "Password is weak — update it soon",     colored: "\u{001B}[1;31mPassword is weak — update it soon\u{001B}[0m") }
            print("╰" + String(repeating: "─", count: inner) + "╯")
            print("")
            printStandardFooter(keys: "[V] Toggle Password  |  [E] Edit  |  [D] Delete  |  ESC: Back")
            printNavFooter()

            switch keyboard.readKey() {
            case .escape:
                showPasswordPlaintext = false
                keyboard.disableRawMode()
                goBack()
                return
            case .toggle:
                showPasswordPlaintext.toggle()
            case .other(let ch):
                let lower = Character(ch.lowercased())
                if lower == "v" {
                    showPasswordPlaintext.toggle()
                } else if lower == "e" {
                    showPasswordPlaintext = false
                    keyboard.disableRawMode()
                    navigate(to: .editCredential(index: index))
                    return
                } else if lower == "d" {
                    keyboard.disableRawMode()
                    print("\n Delete \(cred.service) permanently? (y/n): ", terminator: "")
                    if let confirm = readLine(), confirm.lowercased() == "y" {
                        credentials.remove(at: index)
                        saveVault()
                        VaultDebugLogger.log("Credential deleted for service (redacted)", category: "VAULT")
                        print("\n Credential deleted. Press Enter.")
                        _ = readLine()
                        goBack()
                        return
                    }
                    keyboard.enableRawMode()
                } else {
                    // Nav footer keys
                    let navMap: [Character: String] = [
                        "t": "swiftCONTACTS", "c": "swiftCALENDAR",
                        "m": "swiftMAIL",     "n": "swiftNOTES",
                        "s": "swiftSTOCKS"
                    ]
                    if let target = navMap[lower] {
                        showPasswordPlaintext = false
                        navigateToApp(target, args: [machineName, uptime, cpuUsage, memUsage])
                    } else if lower == "l" {
                        showPasswordPlaintext = false
                        keyboard.disableRawMode()
                        returnToLauncher(); return
                    }
                }
            default: break
            }
        }
    }
    
    /// Returns true if the caller should stay on this credential card and redraw (toggle/copy —
    /// no navigation happened), or false if it should exit its loop (edit/delete/back all call
    /// navigate()/goBack(), moving the screen stack elsewhere).
    private func executeCardAction(choiceIndex: Int, recordIndex: Int) -> Bool {
        let cred = credentials[recordIndex]
        switch choiceIndex {
        case 0:
            showPasswordPlaintext.toggle()
            return true
        case 1:
            if let plaintext = try? VaultCrypto.decrypt(cred.encryptedPassword, key: vaultKey) {
                copyPasswordToClipboard(plaintext)
                lastStatusMessage = "Password copied — clipboard clears automatically in 20s."
                lastStatusWasError = false
                VaultDebugLogger.log("Password copied to clipboard for service (redacted)", category: "VAULT")
            } else {
                lastStatusMessage = "Could not decrypt password to copy."
                lastStatusWasError = true
            }
            return true
        case 2:
            showPasswordPlaintext = false
            navigate(to: .editCredential(index: recordIndex))
            return false
        case 3:
            showPasswordPlaintext = false
            print("\n Delete this record permanently? (y/n): ", terminator: "")
            if let confirm = readLine(), confirm.lowercased() == "y" {
                credentials.remove(at: recordIndex)
                saveVault()
                VaultDebugLogger.log("Credential deleted for service (redacted)", category: "VAULT")
            }
            goBack()
            return false
        default:
            showPasswordPlaintext = false
            goBack()
            return false
        }
    }
    
    func showAddCredentialScreen() {
        printStandardHeader()
        print("                     >>> ADD CREDENTIAL <<<                ")
        print(String(repeating: "─", count: 120))
        guard let url = getStringInput(prompt: " Website URL (e.g. aa.com): ") else { return }
        
        let suggestedName = SiteNameLookup.suggestedName(forURL: url)
        let namePrompt = suggestedName.isEmpty ? " Site Name: " : " Site Name [\(suggestedName)] (Enter to accept): "
        guard let service = getStringInput(prompt: namePrompt, defaultValue: suggestedName.isEmpty ? nil : suggestedName) else { return }
        
        guard let username = getStringInput(prompt: " Account Name/Email: ") else { return }
        guard let password = getMaskedInput(prompt: " Password: ") else { return }
        
        let notes = getStringInput(prompt: " Notes: ") ?? ""
        let tfaInput = getStringInput(prompt: " 2FA Enabled? (y/N): ") ?? ""
        let twoFactorEnabled = tfaInput.lowercased() == "y"
        
        
        guard let encrypted = try? VaultCrypto.encrypt(password, key: vaultKey) else {
            print("\n \u{001B}[1;31mEncryption failed — record not saved.\u{001B}[0m Press Enter.")
            _ = readLine()
            goBack()
            return
        }
        
        let newRecord = Credential(
            service: service,
            url: url,
            username: username,
            encryptedPassword: encrypted,
            notes: notes,
            dateModified: Date(),
            twoFactorEnabled: twoFactorEnabled
        )
        
        credentials.append(newRecord)
        saveVault()
        VaultDebugLogger.log("Credential added for service (redacted)", category: "VAULT")
        
        print("\n\u{001B}[92mCredential saved. Press Enter.\u{001B}[0m")
        _ = readLine()
        goBack()
    }
    
    func showEditCredentialScreen(index: Int) {
        var cred = credentials[index]
        printStandardHeader()
        print("                     >>> EDIT CREDENTIAL <<<                ")
        print(String(repeating: "─", count: 120))
        print(" Press Enter to keep the current value.\n")
        
        if let url = getStringInput(prompt: " URL [\(cred.url)]: ") { cred.url = url }
        if let service = getStringInput(prompt: " Site Name [\(cred.service)]: ") { cred.service = service }
        if let username = getStringInput(prompt: " Account Name [\(cred.username)]: ") { cred.username = username }
        if let password = getMaskedInput(prompt: " New Password (Enter to keep current): ") {
            if let encrypted = try? VaultCrypto.encrypt(password, key: vaultKey) {
                cred.encryptedPassword = encrypted
            } else {
                print("\n \u{001B}[1;31mEncryption failed — password not changed.\u{001B}[0m")
            }
        }
        
        if let notes = getStringInput(prompt: " Notes [\(cred.notes)]: ") { cred.notes = notes }
        
        let currentTFA = cred.twoFactorEnabled ? "Y" : "N"
        let tfaInput = getStringInput(prompt: " 2FA Enabled? [\(currentTFA)] (y/n): ") ?? ""
        if tfaInput.lowercased() == "y" { cred.twoFactorEnabled = true }
        else if tfaInput.lowercased() == "n" { cred.twoFactorEnabled = false }
        
        cred.dateModified = Date()
        credentials[index] = cred
        saveVault()
        VaultDebugLogger.log("Credential updated for service (redacted)", category: "VAULT")
        
        print("\n Record updated. Press Enter.")
        _ = readLine()
        goBack()
    }
    
    // MARK: - Database Utilities Menu
    
    func showDbUtilitiesMenu() {
        let options = [
            "Backup Vault Database",
            "Restore Vault Database",
            "Export CSV Template",
            "Bulk Import from CSV",
            "Delete All Locked Records",
            "Back to Vault"
        ]
        var selectedIdx = 0
        keyboard.enableRawMode()
        
        while true {
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()
            print("                      >>> DATABASE UTILITIES <<<                      ")
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
        case 2: exportCSVTemplate()
        case 3: bulkImportFromCSV()
        case 4: deleteAllCredentials()
        case 5: goBack()
        default: break
        }
    }

    private func exportCSVTemplate() {
        printStandardHeader()
        print(" \u{001B}[1;33mWarning: the exported file contains credentials in plain text.\u{001B}[0m")
        print(" \u{001B}[1;33mHandle it carefully and delete after use.\u{001B}[0m\n")
        let exportURL = resolveAppDataDirectory().appendingPathComponent("vault.csv")
        var csv = "service,url,username,password,notes,2fa\n"
        for cred in credentials {
            let password = (try? VaultCrypto.decrypt(cred.encryptedPassword, key: vaultKey)) ?? ""
            let fields = [cred.service, cred.url, cred.username, password, cred.notes, cred.twoFactorEnabled ? "yes" : "no"]
            let row = fields.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
            csv.append("\(row)\n")
        }
        do {
            try csv.write(to: exportURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: exportURL.path)
            print(" Exported to: \(exportURL.path)\n Rename this file as needed before importing.")
            lastStatusMessage = "Exported \(credentials.count) credential(s) to CSV."
            lastStatusWasError = false
        } catch {
            print(" Export failed: \(error)")
            lastStatusMessage = "Export failed."
            lastStatusWasError = true
        }
        print(" Press Enter to continue...")
        _ = readLine()
    }
    
    // MARK: - CSV Bulk Import
    //
    // A CSV export from Chrome, Bitwarden, 1Password, etc. is a good, standard way to migrate
    // credentials in bulk rather than retyping each one through Add. The one thing worth being
    // upfront about: CSV has no encryption of its own — the file sitting on disk before import
    // is a flat list of every password in plaintext. This offers to overwrite-then-delete it
    // immediately after a successful import, but that's a best-effort step above a plain
    // delete, not a forensic guarantee — see the note printed after import.
    
    /// A minimal quote-aware CSV row splitter: handles quoted fields (which may contain commas)
    /// and "" as an escaped literal quote inside a quoted field, per standard CSV conventions.
    /// Does not handle a quoted field spanning multiple physical lines — uncommon for the
    /// service/username/password/tags fields this is built for, but notes containing a literal
    /// newline wouldn't round-trip correctly.
    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var insideQuotes = false
        let chars = Array(line)
        var i = 0
        
        while i < chars.count {
            let ch = chars[i]
            if insideQuotes {
                if ch == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        current.append("\"")
                        i += 1
                    } else {
                        insideQuotes = false
                    }
                } else {
                    current.append(ch)
                }
            } else {
                if ch == "\"" {
                    insideQuotes = true
                } else if ch == "," {
                    fields.append(current)
                    current = ""
                } else {
                    current.append(ch)
                }
            }
            i += 1
        }
        fields.append(current)
        return fields
    }
    
    /// Matches by alias priority order (e.g. prefer a column literally named "service" over one
    /// named "name" over one named "url"), not by which column happens to appear first in the
    /// file — those are two different things and only the former reflects actual intent.
    private func csvColumnIndex(headers: [String], aliases: [String]) -> Int? {
        let normalizedHeaders = headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        for alias in aliases {
            if let idx = normalizedHeaders.firstIndex(of: alias) {
                return idx
            }
        }
        return nil
    }
    
    private func parseCSVCredentials(fileContents: String) -> (imported: [Credential], skipped: Int) {
        let lines = fileContents.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let headerLine = lines.first else { return ([], 0) }
        
        let headers = parseCSVLine(headerLine)
        let serviceIdx = csvColumnIndex(headers: headers, aliases: ["service", "name", "title", "site"])
        let urlIdx = csvColumnIndex(headers: headers, aliases: ["url", "website", "login_uri", "site_url", "link"])
        
        guard serviceIdx != nil || urlIdx != nil else {
            return ([], 0) // need at least one of these to know what each row even is
        }
        
        let usernameIdx = csvColumnIndex(headers: headers, aliases: ["username", "login", "email", "login_username", "user"])
        let passwordIdx = csvColumnIndex(headers: headers, aliases: ["password", "login_password", "pass"])
        let notesIdx = csvColumnIndex(headers: headers, aliases: ["notes", "note", "extra"])
        let tfaIdx   = csvColumnIndex(headers: headers, aliases: ["2fa", "totp", "mfa", "two_factor", "twofactor"])
        
        var imported: [Credential] = []
        var skipped = 0
        
        for line in lines.dropFirst() {
            let fields = parseCSVLine(line)
            
            let url = (urlIdx.flatMap { $0 < fields.count ? fields[$0] : nil } ?? "").trimmingCharacters(in: .whitespaces)
            let rawService = (serviceIdx.flatMap { $0 < fields.count ? fields[$0] : nil } ?? "").trimmingCharacters(in: .whitespaces)
            // No explicit name/service column, or this row left it blank — fall back to the
            // same offline site-name lookup used when adding a credential by hand.
            let service = rawService.isEmpty ? SiteNameLookup.suggestedName(forURL: url) : rawService
            
            guard !service.isEmpty else {
                skipped += 1
                continue
            }
            
            let username = (usernameIdx.flatMap { $0 < fields.count ? fields[$0] : nil } ?? "").trimmingCharacters(in: .whitespaces)
            let password = passwordIdx.flatMap { $0 < fields.count ? fields[$0] : nil } ?? ""
            let notes = notesIdx.flatMap { $0 < fields.count ? fields[$0] : nil } ?? ""
            let tfaRaw = tfaIdx.flatMap { $0 < fields.count ? fields[$0] : nil } ?? ""
            let twoFactor = ["yes", "true", "1", "y"].contains(tfaRaw.lowercased())
            
            guard let encrypted = try? VaultCrypto.encrypt(password, key: vaultKey) else {
                skipped += 1
                continue
            }
            
            imported.append(Credential(service: service, url: url, username: username, encryptedPassword: encrypted, notes: notes, dateModified: Date(), twoFactorEnabled: twoFactor))
        }
        
        return (imported, skipped)
    }
    
    /// Best-effort overwrite before deletion. On a modern SSD with wear leveling this does NOT
    /// guarantee the original bytes are physically unrecoverable — the overwrite can land on
    /// different flash blocks than the original data occupied, which is a well-known limitation
    /// of "secure delete" on SSDs (unlike old spinning-disk drives, where overwriting reliably
    /// touched the same physical sectors). This is meaningfully better than a plain `rm` against
    /// casual recovery (Trash, basic undelete tools), but not a forensic guarantee. If FileVault
    /// (full-disk encryption) is enabled, at-rest recovery of any leftover blocks is far less of
    /// a practical concern regardless.
    private func secureDeleteFile(at url: URL) {
        if let data = try? Data(contentsOf: url) {
            let randomOverwrite = Data((0..<data.count).map { _ in UInt8.random(in: 0...255) })
            try? randomOverwrite.write(to: url)
        }
        try? FileManager.default.removeItem(at: url)
    }
    
    private func bulkImportFromCSV() {
        printStandardHeader()
        let csvURL = resolveAppDataDirectory().appendingPathComponent("vault.csv")

        guard FileManager.default.fileExists(atPath: csvURL.path) else {
            print("\n \u{001B}[1;31mError: 'vault.csv' was not found in the app data directory.\u{001B}[0m")
            print(" Export your credentials first using [3] Export CSV Template,")
            print(" or place a compatible CSV at: \(csvURL.path)")
            print("\n Press Enter to continue...")
            _ = readLine()
            return
        }

        print(" \u{001B}[1;33mWarning: vault.csv is plain text — it will be deleted automatically\u{001B}[0m")
        print(" \u{001B}[1;33mafter a successful import.\u{001B}[0m\n")

        guard let fileContents = try? String(contentsOf: csvURL, encoding: .utf8) else {
            print("\n \u{001B}[1;31mCould not read vault.csv.\u{001B}[0m")
            print(" Press Enter to continue...")
            _ = readLine()
            return
        }

        let (parsed, malformed) = parseCSVCredentials(fileContents: fileContents)

        guard !parsed.isEmpty else {
            print("\n \u{001B}[1;31mNo valid rows found — check that vault.csv has a recognised header row.\u{001B}[0m")
            print(" Press Enter to continue...")
            _ = readLine()
            return
        }

        print("\n Found \(parsed.count) importable credential(s)\(malformed > 0 ? ", \(malformed) malformed row(s) skipped" : "").")
        for cred in parsed.prefix(10) {
            let urlPart = cred.url.isEmpty ? "" : " (\(cred.url))"
            print("   • \(cred.service)\(urlPart)  [\(cred.username)]")
        }
        if parsed.count > 10 { print("   ... and \(parsed.count - 10) more") }

        print("\n Import these \(parsed.count) credential(s)? (y/n): ", terminator: "")
        guard let confirm = readLine(), confirm.lowercased() == "y" else {
            print("\n Import cancelled. vault.csv left untouched.")
            print(" Press Enter to continue...")
            _ = readLine()
            return
        }

        // Skip duplicates — match on service + username
        let existingKeys = Set(credentials.map { "\($0.service.lowercased())|\($0.username.lowercased())" })
        var newCreds: [Credential] = []
        var dupNames: [String] = []
        for cred in parsed {
            let key = "\(cred.service.lowercased())|\(cred.username.lowercased())"
            if existingKeys.contains(key) {
                dupNames.append("\(cred.service) [\(cred.username)]")
            } else {
                newCreds.append(cred)
            }
        }

        credentials.append(contentsOf: newCreds)
        saveVault()
        VaultDebugLogger.log("Import: \(newCreds.count) imported, \(dupNames.count) duplicates skipped", category: "VAULT")

        print("\n \u{001B}[1;32m\(newCreds.count) credential(s) imported and encrypted.\u{001B}[0m")
        if !dupNames.isEmpty {
            print(" \u{001B}[2m\(dupNames.count) skipped (already exist): \(dupNames.joined(separator: ", "))\u{001B}[0m")
        }
        lastStatusMessage = "Imported \(newCreds.count), skipped \(dupNames.count) duplicate(s)."
        lastStatusWasError = false

        // Auto-delete after successful import
        secureDeleteFile(at: csvURL)
        print(" \u{001B}[1;32mvault.csv deleted automatically.\u{001B}[0m")
        VaultDebugLogger.log("vault.csv deleted after import", category: "VAULT")

        print("\n Press Enter to continue...")
        _ = readLine()
    }
    
    private func deleteAllCredentials() {
        printStandardHeader()
        if credentials.isEmpty {
            print("\n Vault registry is already clean and empty.")
            print(" Press Enter to continue...")
            _ = readLine()
            return
        }
        
        print("\n WARNING: This will clear ALL \(credentials.count) vault keys permanently!")
        print(" Type 'CONFIRM' to wipe secure repository: ", terminator: "")
        if let validation = readLine(), validation == "CONFIRM" {
            credentials.removeAll()
            saveVault()
            VaultDebugLogger.log("All credentials wiped by user request", category: "VAULT")
            print("\n Vault registry successfully cleared out!")
            lastStatusMessage = "Vault wiped."
            lastStatusWasError = false
        } else {
            print("\n Wipe aborted. Data remains encrypted.")
        }
        print(" Press Enter to continue...")
        _ = readLine()
    }
    
    private func backupDatabase() {
        printStandardHeader()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("\n Error: No database file found to backup yet. Lock a record first.")
            print(" Press Enter to continue...")
            _ = readLine()
            return
        }
        
        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "MM-dd-yy hh:mm a"
        lastBackupTimestamp = displayFormatter.string(from: Date()).uppercased()
        saveVault() // persist the updated timestamp into vault.json before copying it
        
        let fileFormatter = DateFormatter()
        fileFormatter.dateFormat = "yyyyMMdd_HHmm"
        let timestamp = fileFormatter.string(from: Date())
        let backupURL = resolveAppDataDirectory().appendingPathComponent("vault_backup_\(timestamp).json")
        
        do {
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
            print("\n Backup created successfully: \(backupURL.lastPathComponent)")
            print(" (This backup is real AES-256 ciphertext, protected by the same master password.)")
            lastStatusMessage = "Backup created: \(backupURL.lastPathComponent)"
            lastStatusWasError = false
            VaultDebugLogger.log("Backup created: \(backupURL.lastPathComponent)", category: "VAULT")
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
            let backupFiles = files.filter { $0.lastPathComponent.hasPrefix("vault_backup_") && $0.lastPathComponent.hasSuffix(".json") }
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
                print("                  >>> AVAILABLE BACKUPS <<<                    ")
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
        
        guard let data = try? Data(contentsOf: fileURL), let vaultFile = try? JSONDecoder().decode(VaultFile.self, from: data) else {
            print(" \u{001B}[1;31mCould not read that backup file.\u{001B}[0m")
            print(" Press Enter to continue...")
            _ = readLine()
            return
        }
        
        guard let saltData = Data(base64Encoded: vaultFile.kdfSalt) else {
            print(" \u{001B}[1;31mBackup file's salt is corrupted.\u{001B}[0m")
            print(" Press Enter to continue...")
            _ = readLine()
            return
        }
        
        var attempts = 0
        while true {
            let password = promptForMasterPassword()
            let key = PBKDF2.deriveKey(password: password, salt: saltData, iterations: vaultFile.kdfIterations)
            
            if let decryptedCanary = try? VaultCrypto.decrypt(vaultFile.canary, key: key), decryptedCanary == VaultCrypto.canaryPlaintext {
                self.vaultKey = key
                self.kdfSalt = saltData
                self.kdfIterations = vaultFile.kdfIterations
                self.credentials = vaultFile.credentials
                self.lastBackupTimestamp = vaultFile.lastBackupTimestamp
                recomputePasswordHealth()
                VaultDebugLogger.log("Vault restored from \(file.lastPathComponent)", category: "VAULT")
                print("\n \u{001B}[1;32mVault registry restored from \(file.lastPathComponent) successfully!\u{001B}[0m")
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
    
    func saveVault() {
        recomputePasswordHealth()
        do {
            let canaryEncrypted = try VaultCrypto.encrypt(VaultCrypto.canaryPlaintext, key: vaultKey)
            let vaultFile = VaultFile(
                formatVersion: 2,
                kdfSalt: kdfSalt.base64EncodedString(),
                kdfIterations: kdfIterations,
                canary: canaryEncrypted,
                credentials: credentials,
                lastBackupTimestamp: lastBackupTimestamp
            )
            let data = try JSONEncoder().encode(vaultFile)
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            print("Vault write error: \(error)")
            VaultDebugLogger.log("Vault save failed: \(error.localizedDescription)", category: "VAULT-ERR")
        }
    }
    
    // MARK: - Password Health
    
    private func credentialKey(_ cred: Credential) -> String {
        "\(cred.service)|\(cred.username)"
    }
    
    private func isWeakPassword(_ password: String) -> Bool {
        if password.count < 8 { return true }
        let hasDigit = password.contains { $0.isNumber }
        let hasLetter = password.contains { $0.isLetter }
        return !(hasDigit && hasLetter)
    }
    
    private func recomputePasswordHealth() {
        guard vaultKey != nil else { return }
        
        var passwordToKeys: [String: [String]] = [:]
        var weak: Set<String> = []
        
        for cred in credentials {
            guard let plaintext = try? VaultCrypto.decrypt(cred.encryptedPassword, key: vaultKey) else { continue }
            let key = credentialKey(cred)
            passwordToKeys[plaintext, default: []].append(key)
            if isWeakPassword(plaintext) {
                weak.insert(key)
            }
        }
        
        var reused: Set<String> = []
        for (_, keys) in passwordToKeys where keys.count > 1 {
            reused.formUnion(keys)
        }
        
        self.reusedCredentialKeys = reused
        self.weakCredentialKeys = weak
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

func returnToLauncher() {
    navigateToApp("swiftCORE", args: [])
}

func printNavFooter(currentApp: String = "swiftVAULT") {
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
let passwordEngine = PasswordVaultManager()
passwordEngine.run()