import Foundation
import Network
import CryptoKit

// MARK: - Models

enum AccountType: String, Codable, CaseIterable {
    case google
    case icloud
    case yahoo
    case fastmail
    case custom
    
    var displayName: String {
        switch self {
        case .google: return "Gmail / Google Workspace"
        case .icloud: return "iCloud Mail"
        case .yahoo: return "Yahoo Mail"
        case .fastmail: return "Fastmail"
        case .custom: return "Other (enter server details manually)"
        }
    }
    
    // nil for .custom — there's no sensible default to guess, the person has to enter their own.
    var defaultIMAPHost: String? {
        switch self {
        case .google: return "imap.gmail.com"
        case .icloud: return "imap.mail.me.com"
        case .yahoo: return "imap.mail.yahoo.com"
        case .fastmail: return "imap.fastmail.com"
        case .custom: return nil
        }
    }
    var defaultSMTPHost: String? {
        switch self {
        case .google: return "smtp.gmail.com"
        case .icloud: return "smtp.mail.me.com"
        case .yahoo: return "smtp.mail.yahoo.com"
        case .fastmail: return "smtp.fastmail.com"
        case .custom: return nil
        }
    }
    
    // Best-known folder-naming convention per provider. There's no substitute for real
    // discovery here (IMAP's SPECIAL-USE extension, RFC 6154, is the protocol-correct way a
    // server tells a client which folder is Sent/Trash/Junk) — this implements the pragmatic
    // version instead: a reasonable guess per provider, always editable afterward if wrong for
    // a specific server.
    var defaultSentPath: String {
        switch self {
        case .google: return "\"[Gmail]/Sent Mail\""
        case .icloud, .fastmail: return "\"Sent Messages\""
        default: return "\"Sent\""
        }
    }
    var defaultJunkPath: String {
        switch self {
        case .google: return "\"[Gmail]/Spam\""
        case .yahoo: return "\"Bulk Mail\""
        default: return "\"Junk\""
        }
    }
    var defaultTrashPath: String {
        switch self {
        case .google: return "\"[Gmail]/Trash\""
        case .icloud, .fastmail: return "\"Deleted Messages\""
        default: return "\"Trash\""
        }
    }
}

struct EmailFolder: Codable {
    let name: String        // display label shown in the UI
    var serverPath: String  // actual IMAP mailbox path used for SELECT/APPEND
    var messages: [EmailMessage]
    // Server UIDs the user has deleted locally from this folder. Deleting locally does NOT
    // touch the server, so without this the next sync would just re-fetch the same message and
    // silently resurrect it. Kept per-folder since IMAP UIDs are only unique within a mailbox.
    var deletedServerUIDs: Set<Int>
    
    init(name: String, serverPath: String, messages: [EmailMessage] = [], deletedServerUIDs: Set<Int> = []) {
        self.name = name
        self.serverPath = serverPath
        self.messages = messages
        self.deletedServerUIDs = deletedServerUIDs
    }
    
    private enum CodingKeys: String, CodingKey {
        case name, serverPath, messages, deletedServerUIDs
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        messages = try container.decode([EmailMessage].self, forKey: .messages)
        // decodeIfPresent + fallback so existing mail_config.json files saved before these
        // fields existed still load instead of failing to decode.
        deletedServerUIDs = try container.decodeIfPresent(Set<Int>.self, forKey: .deletedServerUIDs) ?? []
        serverPath = try container.decodeIfPresent(String.self, forKey: .serverPath) ?? EmailFolder.defaultGmailServerPath(forDisplayName: name)
    }
    
    /// Bug fix: the app used to SELECT the literal display name ("SENT", "JUNK", "TRASH") against
    /// Gmail's IMAP server. Gmail's actual special-use mailbox names are different
    /// ("[Gmail]/Sent Mail", "[Gmail]/Spam", "[Gmail]/Trash"), so those SELECTs were just failing
    /// every time — switching to Sent/Junk/Trash and syncing never actually pulled anything.
    static func defaultGmailServerPath(forDisplayName name: String) -> String {
        switch name.uppercased() {
        case "INBOX": return "INBOX"
        case "SENT": return "\"[Gmail]/Sent Mail\""
        case "JUNK": return "\"[Gmail]/Spam\""
        case "TRASH": return "\"[Gmail]/Trash\""
        default: return name
        }
    }
}

struct EmailMessage: Codable {
    var id: Int
    var serverUID: Int? 
    var sender: String
    var subject: String
    var body: String
    var isUnread: Bool
    var hasGraphics: Bool
    var dateReceived: Date
}

struct EmailAccount: Codable, Identifiable {
    let id: UUID
    var emailAddress: String
    var tokenKey: String 
    var type: AccountType
    var imapHost: String
    var imapPort: Int
    var smtpHost: String
    var smtpPort: Int
    var folders: [EmailFolder]
    var activeFolderIndex: Int = 0
    
    init(id: UUID = UUID(), emailAddress: String, type: AccountType, tokenKey: String = "",
         imapHost: String? = nil, imapPort: Int = 993, smtpHost: String? = nil, smtpPort: Int = 465) {
        self.id = id
        self.emailAddress = emailAddress
        self.type = type
        self.tokenKey = tokenKey
        self.imapHost = imapHost ?? type.defaultIMAPHost ?? ""
        self.imapPort = imapPort
        self.smtpHost = smtpHost ?? type.defaultSMTPHost ?? ""
        self.smtpPort = smtpPort
        self.folders = [
            EmailFolder(name: "INBOX", serverPath: "INBOX", messages: []),
            EmailFolder(name: "SENT", serverPath: type.defaultSentPath, messages: []),
            EmailFolder(name: "JUNK", serverPath: type.defaultJunkPath, messages: []),
            EmailFolder(name: "TRASH", serverPath: type.defaultTrashPath, messages: [])
        ]
        self.activeFolderIndex = 0
    }
    
    private enum CodingKeys: String, CodingKey {
        case id, emailAddress, tokenKey, type, imapHost, imapPort, smtpHost, smtpPort, folders, activeFolderIndex
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        emailAddress = try container.decode(String.self, forKey: .emailAddress)
        tokenKey = try container.decode(String.self, forKey: .tokenKey)
        type = try container.decodeIfPresent(AccountType.self, forKey: .type) ?? .google
        // Existing accounts predate these fields and were always Gmail (the only option that
        // used to exist) — fall back to Gmail's real host/port so they keep connecting exactly
        // as before after this update, without needing to be re-entered.
        imapHost = try container.decodeIfPresent(String.self, forKey: .imapHost) ?? (type.defaultIMAPHost ?? "imap.gmail.com")
        imapPort = try container.decodeIfPresent(Int.self, forKey: .imapPort) ?? 993
        smtpHost = try container.decodeIfPresent(String.self, forKey: .smtpHost) ?? (type.defaultSMTPHost ?? "smtp.gmail.com")
        smtpPort = try container.decodeIfPresent(Int.self, forKey: .smtpPort) ?? 465
        folders = try container.decode([EmailFolder].self, forKey: .folders)
        activeFolderIndex = try container.decodeIfPresent(Int.self, forKey: .activeFolderIndex) ?? 0
    }
}

// MARK: - Application State

enum MailScreen {
    case mainWorkspace
    case accountSetup
    case editAccountSlot(accountIndex: Int)
    case readingPane(messageIndex: Int)
}

// MARK: - App Storage Location

/// Resolves the directory the compiled binary itself lives in — not the current working
/// directory (which varies depending on how the app is launched: double-click, Terminal cd'd
/// somewhere else, the swiftCORE launcher's execv, etc.) — so config/log files land in a stable,
/// predictable spot next to the binary. This intentionally keeps them inside the app's own
/// directory (rather than ~/Library/Application Support) so a folder-sync tool like Syncthing,
/// pointed at this directory, carries account list / read state / per-folder delete tombstones
/// between machines.
///
/// Still locks the file down to owner-only permissions (0600) on write — living in a synced
/// folder doesn't mean it should be group/world-readable.
func resolveAppDataDirectory() -> URL {
    let executablePath = CommandLine.arguments.first ?? "."
    let dir = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().deletingLastPathComponent()
    return dir
}

// MARK: - Contacts Integration (read-only, autocomplete only)
//
// Reads name/email directly from swiftCONTACTS' contacts.json — specifically only the fields
// that app deliberately stores unencrypted for exactly this purpose (see swiftCONTACTS' own
// design notes: name/email stay plaintext so other apps can use them without swiftCONTACTS'
// master password). This never touches that password or the encrypted "details" blob on each
// contact; it can't, since it isn't decrypting anything — Codable below simply ignores the JSON
// keys it wasn't asked to decode (kdfSalt, canary, encryptedDetails, etc).

private struct ContactAutocompleteEntry: Codable {
    var firstName: String = ""
    var lastName: String = ""
    var personalEmail: String = ""
    var workEmail: String = ""
}

private struct ContactsFileForAutocomplete: Codable {
    var contacts: [ContactAutocompleteEntry] = []
}

struct ContactMatch {
    let name: String
    let email: String
}

/// Returns an empty list (never throws/crashes) if swiftCONTACTS isn't installed, has no data
/// yet, or its file can't be read for any reason — autocomplete just quietly has nothing to
/// suggest rather than blocking mail from composing.
func loadContactAutocompleteEntries() -> [ContactMatch] {
    let contactsPath = resolveAppDataDirectory()
        .deletingLastPathComponent()
        .appendingPathComponent("swiftCONTACTS")
        .appendingPathComponent("contacts.json")
    
    guard let data = try? Data(contentsOf: contactsPath),
          let file = try? JSONDecoder().decode(ContactsFileForAutocomplete.self, from: data) else {
        return []
    }
    
    var matches: [ContactMatch] = []
    for c in file.contacts {
        let name = "\(c.firstName) \(c.lastName)".trimmingCharacters(in: .whitespaces)
        if !c.personalEmail.isEmpty { matches.append(ContactMatch(name: name, email: c.personalEmail)) }
        if !c.workEmail.isEmpty && c.workEmail != c.personalEmail { matches.append(ContactMatch(name: name, email: c.workEmail)) }
    }
    return matches
}

// MARK: - Debug Logger Infrastructure

class MailDebugLogger {
    static let logURL: URL = resolveAppDataDirectory().appendingPathComponent("swiftmail_debug.log")
    
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

// MARK: - Local Secure Crypto Storage Layer

class LocalCryptoEngine {
    private static var derivedKey: SymmetricKey {
        let salt = "swiftGMAIL_SymmetricSalt_System"
        var hash = SHA256()
        hash.update(data: salt.data(using: .utf8)!)
        let digest = hash.finalize()
        return SymmetricKey(data: digest)
    }
    
    static func encrypt(_ plaintext: String) -> String {
        guard !plaintext.isEmpty else { return "" }
        guard let data = plaintext.data(using: .utf8) else { return plaintext }
        do {
            let sealedBox = try AES.GCM.seal(data, using: derivedKey)
            return sealedBox.combined?.base64EncodedString() ?? plaintext
        } catch {
            return plaintext
        }
    }
    
    static func decrypt(_ base64Ciphertext: String) -> String {
        guard !base64Ciphertext.isEmpty, let data = Data(base64Encoded: base64Ciphertext) else { return base64Ciphertext }
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            let decryptedData = try AES.GCM.open(sealedBox, using: derivedKey)
            return String(data: decryptedData, encoding: .utf8) ?? base64Ciphertext
        } catch {
            return base64Ciphertext 
        }
    }
}

// MARK: - Keyboard Handling Engine

enum MailKeyPress {
    case up
    case down
    case enter
    case escape
    case tab
    case charMenu(Character)
}

class MailKeyboardReader {
    private var originalTermios = termios()

    func enableRawMode() {
        var raw = termios()
        tcgetattr(STDIN_FILENO, &originalTermios)
        raw = originalTermios
        raw.c_lflag &= ~(tcflag_t(ECHO) | tcflag_t(ICANON))
        
        withUnsafeMutableBytes(of: &raw.c_cc) { ptr in
            ptr[Int(VMIN)] = 1  
            ptr[Int(VTIME)] = 0 
        }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    }

    func disableRawMode() {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
    }

    func readKey() -> MailKeyPress {
        var buffer = [UInt8](repeating: 0, count: 3)
        _ = read(STDIN_FILENO, &buffer, 3)
        
        if buffer[0] == 9 { return .tab }
        if buffer[0] == 27 {
            if buffer[1] == 91 {
                switch buffer[2] {
                case 65: return .up
                case 66: return .down
                default: return .escape
                }
            }
            return .escape
        }
        if buffer[0] == 10 || buffer[0] == 13 { return .enter }
        return .charMenu(Character(UnicodeScalar(buffer[0])))
    }
    
    /// Same as `readKey()` but returns nil after `timeoutSeconds` if no key was pressed, instead
    /// of blocking forever. Passing `nil` blocks indefinitely, identical to plain `readKey()`.
    /// This is what lets the main loop repaint an in-progress sync's status bar in near-real-time
    /// instead of only refreshing once per keypress.
    func waitForKey(timeoutSeconds: Double?) -> MailKeyPress? {
        guard let timeoutSeconds = timeoutSeconds else {
            return readKey()
        }
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let timeoutMs = Int32(max(0, timeoutSeconds) * 1000)
        let ready = poll(&pfd, 1, timeoutMs)
        guard ready > 0 else { return nil } // 0 = timed out, <0 = interrupted/error
        return readKey()
    }

    func readCanonicalLine() -> String {
        var inputString = ""
        var buffer = [UInt8](repeating: 0, count: 1)
        
        while true {
            let bytesRead = read(STDIN_FILENO, &buffer, 1)
            if bytesRead <= 0 { continue }
            
            let byte = buffer[0]
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
                let scalar = UnicodeScalar(byte)
                let char = Character(scalar)
                inputString.append(char)
                print(char, terminator: "")
                fflush(stdout)
            }
        }
        return inputString
    }
    
    /// Same as `readCanonicalLine()` but echoes "*" instead of the typed character, so sensitive
    /// input like an app password isn't visible on screen or left sitting in terminal scrollback.
    func readMaskedLine() -> String {
        var inputString = ""
        var buffer = [UInt8](repeating: 0, count: 1)
        
        while true {
            let bytesRead = read(STDIN_FILENO, &buffer, 1)
            if bytesRead <= 0 { continue }
            
            let byte = buffer[0]
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
                let scalar = UnicodeScalar(byte)
                let char = Character(scalar)
                inputString.append(char)
                print("*", terminator: "")
                fflush(stdout)
            }
        }
        return inputString
    }
}

// MARK: - Native Secure Networking Stream Client
//
// Replaces the old single fire-and-forget `executeSecureCommand` design.
//
// The old design's "is this command done yet?" check was `responseString.contains(" OK ")`
// run against whatever chunk of bytes happened to arrive from the socket. That's broken in
// two serious ways:
//   1. Ordinary IMAP/SMTP data legitimately contains " OK " (an email body, an untagged
//      "* OK [PERMANENTFLAGS ...]" status line, etc), so the parser could decide a command
//      was "finished" mid-response and race ahead before the real data (like the EXISTS
//      count, or a message body) had even arrived.
//   2. After sending SMTP "DATA", the server replies "354 ..." — which contains neither
//      " OK " nor a completed transfer marker, so `isCommandFinished` never becomes true and
//      the code just sits calling readNext() forever. The queued message body is *never sent*.
//      It silently "succeeds" ~15s later only because EHLO/MAIL/RCPT earlier response chunks
//      happened to contain "250 " and flipped `overallSuccess` to true. So `send()` was
//      reporting success while the actual message contents never left the socket.
//
// The fixes below:
//   - Read the socket into a byte buffer and split strictly on real line boundaries, so a
//     response is only considered "finished" once its actual protocol-defined terminator
//     (a *tagged* IMAP status line, or a non-continuation "NNN " SMTP reply line) is seen.
//   - IMAP FETCH literals ({N}) are read as exactly N raw bytes rather than guessed from
//     string heuristics, so message bodies can't get truncated by a stray ")" character.
//   - SMTP DATA properly waits for "354" before transmitting the body, then reads the real
//     final "250" reply, instead of racing ahead blind.
//   - One TLS connection + one login is reused for an entire IMAP operation (select, fetch,
//     append, logout) instead of reconnecting and re-authenticating for every step, which is
//     what made sync/fetch/send feel slow — each avoided reconnect saves a full TLS handshake
//     + login round trip.

final class SecureLineConnection {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "swiftGMAIL.lineconn")
    private let bufferLock = NSLock()
    private var recvBuffer = Data()
    private let dataAvailable = DispatchSemaphore(value: 0)
    private var closed = false

    init?(host: String, port: UInt16, connectTimeout: TimeInterval = 8.0) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        connection = NWConnection(to: endpoint, using: .tls)

        let readySemaphore = DispatchSemaphore(value: 0)
        var didConnect = false

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                didConnect = true
                readySemaphore.signal()
            case .failed, .cancelled:
                readySemaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        _ = readySemaphore.wait(timeout: .now() + connectTimeout)

        guard didConnect else {
            connection.cancel()
            return nil
        }
        pumpReceive()
    }

    private func pumpReceive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.bufferLock.lock()
                self.recvBuffer.append(data)
                self.bufferLock.unlock()
                self.dataAvailable.signal()
            }
            if error != nil || isComplete {
                self.bufferLock.lock()
                self.closed = true
                self.bufferLock.unlock()
                self.dataAvailable.signal()
                return
            }
            self.pumpReceive()
        }
    }

    /// Blocking read of one CRLF-terminated line (CRLF stripped). nil on timeout/closed-with-no-data.
    func readLine(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        let crlf = Data([0x0D, 0x0A])

        while true {
            bufferLock.lock()
            if let range = recvBuffer.range(of: crlf) {
                let lineData = recvBuffer.subdata(in: recvBuffer.startIndex..<range.lowerBound)
                recvBuffer.removeSubrange(recvBuffer.startIndex..<range.upperBound)
                bufferLock.unlock()
                return String(data: lineData, encoding: .utf8)
            }
            let isClosed = closed
            let leftover = recvBuffer
            bufferLock.unlock()

            if isClosed {
                guard !leftover.isEmpty else { return nil }
                bufferLock.lock()
                recvBuffer.removeAll()
                bufferLock.unlock()
                return String(data: leftover, encoding: .utf8)
            }

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            _ = dataAvailable.wait(timeout: .now() + min(remaining, 1.0))
        }
    }

    /// Blocking read of exactly `length` raw bytes (used for IMAP literal syntax `{N}`,
    /// which may itself contain embedded CR/LF and must not be split into "lines").
    func readLiteral(length: Int, timeout: TimeInterval) -> String? {
        guard length > 0 else { return "" }
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            bufferLock.lock()
            if recvBuffer.count >= length {
                let end = recvBuffer.index(recvBuffer.startIndex, offsetBy: length)
                let literalData = recvBuffer.subdata(in: recvBuffer.startIndex..<end)
                recvBuffer.removeSubrange(recvBuffer.startIndex..<end)
                bufferLock.unlock()
                return String(data: literalData, encoding: .utf8) ?? ""
            }
            let isClosed = closed
            bufferLock.unlock()
            if isClosed { return nil }

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            _ = dataAvailable.wait(timeout: .now() + min(remaining, 1.0))
        }
    }

    func write(_ raw: String) {
        bufferLock.lock()
        let isClosed = closed
        bufferLock.unlock()
        guard !isClosed else { return }

        let sema = DispatchSemaphore(value: 0)
        connection.send(content: raw.data(using: .utf8), completion: .contentProcessed({ _ in
            sema.signal()
        }))
        _ = sema.wait(timeout: .now() + 10.0)
    }

    func writeLine(_ raw: String) {
        write(raw + "\r\n")
    }

    func close() {
        bufferLock.lock()
        closed = true
        bufferLock.unlock()
        connection.cancel()
    }

    var isAlive: Bool {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return !closed
    }
}

// MARK: - IMAP session (single persistent, authenticated connection)

struct IMAPResponse {
    let ok: Bool
    let statusLine: String
    let untagged: [String]
    let literals: [String]
}

final class IMAPSession {
    private let conn: SecureLineConnection
    private var tagCounter = 0

    init?(host: String, port: UInt16 = 993) {
        guard let c = SecureLineConnection(host: host, port: port) else { return nil }
        conn = c
        _ = conn.readLine(timeout: 8.0) // server greeting, e.g. "* OK Gimap ready..."
    }

    private func nextTag() -> String {
        tagCounter += 1
        return "T\(tagCounter)"
    }

    private func trailingLiteralLength(_ line: String) -> Int? {
        guard line.hasSuffix("}"), let openBrace = line.lastIndex(of: "{") else { return nil }
        return Int(line[line.index(after: openBrace)..<line.index(before: line.endIndex)])
    }

    /// Sends a tagged command and reads lines until the matching tagged status line arrives —
    /// the only protocol-correct definition of "this command is done".
    @discardableResult
    func command(_ text: String, timeout: TimeInterval = 20.0) -> IMAPResponse {
        let tag = nextTag()
        conn.writeLine("\(tag) \(text)")

        var untagged: [String] = []
        var literals: [String] = []
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, let line = conn.readLine(timeout: remaining) else {
                return IMAPResponse(ok: false, statusLine: "TIMEOUT waiting on \(tag)", untagged: untagged, literals: literals)
            }

            if line.hasPrefix("\(tag) ") {
                let ok = line.hasPrefix("\(tag) OK")
                return IMAPResponse(ok: ok, statusLine: line, untagged: untagged, literals: literals)
            }

            if let literalLength = trailingLiteralLength(line) {
                let literalText = conn.readLiteral(length: literalLength, timeout: deadline.timeIntervalSinceNow) ?? ""
                literals.append(literalText)
                untagged.append(line)
                continue
            }

            untagged.append(line)
        }
    }

    func login(user: String, password: String) -> Bool {
        let u = user.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let p = password.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return command("LOGIN \"\(u)\" \"\(p)\"", timeout: 10.0).ok
    }

    func select(folder: String) -> (ok: Bool, exists: Int) {
        let result = command("SELECT \(folder)", timeout: 10.0)
        var exists = 0
        for line in result.untagged where line.contains("EXISTS") {
            let parts = line.split(separator: " ")
            if let idx = parts.firstIndex(of: "EXISTS"), idx > 0, let n = Int(parts[idx - 1]) {
                exists = n
            }
        }
        return (result.ok, exists)
    }

    func fetchEnvelopes(range: String) -> [String] {
        // UID is requested alongside ENVELOPE so each message has a stable identifier across
        // syncs — plain IMAP sequence numbers shift whenever the mailbox changes, so they're
        // not safe to use for "did I already see/delete this one" tracking.
        command("FETCH \(range) (UID ENVELOPE)", timeout: 30.0).untagged
    }

    /// Fetches the entire raw message (headers + body) so MIME structure can be decoded locally.
    /// `.PEEK` is used so simply reading a message doesn't also set the server-side \Seen flag —
    /// this client tracks read/unread locally, so there's no need to mutate anything server-side.
    func fetchFullMessage(uid: Int) -> String {
        let result = command("UID FETCH \(uid) BODY.PEEK[]", timeout: 20.0)
        return result.literals.joined()
    }

    func append(folder: String, message: String) -> Bool {
        let byteCount = message.utf8.count
        let tag = nextTag()
        conn.writeLine("\(tag) APPEND \(folder) (\\Seen) {\(byteCount)}")

        guard let continuation = conn.readLine(timeout: 10.0), continuation.hasPrefix("+") else {
            return false
        }
        conn.write(message + "\r\n")

        let deadline = Date().addingTimeInterval(15.0)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, let line = conn.readLine(timeout: remaining) else { return false }
            if line.hasPrefix("\(tag) ") {
                return line.hasPrefix("\(tag) OK")
            }
        }
    }

    func logout() {
        _ = command("LOGOUT", timeout: 5.0)
        conn.close()
    }

    func close() {
        conn.close()
    }

    var isAlive: Bool {
        conn.isAlive
    }
}

// MARK: - SMTP session (proper multi-line reply codes, correct DATA handshake)

final class SMTPSession {
    private let conn: SecureLineConnection

    init?(host: String, port: UInt16 = 465) {
        guard let c = SecureLineConnection(host: host, port: port) else { return nil }
        conn = c
        _ = readReply(timeout: 8.0) // greeting, e.g. "220 smtp.gmail.com ESMTP ready"
    }

    /// Reads a full (possibly multi-line) SMTP reply. A reply is only complete once a line has
    /// its 4th character as a space (e.g. "250 ") rather than "-" (continuation, e.g. "250-").
    @discardableResult
    private func readReply(timeout: TimeInterval) -> (code: Int, ok: Bool, lines: [String]) {
        var lines: [String] = []
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, let line = conn.readLine(timeout: remaining) else {
                return (0, false, lines)
            }
            lines.append(line)
            guard line.count >= 4, let code = Int(line.prefix(3)) else { continue }
            let separator = line[line.index(line.startIndex, offsetBy: 3)]
            if separator == " " {
                return (code, (200..<400).contains(code), lines)
            }
            // separator == "-" means this is a continuation line; keep reading.
        }
    }

    @discardableResult
    func send(_ command: String, timeout: TimeInterval = 15.0) -> (code: Int, ok: Bool, lines: [String]) {
        conn.writeLine(command)
        return readReply(timeout: timeout)
    }

    /// Sends the message body after a "354" DATA continuation, terminated per RFC with a
    /// lone "." on its own line, and waits for the real final "250" reply.
    func sendData(_ body: String) -> (code: Int, ok: Bool, lines: [String]) {
        var payload = body
        if !payload.hasSuffix("\r\n") { payload += "\r\n" }
        payload += ".\r\n"
        conn.write(payload)
        return readReply(timeout: 20.0)
    }

    func close() {
        conn.close()
    }
}

// MARK: - MIME Decoding
//
// The old body-fetch just grabbed BODY[TEXT] and displayed it verbatim. That's fine for a bare
// plain-text message, but most real-world email today is multipart (text/plain + text/html,
// often plus attachments) and/or quoted-printable/base64 encoded — displaying that raw just
// shows MIME boundary markers and encoded gibberish instead of the message. This decodes a full
// raw RFC822 message (as fetched via BODY.PEEK[]) down to readable text.

enum MimeDecoder {
    /// Entry point: given a full raw message (headers + body), returns readable plain text.
    static func extractReadableBody(fromRawMessage raw: String) -> String {
        guard let headerEnd = raw.range(of: "\r\n\r\n") ?? raw.range(of: "\n\n") else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let headers = parseHeaders(String(raw[..<headerEnd.lowerBound]))
        let body = String(raw[headerEnd.upperBound...])
        let result = decodePart(headers: headers, body: body)
        return result.isEmpty ? "(This message has no readable text content.)" : result
    }
    
    /// Parses a block of RFC822 header lines into a lowercase-keyed dictionary, joining folded
    /// (continuation) lines that start with whitespace back onto the previous header.
    private static func parseHeaders(_ block: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentKey: String? = nil
        
        for rawLine in block.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if let first = line.first, (first == " " || first == "\t"), let key = currentKey {
                headers[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            if let colonIdx = line.firstIndex(of: ":") {
                let key = line[..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
                currentKey = key
            }
        }
        return headers
    }
    
    /// Decodes one MIME part (which may itself be multipart) into readable text, recursing for
    /// nested multipart structures (e.g. multipart/alternative inside multipart/mixed).
    private static func decodePart(headers: [String: String], body: String) -> String {
        let contentType = (headers["content-type"] ?? "text/plain").lowercased()
        let transferEncoding = (headers["content-transfer-encoding"] ?? "7bit").lowercased()
        
        if contentType.contains("multipart"), let boundary = extractBoundary(contentType) {
            var plainCandidate: String? = nil
            var htmlCandidate: String? = nil
            
            for part in splitMultipart(body: body, boundary: boundary) {
                guard let blankRange = part.range(of: "\r\n\r\n") ?? part.range(of: "\n\n") else { continue }
                let partHeaders = parseHeaders(String(part[..<blankRange.lowerBound]))
                let partBody = String(part[blankRange.upperBound...])
                let partContentType = (partHeaders["content-type"] ?? "text/plain").lowercased()
                
                if partContentType.contains("multipart") {
                    if plainCandidate == nil {
                        plainCandidate = decodePart(headers: partHeaders, body: partBody)
                    }
                } else if partContentType.contains("text/plain") && plainCandidate == nil {
                    plainCandidate = decodeTransferEncoding(partBody, encoding: (partHeaders["content-transfer-encoding"] ?? "7bit").lowercased())
                } else if partContentType.contains("text/html") && htmlCandidate == nil {
                    htmlCandidate = decodeTransferEncoding(partBody, encoding: (partHeaders["content-transfer-encoding"] ?? "7bit").lowercased())
                }
                // Anything else (attachments, images, etc.) is intentionally skipped — this is a
                // lightweight text-only reader, not a full mail client.
            }
            
            if let plain = plainCandidate, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return plain.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let html = htmlCandidate {
                return stripHTML(html).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return ""
        }
        
        let decoded = decodeTransferEncoding(body, encoding: transferEncoding)
        if contentType.contains("text/html") {
            return stripHTML(decoded).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private static func extractBoundary(_ contentTypeHeader: String) -> String? {
        guard let range = contentTypeHeader.range(of: "boundary=", options: .caseInsensitive) else { return nil }
        var value = String(contentTypeHeader[range.upperBound...])
        if let semi = value.firstIndex(of: ";") { value = String(value[..<semi]) }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }
    
    private static func splitMultipart(body: String, boundary: String) -> [String] {
        let delimiter = "--" + boundary
        let rawParts = body.components(separatedBy: delimiter)
        // First chunk is the preamble before the first boundary, last is the epilogue after the
        // closing "--boundary--" — only the parts in between are real MIME parts.
        guard rawParts.count > 2 else { return [] }
        return rawParts[1..<(rawParts.count - 1)].map { part in
            var p = part
            if p.hasPrefix("\r\n") { p.removeFirst(2) } else if p.hasPrefix("\n") { p.removeFirst(1) }
            return p
        }
    }
    
    private static func decodeTransferEncoding(_ text: String, encoding: String) -> String {
        switch encoding {
        case "base64":
            let cleaned = text.components(separatedBy: .whitespacesAndNewlines).joined()
            if let data = Data(base64Encoded: cleaned), let decoded = String(data: data, encoding: .utf8) {
                return decoded
            }
            return text
        case "quoted-printable":
            return decodeQuotedPrintable(text)
        default:
            return text
        }
    }
    
    private static func decodeQuotedPrintable(_ text: String) -> String {
        // Soft line breaks ("=" at end of line) just mean "this line continues" and get removed.
        let joined = text.replacingOccurrences(of: "=\r\n", with: "").replacingOccurrences(of: "=\n", with: "")
        let chars = Array(joined)
        var bytes: [UInt8] = []
        var i = 0
        while i < chars.count {
            if chars[i] == "=", i + 2 < chars.count, let hex = UInt8(String([chars[i + 1], chars[i + 2]]), radix: 16) {
                bytes.append(hex)
                i += 3
            } else {
                bytes.append(contentsOf: Array(String(chars[i]).utf8))
                i += 1
            }
        }
        return String(bytes: bytes, encoding: .utf8) ?? joined
    }
    
    /// Deliberately simple tag-stripping HTML-to-text conversion — good enough for a lightweight
    /// reader, not a real HTML renderer.
    private static func stripHTML(_ html: String) -> String {
        var text = html
        
        for tag in ["script", "style"] {
            while let openRange = text.range(of: "<\(tag)", options: .caseInsensitive),
                  let closeRange = text.range(of: "</\(tag)>", options: .caseInsensitive, range: openRange.upperBound..<text.endIndex) {
                text.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
            }
        }
        
        text = text.replacingOccurrences(of: "<br", with: "\n<br", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "</div>", with: "\n", options: .caseInsensitive)
        
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        }
        
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&rsquo;", "'"), ("&ldquo;", "\""), ("&rdquo;", "\"")
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Main Application Engine

class MailManager {
    var accounts: [EmailAccount] = []
    var activeAccountIndex = 0
    var screenStack: [MailScreen] = [.mainWorkspace]
    var running = true
    var selectedMessageIndex = 0
    
    private let dataLock = NSLock()
    
    var isSyncing = false
    var syncProgress: Double = 0.0
    var syncMessage = ""
    var lastAutoSyncTime: Date = Date()  // auto-sync every 15 minutes
    
    // Persists after a background operation (sync, message fetch, send) finishes, so a failure
    // is actually visible once the status bar goes back to idle instead of only ever appearing
    // in swiftmail_debug.log for a split second while isSyncing was still true.
    var lastStatusMessage: String? = nil
    var lastStatusWasError = false
    
    let fileURL = resolveAppDataDirectory().appendingPathComponent("mail_config.json")
    let keyboard = MailKeyboardReader()
    
    var machineName: String = "macOS"
    var uptime: String = "Unknown"
    var cpuUsage: String = "0%"
    var memUsage: String = "0G"
    
    private let networkMonitor = NWPathMonitor()
    private var isNetworkAvailable = true
    
    // A live, already-authenticated IMAP connection per account, reused across sync, opening
    // a message, and archiving sent mail. Without this, every single one of those actions pays
    // a fresh TLS handshake + IMAP LOGIN round trip (typically 0.5-1.5s to Gmail) before it does
    // any actual work — that's the biggest remaining cost, not the ENVELOPE fetch itself.
    private let networkLock = NSLock()
    private var imapSessionCache: [UUID: IMAPSession] = [:]
    
    // Serializes entire IMAP operations (e.g. "select + fetch" or "login + append") on the
    // shared connection above. Since sync now runs in the background while the UI keeps
    // accepting input (that's what makes the status bar live), it's possible to trigger a second
    // operation — e.g. composing and sending — while a sync from a moment ago is still running.
    // Two threads issuing commands on the same TCP connection at once scrambles the request/
    // response conversation: one operation can read the other's reply as if it were its own,
    // which can silently corrupt results or — as happened with a Sent-folder APPEND reading a
    // stray reply as failure and retrying — cause an operation to be repeated for real on the
    // server. This lock makes concurrent IMAP operations queue up and run one at a time instead.
    private let imapOperationLock = NSLock()
    
    init() {
        parseLauncherArguments()
        loadConfiguration()
        injectMockDataIfEmpty()
        startNetworkDiagnosticDaemon()
    }
    
    private func startNetworkDiagnosticDaemon() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            self?.dataLock.lock()
            self?.isNetworkAvailable = (path.status == .satisfied)
            self?.dataLock.unlock()
        }
        let queue = DispatchQueue(label: "swiftGMAIL.NetworkMonitor")
        networkMonitor.start(queue: queue)
    }
    
    /// Returns a live, already-authenticated IMAP connection for this account, reusing a
    /// cached one if it's still open. Only pays the TLS handshake + LOGIN cost when there's no
    /// live connection to reuse (first use, or after `forceNew`/an invalidated stale one).
    private func imapSession(for account: EmailAccount, forceNew: Bool = false) -> IMAPSession? {
        networkLock.lock()
        defer { networkLock.unlock() }
        
        if !forceNew, let existing = imapSessionCache[account.id], existing.isAlive {
            return existing
        }
        
        imapSessionCache[account.id]?.close()
        imapSessionCache[account.id] = nil
        
        guard let session = IMAPSession(host: account.imapHost, port: UInt16(clamping: account.imapPort)) else { return nil }
        let decryptedToken = LocalCryptoEngine.decrypt(account.tokenKey)
        guard session.login(user: account.emailAddress, password: decryptedToken) else {
            session.close()
            return nil
        }
        
        imapSessionCache[account.id] = session
        return session
    }
    
    private func invalidateIMAPSession(for account: EmailAccount) {
        networkLock.lock()
        imapSessionCache[account.id]?.close()
        imapSessionCache[account.id] = nil
        networkLock.unlock()
    }
    
    /// SELECTs a folder on a reused session; if that fails (e.g. Gmail dropped an idle
    /// connection), transparently reconnects once and retries, rather than failing outright.
    private func selectFolder(_ folder: String, account: EmailAccount) -> (session: IMAPSession, exists: Int)? {
        if let session = imapSession(for: account) {
            let (ok, exists) = session.select(folder: folder)
            if ok { return (session, exists) }
            invalidateIMAPSession(for: account)
        }
        if let session = imapSession(for: account, forceNew: true) {
            let (ok, exists) = session.select(folder: folder)
            if ok { return (session, exists) }
            invalidateIMAPSession(for: account)
        }
        return nil
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
    
    func run() {
        while running {
            guard let currentScreen = screenStack.last else {
                running = false
                break
            }
            
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            
            switch currentScreen {
            case .mainWorkspace:
                showMainWorkspace()
            case .accountSetup:
                showAccountMatrix()
            case .editAccountSlot(let idx):
                showEditSlotScreen(accountIndex: idx)
            case .readingPane(let msgIdx):
                showReadingPane(index: msgIdx)
            }
        }
    }
    
    private func printStandardHeader() {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MM-dd-yy"
        let dateString = dateFormatter.string(from: now)
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "hh:mm:ss a"
        let timeString = timeFormatter.string(from: now).uppercased()

        let innerWidth = 118
        let titleText = "swiftMAIL v2.5.07.16c"  // plain for layout; c colored below
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

    
    private func renderStatusBar() {
        let width = 30
        dataLock.lock()
        let syncingState = isSyncing
        let progressVal = syncProgress
        let msg = syncMessage
        let lastMsg = lastStatusMessage
        let lastIsError = lastStatusWasError
        dataLock.unlock()
        
        if syncingState {
            let completedCount = Int(progressVal * Double(width))
            let remainderCount = max(0, width - completedCount)
            print(" \u{001B}[1;36mStatus: [\(String(repeating: "█", count: completedCount))\(String(repeating: "░", count: remainderCount))] \(msg)\u{001B}[0m")
        } else if let lastMsg = lastMsg {
            let color = lastIsError ? "\u{001B}[1;31m" : "\u{001B}[1;32m"
            let label = lastIsError ? "Error" : "Done"
            print(" \(color)Status: [ \(label) ] \(lastMsg)\u{001B}[0m")
        } else {
            print(" Status: \u{001B}[1;32m[ Idle ] System connected and ready.\u{001B}[0m")
        }
    }
    
    /// Runs `work` on a background thread while animating a small inline spinner at the current
    /// cursor position, then clears the line once it's done. Blocks the calling thread until
    /// `work` finishes (this app is single-threaded/synchronous by design), but gives visible
    /// feedback instead of the terminal just silently sitting there during a network round trip.
    private func runWithSpinner(message: String, work: @escaping () -> Void) {
        let doneLock = NSLock()
        var isDone = false
        
        Thread.detachNewThread {
            work()
            doneLock.lock()
            isDone = true
            doneLock.unlock()
        }
        
        let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        var frameIdx = 0
        while true {
            doneLock.lock()
            let finished = isDone
            doneLock.unlock()
            if finished { break }
            
            print("\r \u{001B}[1;36m\(frames[frameIdx % frames.count]) \(message)\u{001B}[0m", terminator: "")
            fflush(stdout)
            frameIdx += 1
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        print("\r" + String(repeating: " ", count: message.count + 4) + "\r", terminator: "")
        fflush(stdout)
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
    
    // MARK: - Workspace Workflows
    
    /// Renders the full main workspace screen (header, message list, status bar, footer) and
    /// returns the account/message-list it drew, so callers don't have to re-derive them.
    /// Pulled out of showMainWorkspace() so it can be called repeatedly from a repaint loop
    /// while a sync is in progress, without also blocking on a keypress each time.
    @discardableResult
    private func renderWorkspaceScreen() -> (account: EmailAccount, messageList: [EmailMessage]) {
        dataLock.lock()
        let totalAccounts = accounts.count
        let netStatus = isNetworkAvailable
        if activeAccountIndex >= totalAccounts {
            activeAccountIndex = 0
        }
        let account = accounts[activeAccountIndex]
        dataLock.unlock()
        
        let folder = account.folders[account.activeFolderIndex]
        let messageList = folder.messages
        
        // Keep the selection in range in case a background sync just replaced the message list
        // with a shorter one (e.g. after switching folders or re-syncing a smaller mailbox).
        if selectedMessageIndex >= messageList.count {
            selectedMessageIndex = max(0, messageList.count - 1)
        }
        
        // Colors mapping explicitly to server connection context state
        let addressColor = netStatus ? "\u{001B}[1;32m" : "\u{001B}[1;31m" 
        let resetColor = "\u{001B}[0m"
        
        printStandardHeader()
        
        // Compute alignment calculations dynamically for appending status indicator at far right
        let netIndicatorRaw = netStatus ? "● ONLINE" : "● OFFLINE"
        let netIndicatorColored = netStatus ? "\u{001B}[1;32m● ONLINE\u{001B}[0m" : "\u{001B}[1;31m● OFFLINE\u{001B}[0m"
        
        // Revised alignment for consistent wrapping
        let leftSideText = " ACCOUNT: [\(activeAccountIndex + 1)/\(totalAccounts)] \(account.emailAddress)  ──►  FOLDER: [ \(folder.name) ] (\(messageList.count) Messages)"
        let paddingSize = max(2, 119 - leftSideText.count - netIndicatorRaw.count)
        let middleSpaces = String(repeating: " ", count: paddingSize)
        
        // Print the primary context line cleanly with all embedded ANSI metrics and used variables
        print(" \u{001B}[1;37mACCOUNT:\u{001B}[0m [\(activeAccountIndex + 1)/\(totalAccounts)] \(addressColor)\(account.emailAddress)\(resetColor)  ──►  \u{001B}[1;37mFOLDER:\u{001B}[0m [ \u{001B}[1;36m\(folder.name)\u{001B}[0m ] (\(messageList.count) Messages)\(middleSpaces)\(netIndicatorColored)")
        renderStatusBar()
        
        // Grid box — pipe-free, greenbar, auto-sizes to message count
        // ptr(4)+dot(2)+num(2)+gap(2)+date(5)+gap(2)+sender(30)+gap(2)+subject(69) = 118
        let colSender = 30, colSubject = 69
        let greenBG   = "\u{001B}[48;5;22m"
        let mReset    = "\u{001B}[0m"
        func lm(_ s: String, _ w: Int) -> String { String(s.prefix(w)).padding(toLength: w, withPad: " ", startingAt: 0) }
        func rm(_ s: String, _ w: Int) -> String { s.count >= w ? String(s.prefix(w)) : String(repeating: " ", count: w - s.count) + s }
        func buildMailRow(_ ptr: String, _ dot: String, _ num: String, _ date: String, _ sender: String, _ subj: String) -> String {
            ptr + dot + rm(num, 2) + "  " + lm(date, 5) + "  " + lm(sender, colSender) + "  " + lm(subj, colSubject)
        }

        let headerRow = buildMailRow("    ", "  ", "#", "DATE", "FROM", "SUBJECT")
        print("╭" + String(repeating: "─", count: 118) + "╮")
        print("│\u{001B}[1;37m\(headerRow)\u{001B}[0m│")
        print("├" + String(repeating: "─", count: 118) + "┤")

        if messageList.isEmpty {
            let emptyMsg = "  No messages. Press R to sync."
            print("│\(emptyMsg)\(String(repeating: " ", count: 118 - emptyMsg.count))│")
        } else {
            let maxVisibleRows = 13
            var startIndex = 0
            if selectedMessageIndex >= maxVisibleRows {
                startIndex = min(selectedMessageIndex - maxVisibleRows + 1, messageList.count - maxVisibleRows)
            }
            startIndex = max(0, startIndex)
            let endIndex = min(startIndex + maxVisibleRows, messageList.count)

            let dtFormatter = DateFormatter()
            dtFormatter.dateFormat = "MM/dd"

            for (rowNum, idx) in (startIndex..<endIndex).enumerated() {
                let msg = messageList[idx]
                let ptr    = (idx == selectedMessageIndex) ? " -> " : "    "
                let dot    = msg.isUnread ? "• " : "  "
                let date   = dtFormatter.string(from: msg.dateReceived)
                let plain  = buildMailRow(ptr, dot, "\(idx + 1)", date, msg.sender, msg.subject)
                let padded = plain.padding(toLength: 118, withPad: " ", startingAt: 0)

                if idx == selectedMessageIndex {
                    print("│\u{001B}[7m\u{001B}[1m\(padded)\(mReset)│")
                } else if (rowNum + 1) % 2 != 0 {
                    print("│\(greenBG)\(padded)\(mReset)│")
                } else {
                    // Unread messages in bold on plain rows
                    if msg.isUnread {
                        print("│\u{001B}[1m\(plain)\(mReset)│")
                    } else {
                        print("│\(plain)│")
                    }
                }
            }
        }

        print("╰" + String(repeating: "─", count: 118) + "╯")
        printStandardFooter(keys: "R: Sync | TAB: Account | F: Folder | W: Compose | D: Delete | A: Setup")
        printNavFooter()
        fflush(stdout)
        
        return (account, messageList)
    }
    
    func showMainWorkspace() {
        keyboard.enableRawMode()
        
        dataLock.lock()
        let totalAccounts = accounts.count
        dataLock.unlock()
        
        if totalAccounts == 0 {
            printStandardHeader()
            print("\n\n                  No local email accounts provisioned.")
            print("                  Press 'A' to open Account Setup and add one.")
            for _ in 0..<11 { print("") }
            print(String(repeating: "─", count: 120))
            renderStatusBar()
            printStandardFooter(keys: "A: Setup")
            printNavFooter()
            
            switch keyboard.readKey() {
            case .charMenu(let char):
                if char.lowercased() == "a" {
                    keyboard.disableRawMode()
                    screenStack.append(.accountSetup)
                }
            case .escape:
                keyboard.disableRawMode()
                returnToLauncher()
                running = false
            default: break
            }
            return
        }
        
        // Render, then wait for a key. While a sync is running in the background, poll with a
        // short timeout instead of blocking indefinitely, repainting on every timeout so the
        // status bar's progress and message actually move instead of freezing at whatever value
        // happened to be current the one time the screen got drawn. Once idle, this behaves
        // exactly like a plain blocking read, same as before.
        var pressedKey: MailKeyPress? = nil
        var messageList: [EmailMessage] = []
        
        while pressedKey == nil {
            (_, messageList) = renderWorkspaceScreen()
            
            dataLock.lock()
            let stillSyncing = isSyncing
            dataLock.unlock()
            
            // While syncing: repaint every 0.15s for live progress bar
            // While idle: check every 60s so the 15-minute auto-sync fires on time
            pressedKey = keyboard.waitForKey(timeoutSeconds: stillSyncing ? 0.15 : 60.0)
            
            if pressedKey == nil {
                // Check if 15 minutes have elapsed since last sync — auto-refresh
                if Date().timeIntervalSince(lastAutoSyncTime) >= 15 * 60 {
                    lastAutoSyncTime = Date()
                    executeLiveNetworkRefresh()
                }
                print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            }
        }
        
        switch pressedKey! {
        case .up:
            if !messageList.isEmpty {
                selectedMessageIndex = (selectedMessageIndex == 0) ? messageList.count - 1 : selectedMessageIndex - 1
            }
        case .down:
            if !messageList.isEmpty {
                selectedMessageIndex = (selectedMessageIndex == messageList.count - 1) ? 0 : selectedMessageIndex + 1
            }
        case .tab:
            dataLock.lock()
            if !accounts.isEmpty {
                activeAccountIndex = (activeAccountIndex + 1) % accounts.count
            }
            dataLock.unlock()
            selectedMessageIndex = 0
            executeLiveNetworkRefresh()
            
        case .enter:
            if !messageList.isEmpty {
                keyboard.disableRawMode()
                let indexToFetch = selectedMessageIndex
                print("")
                runWithSpinner(message: "Fetching message content...") { [weak self] in
                    self?.fetchTargetMessageBody(index: indexToFetch)
                }
                screenStack.append(.readingPane(messageIndex: selectedMessageIndex))
            }
        case .charMenu(let char):
            let lowerChar = char.lowercased()
            if lowerChar == "r" {
                executeLiveNetworkRefresh()
            } else if lowerChar == "f" {
                dataLock.lock()
                if !accounts.isEmpty {
                    var targetAccount = accounts[activeAccountIndex]
                    targetAccount.activeFolderIndex = (targetAccount.activeFolderIndex + 1) % targetAccount.folders.count
                    accounts[activeAccountIndex] = targetAccount
                }
                dataLock.unlock()
                selectedMessageIndex = 0
                executeLiveNetworkRefresh()
            } else if lowerChar == "w" {
                composePlaintextMail()
            } else if lowerChar == "d" {
                if !messageList.isEmpty {
                    dataLock.lock()
                    let folderIdx = accounts[activeAccountIndex].activeFolderIndex
                    let removedMessage = accounts[activeAccountIndex].folders[folderIdx].messages[selectedMessageIndex]
                    if let removedUID = removedMessage.serverUID {
                        // Tombstone it so the next sync doesn't just fetch it back — deleting
                        // locally doesn't touch the server copy.
                        accounts[activeAccountIndex].folders[folderIdx].deletedServerUIDs.insert(removedUID)
                    }
                    accounts[activeAccountIndex].folders[folderIdx].messages.remove(at: selectedMessageIndex)
                    if selectedMessageIndex >= accounts[activeAccountIndex].folders[folderIdx].messages.count {
                        selectedMessageIndex = max(0, accounts[activeAccountIndex].folders[folderIdx].messages.count - 1)
                    }
                    saveConfiguration()
                    dataLock.unlock()
                }
            } else if lowerChar == "a" {
                keyboard.disableRawMode()
                screenStack.append(.accountSetup)
            } else {
                // Nav footer — [C] is claimed by Compose; Calendar not reachable from workspace
                let navMap: [Character: String] = [
                    "t": "swiftCONTACTS", "c": "swiftCALENDAR",
                    "n": "swiftNOTES",    "s": "swiftSTOCKS",
                    "v": "swiftVAULT"
                ]
                if let target = navMap[Character(lowerChar)] {
                    keyboard.disableRawMode()
                    navigateToApp(target, args: [machineName, uptime, cpuUsage, memUsage])
                    running = false
                    return
                } else if lowerChar == "l" {
                    keyboard.disableRawMode()
                    returnToLauncher()
                    running = false
                }
            }
        case .escape:
            keyboard.disableRawMode()
            returnToLauncher()
            running = false
        }
    }
    
    private func fetchTargetMessageBody(index: Int) {
        dataLock.lock()
        guard activeAccountIndex < accounts.count else { dataLock.unlock(); return }
        let currentAccount = accounts[activeAccountIndex]
        let currentFolder = currentAccount.folders[currentAccount.activeFolderIndex].serverPath
        let targetMsg = currentAccount.folders[currentAccount.activeFolderIndex].messages[index]
        dataLock.unlock()
        
        guard let serverUID = targetMsg.serverUID else { return }
        
        imapOperationLock.lock()
        defer { imapOperationLock.unlock() }
        
        func setBody(_ text: String) {
            dataLock.lock()
            if activeAccountIndex < accounts.count {
                let folderIdx = accounts[activeAccountIndex].activeFolderIndex
                if index < accounts[activeAccountIndex].folders[folderIdx].messages.count {
                    accounts[activeAccountIndex].folders[folderIdx].messages[index].body = text
                    saveConfiguration()
                }
            }
            dataLock.unlock()
        }
        
        guard let (session, _) = selectFolder(currentFolder, account: currentAccount) else {
            setBody("⚠ Could not connect to imap.gmail.com to fetch this message.\n\nCheck your network connection and app password, then press ESC and ENTER again to retry.")
            dataLock.lock()
            lastStatusMessage = "Failed to fetch message body."
            lastStatusWasError = true
            dataLock.unlock()
            return
        }
        
        let rawMessage = session.fetchFullMessage(uid: serverUID)
        // Connection is intentionally left open (no logout/close) so the next sync or message
        // open reuses it instead of paying another TLS handshake + login.
        
        guard !rawMessage.isEmpty else {
            setBody("⚠ The server returned no content for this message. It may have been moved or deleted on the server since the last sync.")
            dataLock.lock()
            lastStatusMessage = "Message fetch returned no content."
            lastStatusWasError = true
            dataLock.unlock()
            return
        }
        
        setBody(MimeDecoder.extractReadableBody(fromRawMessage: rawMessage))
    }

    func showReadingPane(index: Int) {
        dataLock.lock()
        guard activeAccountIndex < accounts.count else { dataLock.unlock(); return }
        var account = accounts[activeAccountIndex]
        var folder = account.folders[account.activeFolderIndex]
        var targetMessage = folder.messages[index]
        
        targetMessage.isUnread = false
        folder.messages[index] = targetMessage
        account.folders[account.activeFolderIndex] = folder
        accounts[activeAccountIndex] = account
        saveConfiguration()
        dataLock.unlock()
        
        printStandardHeader()

        let inner = 118
        func infoRow(_ label: String, _ value: String) {
            let plain = "  \(label.padding(toLength: 12, withPad: " ", startingAt: 0))\(value)"
            print("│\(plain)\(String(repeating: " ", count: max(0, inner - plain.count)))│")
        }
        let df = DateFormatter()
        df.dateStyle = .medium; df.timeStyle = .short

        print("╭" + String(repeating: "─", count: inner) + "╮")
        infoRow("From",    targetMessage.sender)
        infoRow("Subject", targetMessage.subject)
        infoRow("Date",    df.string(from: targetMessage.dateReceived))
        print("├" + String(repeating: "─", count: inner) + "┤")
        for line in targetMessage.body.components(separatedBy: "\n") {
            let content = "  \(line)"
            print("│\(content)\(String(repeating: " ", count: max(0, inner - content.count)))│")
        }
        print("╰" + String(repeating: "─", count: inner) + "╯")
        print("")
        printStandardFooter(keys: "[D] Delete  |  [R] Reply  |  ESC: Back")
        printNavFooter()
        fflush(stdout)

        keyboard.enableRawMode()
        while true {
            switch keyboard.readKey() {
            case .charMenu(let char):
                let lower = char.lowercased()
                if lower == "r" {
                    composePlaintextMail(replyTo: targetMessage.sender, subjectPrefix: "Re: \(targetMessage.subject)")
                    return
                } else if lower == "d" {
                    keyboard.disableRawMode()
                    print("\n Delete this message? (y/n): ", terminator: "")
                    if let confirm = readLine(), confirm.lowercased() == "y" {
                        dataLock.lock()
                        let folderIdx = accounts[activeAccountIndex].activeFolderIndex
                        if index < accounts[activeAccountIndex].folders[folderIdx].messages.count {
                            if let uid = accounts[activeAccountIndex].folders[folderIdx].messages[index].serverUID {
                                accounts[activeAccountIndex].folders[folderIdx].deletedServerUIDs.insert(uid)
                            }
                            accounts[activeAccountIndex].folders[folderIdx].messages.remove(at: index)
                            saveConfiguration()
                        }
                        dataLock.unlock()
                        screenStack.removeLast()
                        return
                    }
                    keyboard.enableRawMode()
                } else {
                    // Nav footer — [C] Calendar is free here (no Compose on reading pane)
                    let navMap: [Character: String] = [
                        "t": "swiftCONTACTS", "c": "swiftCALENDAR",
                        "n": "swiftNOTES",    "s": "swiftSTOCKS",
                        "v": "swiftVAULT"
                    ]
                    if let target = navMap[Character(lower)] {
                        keyboard.disableRawMode()
                        navigateToApp(target, args: [machineName, uptime, cpuUsage, memUsage])
                        running = false; return
                    } else if lower == "l" {
                        keyboard.disableRawMode()
                        returnToLauncher()
                        running = false; return
                    }
                }
            case .escape:
                keyboard.disableRawMode()
                screenStack.removeLast()
                return
            default:
                break
            }
        }
    }
    
    func executeLiveNetworkRefresh() {
        dataLock.lock()
        guard activeAccountIndex < accounts.count else { dataLock.unlock(); return }
        let currentAccount = accounts[activeAccountIndex]
        let currentFolder = currentAccount.folders[currentAccount.activeFolderIndex].serverPath
        let activeAccountIdx = activeAccountIndex
        dataLock.unlock()
        
        guard !currentAccount.tokenKey.isEmpty && !currentAccount.emailAddress.contains("[New") else { return }
        
        dataLock.lock()
        isSyncing = true
        syncProgress = 0.2
        syncMessage = "Connecting..."
        dataLock.unlock()
        
        Thread.detachNewThread { [weak self] in
            guard let self = self else { return }
            self.imapOperationLock.lock()
            defer {
                self.imapOperationLock.unlock()
                self.dataLock.lock()
                self.isSyncing = false
                self.dataLock.unlock()
            }
            
            // Reuses a cached, already-authenticated connection when one is live, instead of
            // paying a fresh TLS handshake + IMAP LOGIN (typically the single biggest chunk of
            // sync latency) on every sync. Only reconnects if there's no live session yet or
            // the cached one turned out to be dead (handled inside selectFolder's retry).
            self.dataLock.lock()
            self.syncProgress = 0.4
            self.syncMessage = "Selecting mailbox..."
            self.dataLock.unlock()
            
            guard let (session, totalMessagesAvailable) = self.selectFolder(currentFolder, account: currentAccount) else {
                self.dataLock.lock()
                self.syncMessage = "Failed to connect / select folder \(currentFolder)."
                self.lastStatusMessage = "Sync failed: could not select \(currentFolder). Check network/app password."
                self.lastStatusWasError = true
                self.dataLock.unlock()
                return
            }
            
            guard totalMessagesAvailable > 0 else {
                self.dataLock.lock()
                if activeAccountIdx < self.accounts.count {
                    self.accounts[activeAccountIdx].folders[self.accounts[activeAccountIdx].activeFolderIndex].messages = []
                    self.saveConfiguration()
                }
                self.lastStatusMessage = "Sync complete — mailbox is empty."
                self.lastStatusWasError = false
                self.dataLock.unlock()
                return
            }
            
            let lowerBound = max(1, totalMessagesAvailable - 24)
            let upperBound = totalMessagesAvailable
            
            self.dataLock.lock()
            self.syncProgress = 0.7
            self.syncMessage = "Fetching messages..."
            self.dataLock.unlock()
            
            let envelopeLines = session.fetchEnvelopes(range: "\(lowerBound):\(upperBound)")
            // Connection is intentionally left open (no logout/close) for reuse by the next
            // sync or by opening a message.
            
            self.dataLock.lock()
            self.syncProgress = 0.9
            self.syncMessage = "Processing..."
            self.dataLock.unlock()
            
            self.parseIncomingIMAPEnvelopes(envelopeLines, lowerBound: lowerBound, forAccountIndex: activeAccountIdx)
            
            self.dataLock.lock()
            self.lastStatusMessage = "Sync complete."
            self.lastStatusWasError = false
            self.dataLock.unlock()
        }
    }
    
    /// IMAP envelope dates are the message's original `Date:` header, formatted RFC 2822-ish —
    /// but servers vary (weekday present or not, numeric vs named timezone, seconds omitted),
    /// so this tries a few common shapes rather than assuming one exact format.
    private func parseIMAPEnvelopeDate(_ raw: String) -> Date? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "NIL" else { return nil }
        
        // Very common in the wild: a redundant human-readable zone name trailing the numeric
        // offset, e.g. "Fri, 11 Jul 2025 14:32:10 -0700 (PDT)". None of the exact-format
        // patterns below account for trailing text, so strip it before matching.
        if let parenRange = trimmed.range(of: " (") {
            trimmed = String(trimmed[..<parenRange.lowerBound])
        }
        
        let candidateFormats = [
            "E, d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "E, d MMM yyyy HH:mm:ss zzz",
            "d MMM yyyy HH:mm:ss zzz",
            "E, d MMM yyyy HH:mm Z",   // some senders omit seconds
            "d MMM yyyy HH:mm Z"
        ]
        
        for format in candidateFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        
        MailDebugLogger.log("Could not parse envelope date: \"\(raw)\"", category: "PARSE-WARN")
        return nil
    }
    
    private func parseIncomingIMAPEnvelopes(_ logs: [String], lowerBound: Int, forAccountIndex accountIdx: Int) {
        var parsedMessages: [EmailMessage] = []
        var dateParseSucceededByUID: [Int: Bool] = [:]
        let fallbackBody = "Press ENTER to download this message's secure content streams from server..."
        
        for line in logs {
            if line.contains("FETCH") && line.contains("ENVELOPE") {
                let rangeTokens = line.components(separatedBy: " ")
                guard rangeTokens.count > 1, let seqNum = Int(rangeTokens[1]) else { continue }
                
                // Pull the real IMAP UID out of "... FETCH (UID 1023 ENVELOPE (...". Falls back
                // to the sequence number only if a server unexpectedly omits UID, so a message
                // is never simply dropped for lacking one.
                var extractedUID = seqNum
                if let uidRange = line.range(of: "UID ") {
                    let digits = line[uidRange.upperBound...].prefix(while: { $0.isNumber })
                    if let parsedUID = Int(digits) {
                        extractedUID = parsedUID
                    }
                }
                
                var extractedSubject = "(No Subject)"
                var extractedSender = "Unknown Sender"
                var parsedDateField: Date? = nil // nil = couldn't parse; caller decides the fallback
                
                if let envRange = line.range(of: "ENVELOPE (") {
                    let subSlice = line[envRange.upperBound...]
                    
                    // The envelope's first field is always the message's actual Date: header,
                    // as a quoted RFC 2822-ish string, e.g. "Fri, 11 Jul 2025 14:32:10 -0700".
                    // This was previously being discarded entirely, which is why every synced
                    // message showed the moment it was *downloaded* rather than when it was
                    // actually sent.
                    if subSlice.hasPrefix("\"") {
                        let afterOpenQuote = subSlice.dropFirst()
                        if let closingQuoteIdx = afterOpenQuote.firstIndex(of: "\"") {
                            let rawDateField = String(afterOpenQuote[..<closingQuoteIdx])
                            parsedDateField = parseIMAPEnvelopeDate(rawDateField)
                        }
                    }
                    
                    let envelopeParts = subSlice.components(separatedBy: " \"")
                    if envelopeParts.count > 1 {
                        var potentialSubject = envelopeParts[1]
                        if let firstQuote = potentialSubject.firstIndex(of: "\"") {
                            potentialSubject = String(potentialSubject[..<firstQuote])
                        }
                        
                        if potentialSubject.contains("=?") {
                            if let regex = try? NSRegularExpression(pattern: "=\\?[^?]+\\?[QB]\\?([^?]+)\\?=", options: .caseInsensitive) {
                                let nsString = potentialSubject as NSString
                                let matches = regex.matches(in: potentialSubject, options: [], range: NSRange(location: 0, length: nsString.length))
                                
                                if let firstMatch = matches.first, firstMatch.numberOfRanges > 1 {
                                    let rawPayload = nsString.substring(with: firstMatch.range(at: 1))
                                    potentialSubject = rawPayload.replacingOccurrences(of: "_", with: " ")
                                }
                            }
                        }
                        
                        if !potentialSubject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !potentialSubject.contains("NIL") {
                            extractedSubject = potentialSubject
                        }
                    }
                }
                
                if let senderBlockStart = line.range(of: "((") {
                    let trackingSlice = line[senderBlockStart.upperBound...]
                    if let endBlock = trackingSlice.range(of: "))") {
                        let innerSender = trackingSlice[..<endBlock.lowerBound]
                        let tokens = innerSender.components(separatedBy: " ").map { $0.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "NIL", with: "") }
                        let cleanTokens = tokens.filter { !$0.isEmpty }
                        
                        if cleanTokens.count >= 2 {
                            let mailbox = cleanTokens[cleanTokens.count - 2]
                            let domain = cleanTokens[cleanTokens.count - 1]
                            extractedSender = "\(mailbox)@\(domain)"
                        } else if let fallbackEmail = cleanTokens.first, fallbackEmail.contains("@") {
                            extractedSender = fallbackEmail
                        }
                    }
                }
                
                let newMessage = EmailMessage(
                    id: Int.random(in: 1000...9999),
                    serverUID: extractedUID,
                    sender: extractedSender,
                    subject: extractedSubject,
                    body: fallbackBody,
                    isUnread: true,
                    hasGraphics: false,
                    dateReceived: parsedDateField ?? Date()
                )
                dateParseSucceededByUID[extractedUID] = (parsedDateField != nil)
                parsedMessages.append(newMessage)
            }
        }
        
        if !parsedMessages.isEmpty {
            dataLock.lock()
            guard accountIdx < self.accounts.count else { dataLock.unlock(); return }
            let activeFolderIdx = self.accounts[accountIdx].activeFolderIndex
            let deletedUIDs = self.accounts[accountIdx].folders[activeFolderIdx].deletedServerUIDs
            // Snapshot of what's already known locally, keyed by UID, so a re-sync can recognize
            // "I've already seen this one" and keep its read state / cached body instead of
            // stomping them back to "unread" + placeholder every single time.
            let existingByUID: [Int: EmailMessage] = Dictionary(
                uniqueKeysWithValues: self.accounts[accountIdx].folders[activeFolderIdx].messages.compactMap { msg in
                    guard let uid = msg.serverUID else { return nil }
                    return (uid, msg)
                }
            )
            dataLock.unlock()
            
            // Drop anything the user already deleted locally from this folder — otherwise a
            // plain re-sync would just fetch it again and silently bring it back, since deleting
            // locally never told the server to remove it. For UIDs already known locally, keep
            // the local-only state (read status, any already-downloaded body) but still refresh
            // envelope metadata (sender/subject) from the server — that's authoritative and never
            // changes for a given UID, so there's no reason to keep a stale cached copy of it.
            // The date only gets refreshed when this sync's parse actually succeeded (self-heals
            // messages synced before the date-parsing fix, without a rare future parse miss
            // stomping an already-correct date back to "now").
            let filteredMessages: [EmailMessage] = parsedMessages.compactMap { parsed in
                guard let uid = parsed.serverUID else { return parsed }
                if deletedUIDs.contains(uid) { return nil }
                
                guard var merged = existingByUID[uid] else { return parsed }
                merged.sender = parsed.sender
                merged.subject = parsed.subject
                if dateParseSucceededByUID[uid] == true {
                    merged.dateReceived = parsed.dateReceived
                }
                return merged
            }
            let chronologicallyOrdered = filteredMessages.reversed()
            
            dataLock.lock()
            if accountIdx < self.accounts.count {
                let activeFolderIdx = self.accounts[accountIdx].activeFolderIndex
                self.accounts[accountIdx].folders[activeFolderIdx].messages = Array(chronologicallyOrdered)
                
                // A tombstoned UID older than anything in the current sync window can never be
                // fetched again, so it's safe to forget — otherwise this set would just grow
                // forever as more mail gets deleted over time.
                if let minFetchedUID = parsedMessages.compactMap({ $0.serverUID }).min() {
                    self.accounts[accountIdx].folders[activeFolderIdx].deletedServerUIDs = deletedUIDs.filter { $0 >= minFetchedUID }
                }
                
                self.saveConfiguration()
            }
            dataLock.unlock()
        }
    }
    
    /// Prompts for a recipient. If what's typed contains "@", it's used directly as a literal
    /// email address — identical to the previous behavior, no change at all for anyone who
    /// already knows the address. If not, it's treated as a name to search swiftCONTACTS for
    /// instead, entirely inline (no new screens) — one match auto-fills, multiple matches show
    /// a short numbered pick list using the same prompt style as the rest of this screen.
    private func promptForRecipient() -> String? {
        let contactMatches = loadContactAutocompleteEntries()
        
        while true {
            print(" To (email, or a contact's name): ", terminator: "")
            fflush(stdout)
            let input = keyboard.readCanonicalLine().trimmingCharacters(in: .whitespacesAndNewlines)
            if input.isEmpty { return nil }
            if input.contains("@") { return input }
            
            let matches = contactMatches.filter { $0.name.lowercased().contains(input.lowercased()) }
            
            if matches.isEmpty {
                print(" No contact matched '\(input)'. Type a full email address, or try another name.\n")
                continue
            }
            if matches.count == 1 {
                print(" -> \(matches[0].name) <\(matches[0].email)>")
                return matches[0].email
            }
            
            let capped = Array(matches.prefix(9))
            print(" Multiple contacts matched '\(input)':")
            for (i, m) in capped.enumerated() {
                print("   [\(i + 1)] \(m.name) <\(m.email)>")
            }
            if matches.count > capped.count {
                print("   (+\(matches.count - capped.count) more — type more of the name to narrow it down)")
            }
            print(" Enter a number to pick one, or press Enter to try again: ", terminator: "")
            fflush(stdout)
            let pick = keyboard.readCanonicalLine().trimmingCharacters(in: .whitespacesAndNewlines)
            if let num = Int(pick), num >= 1 && num <= capped.count {
                return capped[num - 1].email
            }
            print("")
        }
    }
    
    func composePlaintextMail(replyTo: String? = nil, subjectPrefix: String? = nil) {
        keyboard.enableRawMode()
        
        print("\u{001B}[2J\u{001B}[1;1H", terminator: "") 
        printStandardHeader()
        if replyTo != nil {
            print("                      >>> COMPOSE OUTBOUND REPLY TRANSMISSION <<<                 ")
        } else {
            print("                      >>> COMPOSE NEW OUTBOUND MAIL TRANSMISSION <<<              ")
        }
        print(String(repeating: "─", count: 120))
        
        dataLock.lock()
        guard activeAccountIndex < accounts.count else { dataLock.unlock(); return }
        let currentAccount = accounts[activeAccountIndex]
        dataLock.unlock()
        
        guard !currentAccount.tokenKey.isEmpty else {
            print("\n \u{001B}[1;31m[!] Error: No App Password/Token found for this account.\u{001B}[0m")
            print("Press any key to drop back...")
            let _ = fflush(stdout)
            _ = keyboard.readCanonicalLine()
            return
        }
        
        let targetRecipient: String
        if let replyTarget = replyTo {
            targetRecipient = replyTarget
            print(" To: \(targetRecipient)")
        } else {
            guard let resolved = promptForRecipient() else { return }
            targetRecipient = resolved
        }
        
        let targetSubject: String
        if let subPrefix = subjectPrefix {
            targetSubject = subPrefix
            print(" Subject: \(targetSubject)")
        } else {
            print(" Subject: ", terminator: "")
            fflush(stdout) 
            targetSubject = keyboard.readCanonicalLine()
        }
        
        print("\n Message body (type DONE on its own line when finished):")
        fflush(stdout)
        
        var bufferContentLines: [String] = []
        while true {
            let singleLine = keyboard.readCanonicalLine()
            if singleLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "done" { break }
            bufferContentLines.append(singleLine)
        }
        let fullBodyText = bufferContentLines.joined(separator: "\r\n")
        
        let smtpHost = currentAccount.smtpHost
        let smtpPort = UInt16(clamping: currentAccount.smtpPort)
        let decryptedToken = LocalCryptoEngine.decrypt(currentAccount.tokenKey)
        let base64Auth = Data("\0\(currentAccount.emailAddress)\0\(decryptedToken)".utf8).base64EncodedString()
        
        let rfcDateFormatter = DateFormatter()
        rfcDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        rfcDateFormatter.dateFormat = "E, d MMM yyyy HH:mm:ss Z"
        let timestamp = rfcDateFormatter.string(from: Date())
        
        let randomToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
        let domainSlice = currentAccount.emailAddress.components(separatedBy: "@").last ?? currentAccount.smtpHost
        let messageID = "<\(randomToken)@\(domainSlice)>"
        
        var headerBlock = ""
        headerBlock += "From: \(currentAccount.emailAddress)\r\n"
        headerBlock += "To: \(targetRecipient)\r\n"
        headerBlock += "Subject: \(targetSubject)\r\n"
        headerBlock += "Date: \(timestamp)\r\n"
        headerBlock += "Message-ID: \(messageID)\r\n"
        headerBlock += "MIME-Version: 1.0\r\n"
        headerBlock += "Content-Type: text/plain; charset=UTF-8\r\n"
        headerBlock += "\r\n"
        headerBlock += fullBodyText
        
        // NOTE on the previous implementation: it queued "DATA" and the message body as two
        // separate items in a single command array and just fired them at the server back to
        // back, hoping a generic " OK "/" 250 " substring match somewhere in the stream would
        // eventually flip a success flag. In practice, the server's real response to "DATA" is
        // "354 Start mail input" — which doesn't contain " OK " — so the old code's
        // "is this command done" check never fired, the queued body was never actually sent,
        // and the whole exchange just sat there until the 15s timeout expired. It then reported
        // "success" anyway because EHLO/MAIL/RCPT's *earlier* replies had already contained
        // "250 ". That's the core reason send wasn't reliably working.
        //
        // Below, each step is driven explicitly by its real SMTP reply code.
        var sendSucceeded = false
        var failureDetail = ""
        
        runWithSpinner(message: "Sending via SMTP...") {
            if let smtp = SMTPSession(host: smtpHost, port: smtpPort) {
                let ehlo = smtp.send("EHLO \(domainSlice)")
                let auth = smtp.send("AUTH PLAIN \(base64Auth)")
                let mailFrom = smtp.send("MAIL FROM:<\(currentAccount.emailAddress)>")
                let rcptTo = smtp.send("RCPT TO:<\(targetRecipient)>")
                let dataStart = smtp.send("DATA")
                
                if ehlo.ok && auth.ok && mailFrom.ok && rcptTo.ok && dataStart.code == 354 {
                    let dataResult = smtp.sendData(headerBlock)
                    sendSucceeded = dataResult.ok
                    failureDetail = dataResult.lines.joined(separator: " | ")
                } else {
                    failureDetail = "EHLO=\(ehlo.code) AUTH=\(auth.code) MAIL=\(mailFrom.code) RCPT=\(rcptTo.code) DATA=\(dataStart.code)"
                }
                
                smtp.send("QUIT")
                smtp.close()
            } else {
                failureDetail = "Could not establish TLS connection to \(smtpHost)"
            }
        }
        
        if sendSucceeded {
            print("\n \u{001B}[1;32m[+] Message transmitted successfully via SMTP.\u{001B}[0m")
            dataLock.lock()
            lastStatusMessage = "Sent to \(targetRecipient)."
            lastStatusWasError = false
            dataLock.unlock()
            
            runWithSpinner(message: "Archiving copy to Sent folder...") { [weak self] in
                self?.appendMessageToSentFolder(to: targetRecipient, subject: targetSubject, body: fullBodyText, account: currentAccount)
            }
        } else {
            print("\n \u{001B}[1;31m[─] SMTP Operational Delivery Handshake Failed.\u{001B}[0m")
            print(" \u{001B}[1;31mReason: \(failureDetail)\u{001B}[0m")
            MailDebugLogger.log("SMTP send failed: \(failureDetail)", category: "SMTP-ERR")
            dataLock.lock()
            lastStatusMessage = "Send failed: \(failureDetail)"
            lastStatusWasError = true
            dataLock.unlock()
        }
        
        print("\n Press any key to continue.")
        fflush(stdout)
        _ = keyboard.readCanonicalLine()
        
        if replyTo != nil {
            screenStack.removeLast() 
        }
    }
    
    private func appendMessageToSentFolder(to recipient: String, subject: String, body: String, account: EmailAccount) {
        let sentTargetFolder = account.folders.first(where: { $0.name.uppercased() == "SENT" })?.serverPath
            ?? EmailFolder.defaultGmailServerPath(forDisplayName: "SENT")
        let rawMessageContent = "From: \(account.emailAddress)\r\nTo: \(recipient)\r\nSubject: \(subject)\r\n\r\n\(body)\r\n"
        
        var appended = false
        imapOperationLock.lock()
        if let session = imapSession(for: account) {
            appended = session.append(folder: sentTargetFolder, message: rawMessageContent)
            if !appended {
                invalidateIMAPSession(for: account)
                if let retrySession = imapSession(for: account, forceNew: true) {
                    appended = retrySession.append(folder: sentTargetFolder, message: rawMessageContent)
                }
            }
        }
        imapOperationLock.unlock()
        
        if !appended {
            MailDebugLogger.log("IMAP APPEND to Sent Mail failed", category: "IMAP-ERR")
            dataLock.lock()
            lastStatusMessage = "Message sent, but couldn't archive a copy to \(sentTargetFolder) on the server."
            lastStatusWasError = true
            dataLock.unlock()
        }
        
        dataLock.lock()
        if activeAccountIndex < accounts.count {
            if let sentFolderIdx = accounts[activeAccountIndex].folders.firstIndex(where: { $0.name.uppercased() == "SENT" }) {
                let historicalMessage = EmailMessage(
                    id: Int.random(in: 1000...9999),
                    serverUID: nil,
                    sender: "To: \(recipient)",
                    subject: subject,
                    body: body,
                    isUnread: false,
                    hasGraphics: false,
                    dateReceived: Date()
                )
                accounts[activeAccountIndex].folders[sentFolderIdx].messages.insert(historicalMessage, at: 0)
                saveConfiguration()
            }
        }
        dataLock.unlock()
    }
    
    // MARK: - Provisioning Handlers
    
    func showAccountMatrix() {
        var localSelectionIndex = 0
        keyboard.enableRawMode()
        
        while true {
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()
            print("                       >>> ACCOUNT SETUP <<<                        ")
            print(String(repeating: "─", count: 120))
            print("")
            
            dataLock.lock()
            let currentAccounts = accounts
            dataLock.unlock()
            
            if currentAccounts.isEmpty {
                print("               [ No active mail accounts. Press 'N' to add a new account. ]")
                for _ in 0..<10 { print("") }
            } else {
                for (idx, account) in currentAccounts.enumerated() {
                    let pointer = (idx == localSelectionIndex) ? " -> " : "    "
                    let serviceLabel = "[Google]"
                    if idx == localSelectionIndex {
                        print("\(pointer)[\(idx + 1)]. \(serviceLabel) Config: \u{001B}[7m\(account.emailAddress)\u{001B}[0m")
                    } else {
                        print("\(pointer)[\(idx + 1)]. \(serviceLabel) Config: \(account.emailAddress)")
                    }
                }
                for _ in 0..<max(1, 10 - currentAccounts.count) { print("") }
            }
            
            print("\n")
            printStandardFooter(keys: "↑/↓: Highlight | ENTER: Edit | A: Add Account | D: Delete | ESC: Back")
            fflush(stdout)
            
            switch keyboard.readKey() {
            case .up:
                if !accounts.isEmpty {
                    localSelectionIndex = (localSelectionIndex == 0) ? accounts.count - 1 : localSelectionIndex - 1
                }
            case .down:
                if !accounts.isEmpty {
                    localSelectionIndex = (localSelectionIndex == accounts.count - 1) ? 0 : localSelectionIndex + 1
                }
            case .enter:
                if !accounts.isEmpty {
                    showEditSlotScreen(accountIndex: localSelectionIndex)
                }
            case .charMenu(let char):
                let lowerChar = char.lowercased()
                if lowerChar == "n" {
                    let blankAccount = EmailAccount(emailAddress: "[New Unconfigured Account]", type: .google)
                    dataLock.lock()
                    accounts.append(blankAccount)
                    localSelectionIndex = accounts.count - 1
                    saveConfiguration()
                    dataLock.unlock()
                    showEditSlotScreen(accountIndex: localSelectionIndex)
                } else if lowerChar == "d" {
                    if !accounts.isEmpty {
                        dataLock.lock()
                        let removedAccount = accounts[localSelectionIndex]
                        accounts.remove(at: localSelectionIndex)
                        localSelectionIndex = max(0, localSelectionIndex - 1)
                        saveConfiguration()
                        dataLock.unlock()
                        invalidateIMAPSession(for: removedAccount)
                    }
                }
            case .escape:
                keyboard.disableRawMode()
                screenStack.removeLast()
                return
            case .tab:
                break
            }
        }
    }
    
    func showEditSlotScreen(accountIndex: Int) {
        print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
        printStandardHeader()
        dataLock.lock()
        guard accountIndex < accounts.count else { dataLock.unlock(); return }
        var targetAccount = accounts[accountIndex]
        dataLock.unlock()
        
        print("                  >>> EDIT ACCOUNT [\(accountIndex + 1)] <<<")
        print(String(repeating: "─", count: 120))
        print("")
        
        print(" Mail Provider (currently: \(targetAccount.type.displayName)):")
        for (i, providerType) in AccountType.allCases.enumerated() {
            print("   [\(i + 1)] \(providerType.displayName)")
        }
        print(" Pick a number, or press Enter to keep the current provider: ", terminator: "")
        fflush(stdout)
        let providerInput = keyboard.readCanonicalLine().trimmingCharacters(in: .whitespacesAndNewlines)
        if let num = Int(providerInput), num >= 1 && num <= AccountType.allCases.count {
            let newType = AccountType.allCases[num - 1]
            if newType != targetAccount.type {
                targetAccount.type = newType
                // Known providers get their real host/port automatically — .custom is the only
                // case that needs asking, since there's nothing to sensibly guess.
                if newType != .custom {
                    targetAccount.imapHost = newType.defaultIMAPHost ?? ""
                    targetAccount.smtpHost = newType.defaultSMTPHost ?? ""
                    targetAccount.imapPort = 993
                    targetAccount.smtpPort = 465
                }
            }
        }
        
        if targetAccount.type == .custom {
            print("\n Custom provider — enter your mail server details:")
            print(" IMAP Host [\(targetAccount.imapHost)]: ", terminator: "")
            fflush(stdout)
            let imapHostInput = keyboard.readCanonicalLine().trimmingCharacters(in: .whitespacesAndNewlines)
            if !imapHostInput.isEmpty { targetAccount.imapHost = imapHostInput }
            
            print(" IMAP Port [\(targetAccount.imapPort)] (993 is standard for implicit TLS): ", terminator: "")
            fflush(stdout)
            let imapPortInput = keyboard.readCanonicalLine().trimmingCharacters(in: .whitespacesAndNewlines)
            if let port = Int(imapPortInput) { targetAccount.imapPort = port }
            
            print(" SMTP Host [\(targetAccount.smtpHost)]: ", terminator: "")
            fflush(stdout)
            let smtpHostInput = keyboard.readCanonicalLine().trimmingCharacters(in: .whitespacesAndNewlines)
            if !smtpHostInput.isEmpty { targetAccount.smtpHost = smtpHostInput }
            
            print(" SMTP Port [\(targetAccount.smtpPort)] (465 is standard for implicit TLS): ", terminator: "")
            fflush(stdout)
            let smtpPortInput = keyboard.readCanonicalLine().trimmingCharacters(in: .whitespacesAndNewlines)
            if let port = Int(smtpPortInput) { targetAccount.smtpPort = port }
            
            print("\n Folder paths (leave blank to keep the current value — adjust these if")
            print(" your server uses different names than the plain defaults):")
            if let idx = targetAccount.folders.firstIndex(where: { $0.name == "SENT" }) {
                print(" Sent folder path [\(targetAccount.folders[idx].serverPath)]: ", terminator: "")
                fflush(stdout)
                let v = keyboard.readCanonicalLine().trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty { targetAccount.folders[idx].serverPath = v }
            }
            if let idx = targetAccount.folders.firstIndex(where: { $0.name == "JUNK" }) {
                print(" Junk folder path [\(targetAccount.folders[idx].serverPath)]: ", terminator: "")
                fflush(stdout)
                let v = keyboard.readCanonicalLine().trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty { targetAccount.folders[idx].serverPath = v }
            }
            if let idx = targetAccount.folders.firstIndex(where: { $0.name == "TRASH" }) {
                print(" Trash folder path [\(targetAccount.folders[idx].serverPath)]: ", terminator: "")
                fflush(stdout)
                let v = keyboard.readCanonicalLine().trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty { targetAccount.folders[idx].serverPath = v }
            }
        }
        
        print("\n Operational Email Address [\(targetAccount.emailAddress)]: ", terminator: "")
        fflush(stdout) 
        let emailInput = keyboard.readCanonicalLine().trimmingCharacters(in: .whitespacesAndNewlines)
        if !emailInput.isEmpty {
            targetAccount.emailAddress = emailInput
        }
        
        // Outlook.com/Hotmail/Live killed basic-auth password login in Sept 2024 — this app
        // authenticates with a password (app password / token), which simply cannot work there
        // regardless of what host is configured. Worth telling someone this up front rather than
        // letting them find out after a confusing connection failure.
        let lowerEmail = targetAccount.emailAddress.lowercased()
        let microsoftConsumerDomains = ["outlook.com", "hotmail.com", "live.com", "msn.com"]
        if microsoftConsumerDomains.contains(where: { lowerEmail.hasSuffix("@\($0)") }) {
            print("\n \u{001B}[1;33m[!] Heads up: Outlook/Hotmail/Live accounts require OAuth2 —\u{001B}[0m")
            print(" \u{001B}[1;33mMicrosoft disabled password-based login for these in Sept 2024.\u{001B}[0m")
            print(" \u{001B}[1;33mThis app doesn't implement OAuth yet, so this account won't connect.\u{001B}[0m")
        }
        
        print(" App Secret Key / Token Value: ", terminator: "")
        fflush(stdout) 
        let tokenInput = keyboard.readMaskedLine().trimmingCharacters(in: .whitespacesAndNewlines)
        if !tokenInput.isEmpty {
            targetAccount.tokenKey = LocalCryptoEngine.encrypt(tokenInput)
        }
        
        dataLock.lock()
        if accountIndex < accounts.count {
            accounts[accountIndex] = targetAccount
            saveConfiguration()
        }
        dataLock.unlock()
        
        // Credentials or address may have just changed — don't reuse a session authenticated
        // under the old ones.
        invalidateIMAPSession(for: targetAccount)
        executeLiveNetworkRefresh()
        
        print("\n Account saved. Press any key to continue.")
        fflush(stdout)
        _ = keyboard.readCanonicalLine()
    }
    
    func injectMockDataIfEmpty() {
        guard accounts.isEmpty else { return }
        let primaryMock = EmailAccount(emailAddress: "account.name@email.com", type: .google)
        accounts = [primaryMock]
        
        accounts[0].folders[0].messages = [
            EmailMessage(id: 101, serverUID: nil, sender: "office@server.com", subject: "Welcome to swiftGMAIL Engine", body: "Hit 'A' to bring up your accounts configuration dashboard.", isUnread: true, hasGraphics: false, dateReceived: Date())
        ]
        saveConfiguration()
    }
    
    func saveConfiguration() {
        do {
            let encoder = JSONEncoder()
            let encodedPayload = try encoder.encode(accounts)
            try encodedPayload.write(to: fileURL, options: .atomic)
            // Atomic writes go through a temp file + rename, which can pick up default (often
            // group/world-readable) permissions — this file holds an encrypted app password and
            // account addresses, so lock it to the owner only.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            MailDebugLogger.log("Config saved atomically.", category: "STORAGE")
        } catch {
            MailDebugLogger.log("Save fail: \(error.localizedDescription)", category: "STORAGE-ERR")
        }
    }
    
    func loadConfiguration() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let processedData = try Data(contentsOf: fileURL)
            accounts = try JSONDecoder().decode([EmailAccount].self, from: processedData)
            MailDebugLogger.log("Config loaded safely.", category: "STORAGE")
        } catch {
            MailDebugLogger.log("Load fail: \(error.localizedDescription)", category: "STORAGE-ERR")
        }
    }
    
    deinit {
        networkMonitor.cancel()
        networkLock.lock()
        for (_, session) in imapSessionCache { session.close() }
        imapSessionCache.removeAll()
        networkLock.unlock()
    }
}

// MARK: - App Navigation

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

func printNavFooter(currentApp: String = "swiftMAIL") {
    let inner = 118
    // [W] = Compose, [C] = Calendar — no conflicts in mail workspace or reading pane
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

let coreMailService = MailManager()
coreMailService.run()