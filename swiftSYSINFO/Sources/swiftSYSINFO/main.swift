// ═══════════════════════════════════════════════════════════════
// APP: swiftSYSINFO
// BGInfo-style system telemetry companion app
// File: Sources/swiftSYSINFO/main.swift
// ═══════════════════════════════════════════════════════════════

import Cocoa
import IOKit.ps
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// ─────────────────────────────────────────────────────────────
// COLORS
// Reusing the exact same values used across swiftCT and its icon, so
// this feels like part of the same family rather than a separate design.
// ─────────────────────────────────────────────────────────────

let letterColor_s = NSColor(calibratedRed: 0.91, green: 0.65, blue: 0.24, alpha: 1.0)   // gold
let letterColor_i = NSColor(calibratedRed: 0.61, green: 0.49, blue: 0.85, alpha: 1.0)   // purple
let letterColor_f = NSColor(calibratedRed: 0.32, green: 0.85, blue: 0.77, alpha: 1.0)   // teal
let magentaColor = NSColor(calibratedRed: 0.93, green: 0.25, blue: 0.60, alpha: 1.0)    // network shares

// Dark mode matches swiftCT's exact "Clear Dark" theme; light mode is a
// simple plain counterpart — same pattern already used in swiftEYES/swiftCLOCK.
let darkBackground = NSColor(calibratedRed: 0.098039, green: 0.113725, blue: 0.152941, alpha: 1.0)
let darkForeground = NSColor.white
let lightBackground = NSColor.white
let lightForeground = NSColor(calibratedRed: 89.0/255, green: 89.0/255, blue: 89.0/255, alpha: 1.0)

// ─────────────────────────────────────────────────────────────
// REUSABLE VIEWS — PercentBar, SparklineView, NetworkBarView
// Same implementations already proven out in swiftCT.
// ─────────────────────────────────────────────────────────────

class PercentBar: NSView {
    private let track = NSView()
    private let fill = NSView()
    var barColor: NSColor = .systemBlue {
        didSet { fill.layer?.backgroundColor = barColor.cgColor }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        track.layer?.cornerRadius = frame.height / 2
        track.frame = bounds
        track.autoresizingMask = [.width, .height]
        addSubview(track)
        fill.wantsLayer = true
        fill.layer?.backgroundColor = barColor.cgColor
        fill.layer?.cornerRadius = frame.height / 2
        fill.frame = NSRect(x: 0, y: 0, width: 0, height: frame.height)
        addSubview(fill)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func setPercent(_ percent: Double) {
        let clamped = max(0, min(100, percent))
        let width = bounds.width * CGFloat(clamped / 100)
        fill.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
    }
}

class NetworkBarView: NSView {
    private let track = NSView()
    private let downFill = NSView()
    private let upFill = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        track.layer?.cornerRadius = frame.height / 2
        track.frame = bounds
        track.autoresizingMask = [.width, .height]
        addSubview(track)
        downFill.wantsLayer = true
        downFill.layer?.backgroundColor = NSColor.systemRed.cgColor
        addSubview(downFill)
        upFill.wantsLayer = true
        upFill.layer?.backgroundColor = NSColor.systemBlue.cgColor
        addSubview(upFill)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func setRates(downBytesPerSecond: Double, upBytesPerSecond: Double, maxBytesPerSecond: Double = 1_250_000) {
        let half = bounds.width / 2
        let floorBytesPerSecond: Double = 500
        func scaledWidth(_ bytesPerSecond: Double) -> CGFloat {
            guard bytesPerSecond > floorBytesPerSecond else {
                return bytesPerSecond > 0 ? half * 0.04 : 0
            }
            let logValue = log10(bytesPerSecond)
            let logMin = log10(floorBytesPerSecond)
            let logMax = log10(maxBytesPerSecond)
            let fraction = (logValue - logMin) / (logMax - logMin)
            return half * CGFloat(max(0, min(1, fraction)))
        }
        let downWidth = scaledWidth(downBytesPerSecond)
        let upWidth = scaledWidth(upBytesPerSecond)
        downFill.frame = NSRect(x: half - downWidth, y: 0, width: downWidth, height: bounds.height)
        upFill.frame = NSRect(x: half, y: 0, width: upWidth, height: bounds.height)
    }
}

// Three-state status indicator — green/yellow/red, matching the icon's
// dot styling. Battery gets full 3-state support immediately (we already
// have the exact percentage). Tailscale and Syncthing currently only
// resolve to green/red with what we can detect today; yellow ("syncing"/
// "establishing") is wired up but only becomes reachable once richer
// detection is available (Tailscale binary path, Syncthing folder ID).
enum StoplightState {
    case green, yellow, red

    var color: NSColor {
        switch self {
        case .green: return .systemGreen
        case .yellow: return .systemYellow
        case .red: return .systemRed
        }
    }
}

func batteryStoplight(percent: Int) -> StoplightState {
    if percent < 30 { return .red }
    if percent < 70 { return .yellow }
    return .green
}

// Builds the "Battery (72% - Charging)" label with "Charging" colored
// distinctly, matching the same "Title (Status)" pattern already used
// for Tailscale/Syncthing rather than introducing a separate icon-based
// treatment just for this one row. Reads the font directly off whatever
// was already applied to the label at construction time (respects
// whatever scale factor was active then), rather than needing scale
// factor access here.
func batteryAttributedString(percent: Int, isCharging: Bool, font: NSFont, foreground: NSColor) -> NSAttributedString {
    let result = NSMutableAttributedString(string: "Battery (\(percent)%", attributes: [.font: font, .foregroundColor: foreground])
    if isCharging {
        result.append(NSAttributedString(string: " - ", attributes: [.font: font, .foregroundColor: foreground]))
        result.append(NSAttributedString(string: "Charging", attributes: [.font: font, .foregroundColor: NSColor.systemGreen]))
    }
    result.append(NSAttributedString(string: ")", attributes: [.font: font, .foregroundColor: foreground]))
    return result
}

enum RowVisual: Equatable {
    case none
    case percentBar
    case networkBar
}

struct NetworkSample {
    let bytesIn: UInt64
    let bytesOut: UInt64
    let timestamp: Date
}

// ─────────────────────────────────────────────────────────────
// STAT FETCHERS — same as swiftCT's, plus new additions:
// Local IP, Tailscale, Battery, Syncthing.
// ─────────────────────────────────────────────────────────────

let networkInterfaceName = "en0"
let syncthingAPIKeyDefaultsKey = "swiftSYSINFO.syncthingAPIKey"

// ─────────────────────────────────────────────────────────────
// PATH DISCOVERY — same pattern as swiftCT: walk upward from wherever
// this binary is until a sibling swiftCORE folder is found, so the
// whole swiftSUITE folder can move or get renamed without breaking.
// ─────────────────────────────────────────────────────────────

func locateSwiftSuiteRoot() -> URL? {
    var dir = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()

    for _ in 0..<6 {
        let candidate = dir.appendingPathComponent("swiftCORE/swiftCORE")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return dir
        }
        let parent = dir.deletingLastPathComponent()
        if parent == dir { break }
        dir = parent
    }
    return nil
}

// ─────────────────────────────────────────────────────────────
// SHARED CONFIG — a plain JSON file inside swiftSUITE itself, letting
// swiftCT's Settings configure things (Syncthing API key/folder ID,
// Tailscale binary path) that swiftSYSINFO actually uses. Deliberately
// NOT UserDefaults: each compiled app has its own separate UserDefaults
// domain (different bundle IDs), so swiftCT writing to its own
// UserDefaults would be completely invisible to swiftSYSINFO. A shared
// file sidesteps that with zero extra entitlements needed, since neither
// app is sandboxed.
//
// NOTE: this file sits inside swiftSUITE and syncs via Syncthing along
// with everything else, by deliberate choice. It should be added to
// .gitignore in any sterile/public copy of the repo, since it can hold
// a real Syncthing API key.
// ─────────────────────────────────────────────────────────────

let sharedConfigFilename = "swiftsuite-config.json"

struct SharedConfig: Codable {
    var syncthingAPIKey: String?
    var syncthingFolderIDs: String?   // comma-separated — status reflects the least-caught-up folder
    var tailscaleBinaryPath: String?
    var showTailscale: Bool?          // nil defaults to true (shown) — an existing config file without this key shouldn'''t suddenly hide a row nobody asked to hide
    var showSyncthing: Bool?          // same default-to-true behavior
    var showVPN: Bool?                // same default-to-true behavior
}

func sharedConfigURL() -> URL? {
    guard let root = locateSwiftSuiteRoot() else { return nil }
    return root.appendingPathComponent("swiftCT").appendingPathComponent(sharedConfigFilename)
}

func loadSharedConfig() -> SharedConfig {
    guard let url = sharedConfigURL(), let data = try? Data(contentsOf: url) else {
        return SharedConfig()
    }
    return (try? JSONDecoder().decode(SharedConfig.self, from: data)) ?? SharedConfig()
}

func formattedUptime() -> String {
    let seconds = Int(ProcessInfo.processInfo.systemUptime)
    let days = seconds / 86400
    let hours = (seconds % 86400) / 3600
    let minutes = (seconds % 3600) / 60
    if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
}

func diskSpaceInfo() -> (text: String, usedPercent: Double?) {
    let url = URL(fileURLWithPath: NSHomeDirectory())
    do {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        let availableBytes = values.volumeAvailableCapacityForImportantUsage ?? 0
        let totalBytes = Int64(values.volumeTotalCapacity ?? 0)
        let availableGB = Double(availableBytes) / 1_000_000_000
        let totalGB = Double(totalBytes) / 1_000_000_000
        let usedGB = totalGB - availableGB
        let text = String(format: "%.0f / %.0f GB used", usedGB, totalGB)
        var usedPercent: Double? = nil
        if totalGB > 0 { usedPercent = (usedGB / totalGB) * 100 }
        return (text, usedPercent)
    } catch {
        return ("Unavailable", nil)
    }
}

func fetchMemoryInfo() -> (percent: Double?, text: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/vm_stat")
    let outPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = Pipe()

    func extractNumber(from line: Substring) -> Double {
        guard let colonIndex = line.firstIndex(of: ":") else { return 0 }
        let after = line[line.index(after: colonIndex)...]
        let trimmed = after.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return Double(trimmed) ?? 0
    }

    do {
        try process.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return (nil, "Unavailable") }

        var pageSize: Double = 16384
        var pagesActive: Double = 0
        var pagesWired: Double = 0
        var pagesCompressed: Double = 0

        for line in output.split(separator: "\n") {
            if line.contains("page size of"), let range = line.range(of: "page size of "), let endRange = line.range(of: " bytes") {
                pageSize = Double(line[range.upperBound..<endRange.lowerBound]) ?? pageSize
            } else if line.hasPrefix("Pages active:") {
                pagesActive = extractNumber(from: line)
            } else if line.hasPrefix("Pages wired down:") {
                pagesWired = extractNumber(from: line)
            } else if line.hasPrefix("Pages occupied by compressor:") {
                pagesCompressed = extractNumber(from: line)
            }
        }

        let usedBytes = (pagesActive + pagesWired + pagesCompressed) * pageSize
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        guard totalBytes > 0 else { return (nil, "Unavailable") }
        // Same binary-GiB divisor as hardwareInfo()'s total memory figure
        // — the percentage itself was always correct (same wrong divisor
        // on both sides of a ratio cancels out), but these displayed
        // numbers were inflated by about 7%.
        let usedGB = usedBytes / 1_073_741_824
        let totalGB = totalBytes / 1_073_741_824
        let text = String(format: "%.0f / %.0f GB used", usedGB, totalGB)
        return ((usedBytes / totalBytes) * 100, text)
    } catch {
        return (nil, "Unavailable")
    }
}

func mountedExtraLocalVolumes() -> [(name: String, valueText: String, usedPercent: Double?, isRemovable: Bool)] {
    let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey, .volumeIsRemovableKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
    guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
        return []
    }
    var results: [(name: String, valueText: String, usedPercent: Double?, isRemovable: Bool)] = []
    for url in urls {
        guard url.path != "/" else { continue }
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
        guard values.volumeIsLocal == true else { continue }
        let name = values.volumeName ?? url.lastPathComponent
        let isRemovable = values.volumeIsRemovable ?? false
        if let available = values.volumeAvailableCapacity, let total = values.volumeTotalCapacity, total > 0 {
            let availableGB = Double(available) / 1_000_000_000
            let totalGB = Double(total) / 1_000_000_000
            let usedGB = totalGB - availableGB
            let text = "\(String(format: "%.0f", usedGB)) / \(String(format: "%.0f", totalGB)) GB used"
            results.append((name, text, (usedGB / totalGB) * 100, isRemovable))
        } else {
            results.append((name, "—", nil, isRemovable))
        }
    }
    return results
}

func mountedNetworkVolumes() -> [(name: String, valueText: String, usedPercent: Double?)] {
    let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
    guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
        return []
    }
    var results: [(name: String, valueText: String, usedPercent: Double?)] = []
    for url in urls {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
        guard values.volumeIsLocal == false else { continue }
        let name = values.volumeName ?? url.lastPathComponent
        if let available = values.volumeAvailableCapacity, let total = values.volumeTotalCapacity, total > 0 {
            let availableGB = Double(available) / 1_000_000_000
            let totalGB = Double(total) / 1_000_000_000
            let usedGB = totalGB - availableGB
            let text = "\(String(format: "%.0f", usedGB)) / \(String(format: "%.0f", totalGB)) GB used"
            results.append((name, text, (usedGB / totalGB) * 100))
        } else {
            results.append((name, "—", nil))
        }
    }
    return results
}

func systemNameAndOS() -> (name: String, os: String) {
    let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let osString = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    return (name, osString)
}

// Model identifier via sysctl (fast, reliable, no shell-out) — gives
// raw strings like "MacBookPro18,2". Model name and chip aren't
// available through sysctl though, so those come from system_profiler
// instead, which is the only reliable source for the human-readable
// name. Only run once at launch, same as System/OS Version, since none
// of this changes during a session.
//
// NOTE: system_profiler's JSON key names ("machine_name", "chip_type")
// are my best recollection, not verified against every macOS version
// from this sandbox — if Model/Chip come back with the "Mac"/"Unknown"
// fallback unexpectedly, run `system_profiler -json SPHardwareDataType`
// directly and check the actual key names against what's parsed below.
func hardwareInfo() -> (modelText: String, chip: String, totalMemoryText: String) {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var modelChars = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &modelChars, &size, nil, 0)
    let rawModel = String(cString: modelChars)

    // Strip the human-readable prefix, keep just the numeric identifier
    // — e.g. "MacBookPro18,2" -> "18,2". General approach that works
    // across model families (MacBookAir, iMac, Mac, etc.) without
    // needing a per-family lookup table.
    let shortIdentifier = String(rawModel.drop(while: { !$0.isNumber }))

    var modelName = "Mac"
    var chip = "Unknown"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    process.arguments = ["-json", "SPHardwareDataType"]
    let outPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = Pipe()
    do {
        try process.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let items = json["SPHardwareDataType"] as? [[String: Any]],
           let hardware = items.first {
            if let name = hardware["machine_name"] as? String { modelName = name }
            if let chipType = hardware["chip_type"] as? String {
                chip = chipType
            } else if let cpuType = hardware["cpu_type"] as? String {
                chip = cpuType
            }
        }
    } catch {
        // leave defaults
    }

    let modelText = shortIdentifier.isEmpty ? modelName : "\(modelName) (\(shortIdentifier))"

    // RAM is physically manufactured in binary power-of-two sizes, and
    // Apple's own "64 GB" label for memory means 64 * 1024^3 bytes, not
    // 64 * 1,000,000,000 — the opposite convention from disk space
    // (where decimal GB is correct, matching Finder's own storage
    // display). Using the decimal divisor here was inflating every
    // memory size by about 7%.
    let totalMemoryGB = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
    let totalMemoryText = "\(totalMemoryGB) GB"

    return (modelText, chip, totalMemoryText)
}

func fetchTopSummary() -> (cpu: String, cpuPercent: Double?) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
    process.arguments = ["-l", "1", "-n", "0"]
    let outPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = Pipe()

    var cpuResult = "Unavailable"
    do {
        try process.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if let output = String(data: data, encoding: .utf8) {
            for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix("CPU usage:") {
                    cpuResult = line.replacingOccurrences(of: "CPU usage: ", with: "")
                }
            }
        }
    } catch {}

    var cpuPercent: Double? = nil
    if let idleRange = cpuResult.range(of: "% idle") {
        let before = cpuResult[..<idleRange.lowerBound]
        let numberText = before.split(separator: " ").last ?? ""
        if let idleValue = Double(numberText) { cpuPercent = 100 - idleValue }
    }
    return (cpuResult, cpuPercent)
}

func fetchNetworkCounters() -> NetworkSample? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
    process.arguments = ["-ib"]
    let outPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = Pipe()
    do {
        try process.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 10, columns[0] == Substring(networkInterfaceName) else { continue }
            if let ibytes = UInt64(columns[6]), let obytes = UInt64(columns[9]) {
                return NetworkSample(bytesIn: ibytes, bytesOut: obytes, timestamp: Date())
            }
        }
    } catch { return nil }
    return nil
}

func networkRates(previous: NetworkSample?, current: NetworkSample) -> (text: String, downBytesPerSecond: Double, upBytesPerSecond: Double)? {
    guard let previous = previous else { return nil }
    let elapsed = current.timestamp.timeIntervalSince(previous.timestamp)
    guard elapsed > 0 else { return nil }
    let inRate = Double(current.bytesIn &- previous.bytesIn) / elapsed
    let outRate = Double(current.bytesOut &- previous.bytesOut) / elapsed
    func formatRate(_ bytesPerSecond: Double) -> String {
        let kbps = bytesPerSecond * 8 / 1000
        if kbps > 1000 { return String(format: "%.1f Mbps", kbps / 1000) }
        return String(format: "%.0f Kbps", kbps)
    }
    return ("↓ \(formatRate(inRate))  ↑ \(formatRate(outRate))", inRate, outRate)
}

// NEW: Local IP address, via getifaddrs (standard low-level BSD socket
// API, not a shell-out — reliable, no external dependency).
func localIPAddress() -> String {
    var address: String? = nil
    var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return "Unavailable" }
    defer { freeifaddrs(ifaddrPtr) }

    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        let interface = ptr.pointee
        guard let ifaAddr = interface.ifa_addr, ifaAddr.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: interface.ifa_name)
        guard name == networkInterfaceName else { continue }
        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(ifaAddr, socklen_t(ifaAddr.pointee.sa_len), &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
        address = String(cString: hostBuffer)
    }
    return address ?? "Unavailable"
}

// Tailscale connection status. Two paths, depending on whether Settings
// has been given a path to the actual `tailscale` binary:
//
// 1. Binary path configured: runs `tailscale status --json` and reads
//    the real "BackendState" field — gives genuine 3-state detection
//    (Running/Starting/other), not just a guess.
// 2. No binary path configured (or the shell-out fails for any reason):
//    falls back to the original heuristic — scanning interfaces for an
//    address in Tailscale's default CGNAT range (100.64.0.0/10). Only
//    ever resolves to connected/not-connected this way, no "Starting"
//    middle state possible.
// Apple's built-in VPN client (System Settings → Network → VPN entries)
// — checked via `scutil --nc list`, Apple's own diagnostic tool for this
// exact purpose. Someone could have multiple VPN profiles configured
// (work, personal, etc.), so this reports green if ANY of them is
// currently connected, rather than requiring all of them to be — unlike
// Syncthing's multi-folder check, "is my traffic going through a VPN
// right now" isn't a state where every profile needs to agree.
//
// Two things confirmed against real output that the earlier lenient
// version got wrong:
// 1. `scutil --nc list` includes non-VPN network connection services
//    too (e.g. a PPP/modem-style entry for a hardware peripheral) — only
//    lines actually tagged "[VPN:...]" are considered.
// 2. Tailscale registers itself as a VPN-type service too
//    ("[VPN:io.tailscale.ipn.macos]"), which was making this row just
//    echo the dedicated Tailscale row above it. Explicitly excluded here
//    since it already has its own row.
func vpnStatus() -> (text: String, state: StoplightState) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
    process.arguments = ["--nc", "list"]
    let outPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = Pipe()
    do {
        try process.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return ("Unavailable", .red) }

        let vpnLines = output.split(separator: "\n").filter { line in
            let lower = line.lowercased()
            return lower.contains("[vpn:") && !lower.contains("tailscale")
        }
        guard !vpnLines.isEmpty else { return ("Not Configured", .red) }

        if vpnLines.contains(where: { $0.contains("(Connected)") }) {
            return ("Connected", .green)
        } else if vpnLines.contains(where: { $0.contains("(Connecting)") }) {
            return ("Connecting…", .yellow)
        } else {
            return ("Not Connected", .red)
        }
    } catch {
        return ("Unavailable", .red)
    }
}

func tailscaleStatus() -> (text: String, state: StoplightState) {
    let config = loadSharedConfig()

    if let binaryPath = config.tailscaleBinaryPath, FileManager.default.isExecutableFile(atPath: binaryPath) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["status", "--json"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let backendState = json["BackendState"] as? String {
                switch backendState {
                case "Running":
                    if let selfInfo = json["Self"] as? [String: Any],
                       let ips = selfInfo["TailscaleIPs"] as? [String], let ip = ips.first {
                        return ("Connected (\(ip))", .green)
                    }
                    return ("Connected", .green)
                case "Starting":
                    return ("Starting…", .yellow)
                default:
                    return (backendState, .red)
                }
            }
        } catch {
            // fall through to the heuristic below
        }
    }

    var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return ("Unknown", .red) }
    defer { freeifaddrs(ifaddrPtr) }

    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        let interface = ptr.pointee
        guard let ifaAddr = interface.ifa_addr, ifaAddr.pointee.sa_family == UInt8(AF_INET) else { continue }
        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(ifaAddr, socklen_t(ifaAddr.pointee.sa_len), &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
        let addr = String(cString: hostBuffer)
        if addr.hasPrefix("100.") {
            return ("Connected (\(addr))", .green)
        }
    }
    return ("Not Connected", .red)
}

// NEW: Battery — public, documented IOKit API (unlike fan RPM, this one
// has a real supported path). Returns nil on machines with no battery
// (Mac Pro), so the row gets hidden entirely rather than showing "N/A".
func batteryInfo() -> (percent: Int, isCharging: Bool, text: String)? {
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
    guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef], let source = sources.first else { return nil }
    guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: AnyObject] else { return nil }

    let capacity = description[kIOPSCurrentCapacityKey] as? Int ?? 0
    let isCharging = (description[kIOPSIsChargingKey] as? Bool) ?? false
    var text = "\(capacity)%"
    if isCharging { text += " (Charging)" }
    return (capacity, isCharging, text)
}

// Syncthing status via its local REST API.
//
// The API key is checked in the shared config file first (written by
// swiftCT's Settings), falling back to a local UserDefaults prompt if
// nothing's configured there yet — so this still works fine if someone
// runs swiftSYSINFO standalone without ever touching swiftCT's Settings.
// NEVER hardcoded in source, given what happened earlier in this project
// with a leaked session key baked into git history.
//
// Two detection paths, same pattern as Tailscale above:
// 1. Folder ID configured: hits /rest/db/status?folder=<id>, reading the
//    real "state" field (idle/syncing/scanning/error) for genuine
//    3-state detection.
// 2. No folder ID configured: falls back to /rest/system/status, which
//    only confirms the daemon is reachable — connected/not-connected
//    only, no real "syncing" state possible this way.
func syncthingAPIKey() -> String? {
    if let sharedKey = loadSharedConfig().syncthingAPIKey, !sharedKey.isEmpty {
        return sharedKey
    }
    return UserDefaults.standard.string(forKey: syncthingAPIKeyDefaultsKey)
}

func promptForSyncthingAPIKey() -> String? {
    let alert = NSAlert()
    alert.messageText = "Syncthing API Key"
    alert.informativeText = "Enter your Syncthing API key to show sync status here (Syncthing web UI → Settings → GUI → API Key). Leave blank to skip. This can also be set from swiftCT's Settings."
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Skip")
    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
    alert.accessoryView = input
    let response = alert.runModal()
    if response == .alertFirstButtonReturn, !input.stringValue.isEmpty {
        UserDefaults.standard.set(input.stringValue, forKey: syncthingAPIKeyDefaultsKey)
        return input.stringValue
    }
    return nil
}

// Fetches status for every configured folder concurrently, then reports
// the WORST state found — a single green light should mean everything
// is genuinely caught up, not just one folder while others lag behind.
// Priority: any folder erroring → red. Otherwise any folder still
// syncing/scanning → yellow. Only fully idle across every folder → green.
func fetchSyncthingStatus(completion: @escaping (String, StoplightState) -> Void) {
    guard let apiKey = syncthingAPIKey(), !apiKey.isEmpty else {
        completion("Not Configured", .red)
        return
    }

    let folderIDs = (loadSharedConfig().syncthingFolderIDs ?? "")
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

    guard !folderIDs.isEmpty else {
        // No folder IDs configured — fall back to a simple reachability check.
        guard let url = URL(string: "http://127.0.0.1:8384/rest/system/status") else {
            completion("Unavailable", .red)
            return
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil,
                  (try? JSONSerialization.jsonObject(with: data)) != nil else {
                DispatchQueue.main.async { completion("Unavailable", .red) }
                return
            }
            DispatchQueue.main.async { completion("Running", .green) }
        }.resume()
        return
    }

    let group = DispatchGroup()
    var states: [String] = []
    let lock = NSLock()

    for folderID in folderIDs {
        group.enter()
        guard let url = URL(string: "http://127.0.0.1:8384/rest/db/status?folder=\(folderID)") else {
            lock.lock(); states.append("error"); lock.unlock()
            group.leave()
            continue
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { group.leave() }
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = json["state"] as? String else {
                lock.lock(); states.append("error"); lock.unlock()
                return
            }
            lock.lock(); states.append(state); lock.unlock()
        }.resume()
    }

    group.notify(queue: .main) {
        if states.contains("error") {
            completion("Error", .red)
        } else if states.contains(where: { $0 == "syncing" || $0 == "scanning" }) {
            completion("Syncing", .yellow)
        } else if !states.isEmpty && states.allSatisfy({ $0 == "idle" }) {
            completion("Up to Date", .green)
        } else {
            completion("Unavailable", .red)
        }
    }
}

// ─────────────────────────────────────────────────────────────
// ABOUT PANEL — same pattern already used in swiftEYES/swiftCLOCK
// ─────────────────────────────────────────────────────────────

final class AboutWindowController: NSWindowController {
    convenience init(appName: String, tagline: String, version: String) {
        let panelSize = NSSize(width: 300, height: 220)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "About \(appName)"
        panel.isReleasedWhenClosed = false
        panel.center()

        let contentView = NSView(frame: NSRect(origin: .zero, size: panelSize))

        let nameLabel = NSTextField(labelWithString: appName)
        nameLabel.font = .boldSystemFont(ofSize: 18)
        nameLabel.alignment = .center
        nameLabel.frame = NSRect(x: 0, y: panelSize.height - 60, width: panelSize.width, height: 24)
        contentView.addSubview(nameLabel)

        let versionLabel = NSTextField(labelWithString: "Version \(version)")
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        versionLabel.frame = NSRect(x: 0, y: panelSize.height - 84, width: panelSize.width, height: 16)
        contentView.addSubview(versionLabel)

        let taglineLabel = NSTextField(wrappingLabelWithString: tagline)
        taglineLabel.font = .systemFont(ofSize: 12)
        taglineLabel.alignment = .center
        taglineLabel.textColor = .labelColor
        taglineLabel.frame = NSRect(x: 24, y: 50, width: panelSize.width - 48, height: 90)
        contentView.addSubview(taglineLabel)

        let okButton = NSButton(title: "OK", target: nil, action: #selector(NSWindow.performClose(_:)))
        okButton.bezelStyle = .rounded
        okButton.frame = NSRect(x: (panelSize.width - 80) / 2, y: 14, width: 80, height: 28)
        okButton.keyEquivalent = "\r"
        contentView.addSubview(okButton)

        panel.contentView = contentView
        self.init(window: panel)
    }
}

// ─────────────────────────────────────────────────────────────
// AppDelegate
// ─────────────────────────────────────────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var isDarkMode = true   // defaults to dark, matching swiftCT's own default theme

    var telemetryTimer: Timer?
    var networkTimer: Timer?
    var telemetryLabels: [String: NSTextField] = [:]
    var telemetryDots: [String: NSView] = [:]
    var telemetryBars: [String: PercentBar] = [:]
    var telemetryNetworkBars: [String: NetworkBarView] = [:]
    var lastNetworkSample: NetworkSample?
    var reverseColorsMenuItem: NSMenuItem?
    var contextMenuReverseItem: NSMenuItem?
    var scaleFactor: CGFloat = 1.0
    var aboutWindowController: AboutWindowController?

    var background: NSColor { isDarkMode ? darkBackground : lightBackground }
    var foreground: NSColor { isDarkMode ? darkForeground : lightForeground }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindow()
        setUpMainMenu()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startRefresh()

        // Prompt for the Syncthing API key once, if never configured.
        if syncthingAPIKey() == nil {
            _ = promptForSyncthingAPIKey()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Window construction

    func buildWindow() {
        let s = scaleFactor
        let winWidth: CGFloat = 300 * s
        let plainRowHeight: CGFloat = 30 * s
        let visualRowHeight: CGFloat = 50 * s

        let (systemName, osVersion) = systemNameAndOS()
        let (modelText, chip, totalMemoryText) = hardwareInfo()
        let extraLocalVolumes = mountedExtraLocalVolumes()
        let networkVolumes = mountedNetworkVolumes()
        let battery = batteryInfo()
        let visibilityConfig = loadSharedConfig()
        let showTailscale = visibilityConfig.showTailscale ?? true
        let showSyncthing = visibilityConfig.showSyncthing ?? true
        let showVPN = visibilityConfig.showVPN ?? true

        var rows: [(title: String, key: String, symbol: String, visual: RowVisual, barColor: NSColor)] = [
            ("System", "system", "desktopcomputer", .none, .clear),
            ("Model", "model", "macbook", .none, .clear),
            ("Chip", "chip", "cpu", .none, .clear),
            ("Total Memory", "totalmem", "memorychip", .none, .clear),
            ("OS Version", "os", "gearshape", .none, .clear),
            ("Uptime", "uptime", "clock", .none, .clear),
            ("Local IP", "ip", "network", .none, .clear)
        ]
        if showVPN {
            rows.append(("VPN", "vpn", "network.badge.shield.half.filled", .none, .clear))
        }
        if showTailscale {
            rows.append(("Tailscale", "tailscale", "lock.shield", .none, .clear))
        }
        if showSyncthing {
            rows.append(("Syncthing", "syncthing", "arrow.triangle.2.circlepath", .none, .clear))
        }
        if battery != nil {
            rows.append(("Battery", "battery", "battery.100", .none, .clear))
        }
        rows.append(contentsOf: [
            ("CPU", "cpu", "cpu", .percentBar, letterColor_f),
            ("Memory", "memory", "memorychip", .percentBar, .systemGreen),
            ("Disk", "disk", "internaldrive", .percentBar, letterColor_s)
        ])
        for (index, volume) in extraLocalVolumes.enumerated() {
            let color = volume.isRemovable ? letterColor_i : letterColor_s
            let symbol = volume.isRemovable ? "externaldrive" : "internaldrive"
            rows.append((volume.name, "localvol\(index)", symbol, .percentBar, color))
        }
        for (index, volume) in networkVolumes.enumerated() {
            rows.append((volume.name, "netvol\(index)", "externaldrive.connected.to.line.below", .percentBar, magentaColor))
        }
        rows.append(("Network", "network", "network", .networkBar, .clear))

        let totalRowsHeight = rows.reduce(CGFloat(0)) { sum, row in
            sum + (row.visual == .none ? plainRowHeight : visualRowHeight)
        }
        let winHeight: CGFloat = 30 * s + totalRowsHeight

        let frame = NSRect(x: 0, y: 0, width: winWidth, height: winHeight)
        if let existingWindow = window {
            // Rebuild case (Bigger/Smaller) — resize the existing window
            // in place rather than tearing down and recreating it, so it
            // doesn't flicker. Growing/shrinking around the window's own
            // current center (rather than keeping its bottom-left corner
            // fixed) keeps it from drifting off-screen after repeated
            // growth, while still respecting wherever it's positioned
            // rather than forcing a screen re-center.
            //
            // Critically: `frame` above is a CONTENT size (winWidth,
            // winHeight), but setFrame() sets the window's TOTAL frame
            // including the title bar. Passing the content size directly
            // was making the actual usable content area shorter than
            // intended by exactly the title bar's height — the real
            // cause of the clipping, not the positioning math fixed
            // yesterday. frameRect(forContentRect:) does the correct
            // conversion, the same one NSWindow's own initializer
            // performs internally for the first-launch case below.
            let fullFrameRect = existingWindow.frameRect(forContentRect: frame)
            let oldFrame = existingWindow.frame
            let oldCenter = NSPoint(x: oldFrame.midX, y: oldFrame.midY)
            let newOrigin = NSPoint(x: oldCenter.x - fullFrameRect.width / 2, y: oldCenter.y - fullFrameRect.height / 2)
            existingWindow.setFrame(NSRect(origin: newOrigin, size: fullFrameRect.size), display: true)
        } else {
            window = NSWindow(
                contentRect: frame,
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "System Info"
            window.center()
        }
        window.backgroundColor = background

        let content = NSView(frame: NSRect(x: 0, y: 0, width: winWidth, height: winHeight))
        content.wantsLayer = true
        content.layer?.backgroundColor = background.cgColor
        content.menu = buildContextMenu()

        var y = winHeight - 20 * s
        for row in rows {
            let rowHeight = (row.visual == .none) ? plainRowHeight : visualRowHeight

            if row.visual == .none {
                if ["tailscale", "syncthing", "battery", "vpn"].contains(row.key) {
                    // Combined "Title (Status)" label on the left, dot on
                    // the right — no separate value field for these three.
                    let combinedLabel = NSTextField(labelWithString: row.title)
                    combinedLabel.font = NSFont.boldSystemFont(ofSize: 11 * s)
                    combinedLabel.textColor = foreground
                    combinedLabel.lineBreakMode = .byTruncatingTail
                    combinedLabel.frame = NSRect(x: 16 * s, y: y - 12 * s, width: winWidth - 60 * s, height: 14 * s)
                    content.addSubview(combinedLabel)
                    telemetryLabels[row.key] = combinedLabel

                    let dot = NSView(frame: NSRect(x: winWidth - 30 * s, y: y - 12 * s, width: 12 * s, height: 12 * s))
                    dot.wantsLayer = true
                    dot.layer?.cornerRadius = 6 * s
                    dot.layer?.backgroundColor = NSColor.gray.cgColor   // placeholder until first refresh sets the real state
                    content.addSubview(dot)
                    telemetryDots[row.key] = dot
                } else {
                    let icon = NSImageView(frame: NSRect(x: 16 * s, y: y - 14 * s, width: 16 * s, height: 16 * s))
                    icon.image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: row.title)
                    icon.contentTintColor = foreground
                    content.addSubview(icon)

                    let label = NSTextField(labelWithString: row.title)
                    label.font = NSFont.boldSystemFont(ofSize: 11 * s)
                    label.textColor = foreground
                    label.frame = NSRect(x: 38 * s, y: y - 12 * s, width: 110 * s, height: 14 * s)
                    content.addSubview(label)

                    let value = NSTextField(labelWithString: "—")
                    value.font = NSFont.systemFont(ofSize: 11 * s)
                    value.textColor = foreground
                    value.lineBreakMode = .byTruncatingTail
                    value.alignment = .right
                    value.frame = NSRect(x: winWidth - 148 * s, y: y - 12 * s, width: 132 * s, height: 14 * s)
                    content.addSubview(value)
                    telemetryLabels[row.key] = value
                }
            } else {
                let icon = NSImageView(frame: NSRect(x: 16 * s, y: y - 14 * s, width: 16 * s, height: 16 * s))
                icon.image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: row.title)
                icon.contentTintColor = foreground
                content.addSubview(icon)

                let label = NSTextField(labelWithString: row.title)
                label.font = NSFont.boldSystemFont(ofSize: 11 * s)
                label.textColor = foreground
                label.frame = NSRect(x: 38 * s, y: y - 12 * s, width: 150 * s, height: 14 * s)
                content.addSubview(label)

                switch row.visual {
                case .percentBar:
                    let bar = PercentBar(frame: NSRect(x: 16 * s, y: y - 28 * s, width: winWidth - 32 * s, height: 6 * s))
                    bar.barColor = row.barColor
                    content.addSubview(bar)
                    telemetryBars[row.key] = bar
                case .networkBar:
                    let bar = NetworkBarView(frame: NSRect(x: 16 * s, y: y - 28 * s, width: winWidth - 32 * s, height: 6 * s))
                    content.addSubview(bar)
                    telemetryNetworkBars[row.key] = bar
                case .none:
                    break
                }

                let value = NSTextField(labelWithString: "—")
                value.font = NSFont.systemFont(ofSize: 10 * s)
                value.textColor = foreground.withAlphaComponent(0.75)
                value.alignment = .center
                value.frame = NSRect(x: 16 * s, y: y - 46 * s, width: winWidth - 32 * s, height: 12 * s)
                content.addSubview(value)
                telemetryLabels[row.key] = value
            }
            y -= rowHeight
        }

        telemetryLabels["system"]?.stringValue = systemName
        telemetryLabels["model"]?.stringValue = modelText
        telemetryLabels["chip"]?.stringValue = chip
        telemetryLabels["totalmem"]?.stringValue = totalMemoryText
        telemetryLabels["os"]?.stringValue = osVersion
        if let battery = battery {
            let font = telemetryLabels["battery"]?.font ?? NSFont.boldSystemFont(ofSize: 11)
            telemetryLabels["battery"]?.attributedStringValue = batteryAttributedString(percent: battery.percent, isCharging: battery.isCharging, font: font, foreground: foreground)
            telemetryDots["battery"]?.layer?.backgroundColor = batteryStoplight(percent: battery.percent).color.cgColor
        }
        for (index, volume) in extraLocalVolumes.enumerated() {
            telemetryLabels["localvol\(index)"]?.stringValue = volume.valueText
            if let percent = volume.usedPercent { telemetryBars["localvol\(index)"]?.setPercent(percent) }
        }
        for (index, volume) in networkVolumes.enumerated() {
            telemetryLabels["netvol\(index)"]?.stringValue = volume.valueText
            if let percent = volume.usedPercent { telemetryBars["netvol\(index)"]?.setPercent(percent) }
        }

        window.contentView = content
    }

    // Tears down and rebuilds the whole window at the current
    // scaleFactor. Unlike swiftEYES/swiftCLOCK — whose drawing is
    // continuously recalculated from view bounds, so a plain window
    // resize scales everything for free — this window's rows are laid
    // out with absolute positions computed once. Bigger/Smaller here
    // means "rebuild everything from scratch at a new scale," not just
    // resizing the frame.
    func rebuildWindow() {
        telemetryLabels.removeAll()
        telemetryBars.removeAll()
        telemetryNetworkBars.removeAll()
        telemetryDots.removeAll()
        buildWindow()
        refreshNetwork()   // freshly-built labels start at placeholder "—" values, repopulate immediately
        refreshSlow()
    }

    @objc func growWindow() {
        scaleFactor = min(1.6, scaleFactor + 0.12)
        rebuildWindow()
    }

    @objc func shrinkWindow() {
        scaleFactor = max(0.7, scaleFactor - 0.12)
        rebuildWindow()
    }

    // Right-click context menu — same four actions as swiftEYES/swiftCLOCK,
    // built fresh each time so the Reverse Colors checkmark always reflects
    // current state.
    func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Bigger", action: #selector(growWindow), keyEquivalent: "")
        menu.addItem(withTitle: "Smaller", action: #selector(shrinkWindow), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        let reverseItem = NSMenuItem(title: "Reverse Colors", action: #selector(toggleColorMode), keyEquivalent: "")
        reverseItem.state = isDarkMode ? .off : .on
        contextMenuReverseItem = reverseItem
        menu.addItem(reverseItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: - Menu

    func setUpMainMenu() {
        let mainMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(showAboutPanel), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Bigger", action: #selector(growWindow), keyEquivalent: "=")
        viewMenu.addItem(withTitle: "Smaller", action: #selector(shrinkWindow), keyEquivalent: "-")
        viewMenu.addItem(NSMenuItem.separator())
        let reverseItem = NSMenuItem(title: "Reverse Colors", action: #selector(toggleColorMode), keyEquivalent: "i")
        reverseItem.state = isDarkMode ? .off : .on   // dark IS the default, so "reversed" means light
        viewMenu.addItem(reverseItem)
        reverseColorsMenuItem = reverseItem
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Set Syncthing API Key…", action: #selector(setSyncthingKey), keyEquivalent: "")
        viewMenuItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }

    @objc func toggleColorMode() {
        isDarkMode.toggle()
        reverseColorsMenuItem?.state = isDarkMode ? .off : .on
        contextMenuReverseItem?.state = isDarkMode ? .off : .on
        applyColors()
        // applyColors() sets .textColor on plain-text fields, but that
        // has no effect on the battery row specifically, which uses
        // .attributedStringValue (needed to color "Charging" distinctly)
        // — its embedded color attributes take precedence over the
        // field's own .textColor property. Refreshing rebuilds that
        // attributed string using the now-current foreground color.
        refreshSlow()
    }

    @objc func setSyncthingKey() {
        _ = promptForSyncthingAPIKey()
    }

    func applyColors() {
        window.backgroundColor = background
        window.contentView?.layer?.backgroundColor = background.cgColor
        for subview in window.contentView?.subviews ?? [] {
            if let label = subview as? NSTextField {
                label.textColor = foreground
            } else if let icon = subview as? NSImageView {
                icon.contentTintColor = foreground
            }
        }
    }

    @objc func showAboutPanel() {
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController(
                appName: "swiftSYSINFO",
                tagline: "A BGInfo-style system info panel for swiftSUITE — CPU, memory, disk, network, and more at a glance.",
                version: "1.0"
            )
        }
        aboutWindowController?.showWindow(nil)
        aboutWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Refresh loop

    func startRefresh() {
        refreshNetwork()
        refreshSlow()

        networkTimer?.invalidate()
        networkTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshNetwork()
        }

        telemetryTimer?.invalidate()
        telemetryTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { [weak self] _ in
            self?.refreshSlow()
        }
    }

    // The only thing that genuinely benefits from feeling "live" — a
    // bidirectional rate bar reads as broken if it updates sluggishly.
    // Kept on its own fast timer, completely independent of everything
    // else. The rate math itself is based on actual elapsed time between
    // samples (not an assumed fixed interval), so this cadence is free
    // to change without touching that calculation at all.
    func refreshNetwork() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            var networkText = "Calculating…"
            var downRate: Double = 0
            var upRate: Double = 0
            if let sample = fetchNetworkCounters() {
                if let rates = networkRates(previous: self.lastNetworkSample, current: sample) {
                    networkText = rates.text
                    downRate = rates.downBytesPerSecond
                    upRate = rates.upBytesPerSecond
                }
                self.lastNetworkSample = sample
            } else {
                networkText = "Unavailable"
            }

            DispatchQueue.main.async {
                self.telemetryLabels["network"]?.stringValue = networkText
                self.telemetryNetworkBars["network"]?.setRates(downBytesPerSecond: downRate, upBytesPerSecond: upRate)
            }
        }
    }

    // Everything else — none of these numbers need sub-5-second
    // granularity for a glanceable dashboard, and each one costs a real
    // subprocess spawn (or network request, for Syncthing), so a slower
    // cadence here meaningfully cuts down on background energy use.
    // Optional rows (VPN/Tailscale/Syncthing) skip their check entirely
    // when hidden in Settings, rather than paying the cost for a row
    // that isn't even displayed.
    func refreshSlow() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            let (cpuRawText, cpuPercent) = fetchTopSummary()
            let cpuText = cpuPercent.map { "\(Int($0))% used" } ?? cpuRawText
            let (memoryPercent, memoryText) = fetchMemoryInfo()
            let uptime = formattedUptime()
            let (diskText, diskPercent) = diskSpaceInfo()
            let ip = localIPAddress()
            let battery = batteryInfo()

            let visibilityConfig = loadSharedConfig()
            let showTailscale = visibilityConfig.showTailscale ?? true
            let showVPN = visibilityConfig.showVPN ?? true
            let showSyncthing = visibilityConfig.showSyncthing ?? true

            let tailscale = showTailscale ? tailscaleStatus() : nil
            let vpn = showVPN ? vpnStatus() : nil

            DispatchQueue.main.async {
                self.telemetryLabels["cpu"]?.stringValue = cpuText
                self.telemetryLabels["memory"]?.stringValue = memoryText
                self.telemetryLabels["uptime"]?.stringValue = uptime
                self.telemetryLabels["disk"]?.stringValue = diskText
                self.telemetryLabels["ip"]?.stringValue = ip

                if let tailscale = tailscale {
                    let tailscaleShort: String
                    switch tailscale.state {
                    case .green: tailscaleShort = "Connected"
                    case .yellow: tailscaleShort = "Starting"
                    case .red: tailscaleShort = "Not Connected"
                    }
                    self.telemetryLabels["tailscale"]?.stringValue = "Tailscale (\(tailscaleShort))"
                    self.telemetryDots["tailscale"]?.layer?.backgroundColor = tailscale.state.color.cgColor
                }

                if let vpn = vpn {
                    self.telemetryLabels["vpn"]?.stringValue = "VPN (\(vpn.text))"
                    self.telemetryDots["vpn"]?.layer?.backgroundColor = vpn.state.color.cgColor
                }

                if let battery = battery {
                    let font = self.telemetryLabels["battery"]?.font ?? NSFont.boldSystemFont(ofSize: 11)
                    self.telemetryLabels["battery"]?.attributedStringValue = batteryAttributedString(percent: battery.percent, isCharging: battery.isCharging, font: font, foreground: self.foreground)
                    self.telemetryDots["battery"]?.layer?.backgroundColor = batteryStoplight(percent: battery.percent).color.cgColor
                }

                if let cpuPercent = cpuPercent { self.telemetryBars["cpu"]?.setPercent(cpuPercent) }
                if let diskPercent = diskPercent { self.telemetryBars["disk"]?.setPercent(diskPercent) }
                if let memoryPercent = memoryPercent { self.telemetryBars["memory"]?.setPercent(memoryPercent) }
            }

            if showSyncthing {
                fetchSyncthingStatus { status, state in
                    self.telemetryLabels["syncthing"]?.stringValue = "Syncthing (\(status))"
                    self.telemetryDots["syncthing"]?.layer?.backgroundColor = state.color.cgColor
                }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()