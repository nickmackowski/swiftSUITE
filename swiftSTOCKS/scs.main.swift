import Foundation

// MARK: - App Storage Location

/// Resolves the directory the compiled binary itself lives in (not the current working
/// directory, which varies by how the app is launched). Kept consistent with swiftMAIL's
/// approach so a folder-sync tool like Syncthing, pointed at this directory, carries
/// stocks.json and the debug log between machines if you want that.
func resolveAppDataDirectory() -> URL {
    let executablePath = CommandLine.arguments.first ?? "."
    return URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().deletingLastPathComponent()
}

// MARK: - Debug Logger

class StocksDebugLogger {
    static let logURL: URL = resolveAppDataDirectory().appendingPathComponent("swiftstocks_debug.log")
    
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
        }
    }
}

// MARK: - Number Formatter Utility

struct Format {
    /// Formats a Double to a string with thousand separators and 1 decimal place.
    static func comma(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }
}

// MARK: - Models

struct StockPosition: Codable {
    var id: UUID = UUID()
    var symbol: String = ""
    var companyName: String = "Unknown Corp"
    var shares: Double = 0.0
    var purchasePrice: Double = 0.0
    var isPaperStock: Bool = false // true = Mock trade, false = Live position
    var currentPrice: Double = 0.0
    var dayChange: Double = 0.0       // today's price change in dollars
    var dayChangePct: Double = 0.0    // today's price change as a percentage
    var week52Low: Double = 0.0       // 52-week low price
    var week52High: Double = 0.0      // 52-week high price
    
    var totalValue: Double { shares * currentPrice }
    var totalCost: Double { shares * purchasePrice }
    var gainLoss: Double { totalValue - totalCost }
    var gainLossPct: Double { totalCost != 0 ? (gainLoss / totalCost) * 100 : 0 }
}

// MARK: - Navigation State

enum StockScreen {
    case workspace
    case addNewStock
    case globalSearch
    case selectLedgerResult(results: [StockPosition], title: String)
    case viewStock(index: Int)
    case editStock(index: Int)
    case utilitiesMenu
}

// MARK: - Interactive Keyboard Engine

enum StockKeyPress {
    case up
    case down
    case enter
    case escape
    case number(Int)
    case other(Character)
}

class StockKeyboardReader {
    private var originalTermios = termios()

    func enableRawMode() {
        var raw = termios()
        tcgetattr(STDIN_FILENO, &originalTermios)
        raw = originalTermios
        raw.c_lflag &= ~(tcflag_t(ECHO) | tcflag_t(ICANON))
        raw.c_cc.16 = 1 // VMIN = 1
        raw.c_cc.17 = 0 // VTIME = 0
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    }

    func disableRawMode() {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
    }

    func readKey() -> StockKeyPress {
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
}

// MARK: - Application Core Logic

class StocksManager {
    var stocks: [StockPosition] = []
    var screenStack: [StockScreen] = [.workspace]
    var running = true
    var selectedIdx = 0
    
    let keyboard = StockKeyboardReader()
    let fileURL = resolveAppDataDirectory().appendingPathComponent("stocks.json")
    
    // Each syncLiveQuotes() call fires off one URLSession task per symbol; their completion
    // handlers run concurrently on background queues with no ordering guarantee. Array is not
    // safe to mutate from multiple threads at once — even writes to different indices can race
    // on the shared copy-on-write storage buffer. This serializes every mutation of `stocks`
    // (and the shared `updatedCount` counter) from those completion handlers.
    private let stocksMutationLock = NSLock()
    
    var machineName: String = "macOS"
    var uptime: String = "Unknown"
    var cpuUsage: String = "0%"
    var memUsage: String = "0G"
    
    // Tracks the timestamp of the last database API synchronization pull
    var lastDataPullTimestamp: String = "Never"
    var lastStatusMessage: String? = nil
    var lastStatusWasError = false
    
    init() {
        loadDatabase()
        parseLauncherArguments()
        
        // Initial visual splash sync at program initialization
        syncLiveQuotes(isSilent: false)
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
    
    // MARK: - Remote Data Management Engine
    
    /// Contacts Yahoo Finance API. Set `isSilent: true` to bypass terminal output logs completely.
    func syncLiveQuotes(isSilent: Bool = false) {
        if stocks.isEmpty { 
            let formatter = DateFormatter()
            formatter.dateFormat = "hh:mm:ss a"
            lastDataPullTimestamp = formatter.string(from: Date()).uppercased()
            return 
        }
        
        if !isSilent {
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()
            print("")
            print("╭" + String(repeating: "─", count: 118) + "╮")
            let fetchingMsg = "  Fetching live quotes for \(stocks.count) position\(stocks.count == 1 ? "" : "s")..."
            let fetchPad = max(0, 118 - fetchingMsg.count)
            print("│\(fetchingMsg)\(String(repeating: " ", count: fetchPad))│")
            print("├" + String(repeating: "─", count: 118) + "┤")
        }
        
        let dispatchGroup = DispatchGroup()
        var updatedCount = 0
        
        for i in 0..<stocks.count {
            let symbol = stocks[i].symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if symbol.isEmpty { continue }
            
            guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)?interval=1m&range=1d") else { continue }
            
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 4.0
            
            dispatchGroup.enter()
            let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                defer { dispatchGroup.leave() }
                guard let self = self else { return }
                
                let paddedSymbol = symbol.padding(toLength: 6, withPad: " ", startingAt: 0)
                
                guard let data = data, error == nil else {
                    if !isSilent {
                        let msg = "  \(paddedSymbol)  Network error — skipping"
                        let pad = max(0, 118 - msg.count)
                        print("│\(msg)\(String(repeating: " ", count: pad))│")
                    }
                    StocksDebugLogger.log("Sync network error for \(symbol): \(error?.localizedDescription ?? "unknown")", category: "NET-ERR")
                    return
                }
                
                if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let chart = json["chart"] as? [String: Any],
                   let resultList = chart["result"] as? [[String: Any]],
                   let firstResult = resultList.first,
                   let meta = firstResult["meta"] as? [String: Any] {
                    
                    var livePrice = meta["regularMarketPrice"] as? Double
                    if livePrice == nil { livePrice = meta["previousClose"] as? Double }
                    
                    if let finalPrice = livePrice, finalPrice > 0.0 {
                        self.stocksMutationLock.lock()
                        self.stocks[i].currentPrice = finalPrice
                        if let longName = meta["longName"] as? String {
                            self.stocks[i].companyName = longName
                        }
                        if let dc = meta["regularMarketChange"] as? Double {
                            self.stocks[i].dayChange = dc
                        }
                        if let dcp = meta["regularMarketChangePercent"] as? Double {
                            self.stocks[i].dayChangePct = dcp
                        }
                        if let low52 = meta["fiftyTwoWeekLow"] as? Double {
                            self.stocks[i].week52Low = low52
                        }
                        if let high52 = meta["fiftyTwoWeekHigh"] as? Double {
                            self.stocks[i].week52High = high52
                        }
                        updatedCount += 1
                        self.stocksMutationLock.unlock()
                        
                        if !isSilent {
                            let priceStr = String(format: "$%.2f", finalPrice)
                            let statusColor = "\u{001B}[1;32m"
                            let reset = "\u{001B}[0m"
                            let visibleMsg = "  \(paddedSymbol)  \(priceStr)"
                            let coloredMsg = "  \(paddedSymbol)  \(statusColor)\(priceStr)\(reset)"
                            let pad = max(0, 118 - visibleMsg.count)
                            print("│\(coloredMsg)\(String(repeating: " ", count: pad))│")
                        }
                    } else {
                        if !isSilent {
                            let msg = "  \(paddedSymbol)  No price available"
                            let pad = max(0, 118 - msg.count)
                            print("│\(msg)\(String(repeating: " ", count: pad))│")
                        }
                        StocksDebugLogger.log("Sync returned no usable price for \(symbol)", category: "PARSE-ERR")
                    }
                } else {
                    if !isSilent {
                        let msg = "  \(paddedSymbol)  Could not parse response"
                        let pad = max(0, 118 - msg.count)
                        print("│\(msg)\(String(repeating: " ", count: pad))│")
                    }
                    StocksDebugLogger.log("Sync parse error for \(symbol): unexpected response shape", category: "PARSE-ERR")
                }
            }
            task.resume()
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        dispatchGroup.wait()
        
        let formatter = DateFormatter()
        formatter.dateFormat = "hh:mm:ss a"
        lastDataPullTimestamp = formatter.string(from: Date()).uppercased()
        
        StocksDebugLogger.log("Sync finished: \(updatedCount)/\(stocks.count) symbols updated", category: "SYNC")
        
        if updatedCount > 0 { saveDatabase() }
        
        if !isSilent {
            print("├" + String(repeating: "─", count: 118) + "┤")
            let doneMsg = "  \(updatedCount) of \(stocks.count) position\(stocks.count == 1 ? "" : "s") updated  ·  \(lastDataPullTimestamp)"
            let donePad = max(0, 118 - doneMsg.count)
            print("│\(doneMsg)\(String(repeating: " ", count: donePad))│")
            print("╰" + String(repeating: "─", count: 118) + "╯")
            Thread.sleep(forTimeInterval: 0.8)
        }
    }
    
    func navigate(to screen: StockScreen) { screenStack.append(screen) }
    func goBack() { if screenStack.count > 1 { screenStack.removeLast() } }
    
    func run() {
        while running {
            guard let currentScreen = screenStack.last else { running = false; break }
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "") 
            switch currentScreen {
            case .workspace: showWorkspace()
            case .addNewStock: showAddNewStockScreen()
            case .globalSearch: showGlobalSearchScreen()
            case .selectLedgerResult(let res, let title): showSelectLedgerResultScreen(results: res, title: title)
            case .viewStock(let idx): showViewStockScreen(index: idx)
            case .editStock(let idx): showEditStockScreen(index: idx)
            case .utilitiesMenu: showUtilitiesMenu()
            }
        }
    }
    
    // MARK: - Unified Layout Engine
    
    private func printStandardHeader(context: String? = nil) {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MM-dd-yy"
        let dateString = dateFormatter.string(from: now)
        
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "hh:mm:ss a"
        let timeString = timeFormatter.string(from: now).uppercased()
        
        let innerWidth = 118  // 120 total - 2 for │ border chars
        
        let titleText = "swiftSTOCKS v2.5.07.14c"  // plain for layout; c colored below
        let sidePadding = (innerWidth - titleText.count) / 2
        
        var titleLineChars = Array(repeating: " ", count: innerWidth)
        for (i, ch) in dateString.enumerated() where i < innerWidth { titleLineChars[i] = String(ch) }
        for (i, ch) in titleText.enumerated() { titleLineChars[sidePadding + i] = String(ch) }
        // Color the trailing 'c' orange without affecting layout positions
        titleLineChars[sidePadding + titleText.count - 1] = "\u{001B}[38;5;208mc\u{001B}[0m"
        let timeStartIndex = innerWidth - timeString.count
        for (i, ch) in timeString.enumerated() { titleLineChars[timeStartIndex + i] = String(ch) }
        let combinedTitleLine = titleLineChars.joined()
        
        let segment1Colored = "User: \u{001B}[1;33mjzmfcz\u{001B}[0m"
        let segment1Raw = "User: jzmfcz"
        let segment2 = "Connected: [\(machineName)]"
        let segment3 = "Host Uptime: \(uptime)"
        let segment4 = "CPU: \(cpuUsage)"
        let segment5 = "Mem: \(memUsage)"
        
        let totalTextCount = segment1Raw.count + segment2.count + segment3.count + segment4.count + segment5.count
        let remainingSpaces = max(4, innerWidth - totalTextCount)
        let spaceInterval = remainingSpaces / 4
        let baseSpaces = String(repeating: " ", count: spaceInterval)
        let extraSpacesCount = remainingSpaces % 4
        let gap1 = baseSpaces + (extraSpacesCount > 0 ? " " : "")
        let gap2 = baseSpaces + (extraSpacesCount > 1 ? " " : "")
        let gap3 = baseSpaces + (extraSpacesCount > 2 ? " " : "")
        let combinedTelemetryLine = "\(segment1Colored)\(gap1)\(segment2)\(gap2)\(segment3)\(gap3)\(segment4)\(baseSpaces)\(segment5)"
        let telemetryRaw = "\(segment1Raw)\(gap1)\(segment2)\(gap2)\(segment3)\(gap3)\(segment4)\(baseSpaces)\(segment5)"
        let telemetryPad = max(0, innerWidth - telemetryRaw.count)
        
        print("╭" + String(repeating: "─", count: innerWidth) + "╮")
        print("│" + combinedTitleLine + "│")
        print("│" + combinedTelemetryLine + String(repeating: " ", count: telemetryPad) + "│")
        
        // Optional context line — centered inside the box, e.g. company name + ticker on the
        // detail screen. All other screens call printStandardHeader() with no argument and get
        // the standard 4-line header unchanged.
        if let context = context {
            let ctxPad = max(0, (innerWidth - context.count) / 2)
            let ctxRight = max(0, innerWidth - ctxPad - context.count)
            print("│" + String(repeating: " ", count: ctxPad) + context + String(repeating: " ", count: ctxRight) + "│")
        }
        
        print("╰" + String(repeating: "─", count: innerWidth) + "╯")
    }
    
    /// Workspace-only status block, matching the 2-line left/right pattern used by
    /// vault/notes/contacts (entity count + a badge on line 1, a secondary metric + a second
    /// badge on line 2) rather than the old asterisk-banner style repeated on every screen.
    private func printPortfolioStatusBlock() {
        let posLabel = "\(stocks.count) Position\(stocks.count == 1 ? "" : "s") Held"
        let leftText = " PORTFOLIO: \(posLabel)"
        
        let calendar = Calendar.current
        let now = Date()
        let weekday = calendar.component(.weekday, from: now)
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let timeInMinutes = (hour * 60) + minute
        let isWeekend = (weekday == 1 || weekday == 7)
        let isMarketHours = (timeInMinutes >= (9 * 60 + 30) && timeInMinutes < (16 * 60))
        let marketOpen = !isWeekend && isMarketHours
        
        let rightText = marketOpen ? "● MARKET OPEN" : "● MARKET CLOSED"
        let rightColor = marketOpen ? "\u{001B}[1;32m" : "\u{001B}[1;31m"
        let pad1 = max(1, 119 - leftText.count - rightText.count)
        print("\u{001B}[1;37m PORTFOLIO:\u{001B}[0m \(posLabel)\(String(repeating: " ", count: pad1))\(rightColor)\(rightText)\u{001B}[0m")
        
        let totalGL = stocks.reduce(0.0) { $0 + $1.gainLoss }
        let totalCost = stocks.reduce(0.0) { $0 + $1.totalCost }
        let totalGLPercent = totalCost != 0 ? (totalGL / totalCost) * 100 : 0
        let sign = totalGL >= 0 ? "+" : "-"
        let glColor = totalGL >= 0 ? "\u{001B}[1;32m" : "\u{001B}[1;31m"
        
        let leftText2 = " Last Data Pull: \(lastDataPullTimestamp)  [R] to refresh"
        let rightText2 = "● Gain/Loss: \(sign)$\(Format.comma(abs(totalGL))) (\(sign)\(String(format: "%.2f", abs(totalGLPercent)))%)"
        let pad2 = max(1, 119 - leftText2.count - rightText2.count)
        print("\(leftText2)\(String(repeating: " ", count: pad2))\(glColor)\(rightText2)\u{001B}[0m")
    }
    
    private func printStandardFooter(keys: String) {
        let innerWidth = 118  // 120 total - 2 for │ border chars
        
        // Wrap if needed, then center each line inside the rounded box
        let segments = keys.components(separatedBy: "|")
        var wrappedLines: [String] = []
        var current = ""
        for segment in segments {
            let candidate = current.isEmpty ? segment : "\(current)|\(segment)"
            if candidate.count <= innerWidth { current = candidate }
            else { if !current.isEmpty { wrappedLines.append(current) }; current = segment }
        }
        if !current.isEmpty { wrappedLines.append(current) }
        
        print("╭" + String(repeating: "─", count: innerWidth) + "╮")
        for line in wrappedLines {
            let pad = max(0, (innerWidth - line.count) / 2)
            let right = max(0, innerWidth - pad - line.count)
            print("│" + String(repeating: " ", count: pad) + line + String(repeating: " ", count: right) + "│")
        }
        print("╰" + String(repeating: "─", count: innerWidth) + "╯")
    }
    
    private func centerSubtitle(_ title: String) {
        let totalWidth = 120
        let paddingSize = max(0, (totalWidth - title.count - 8) / 2)
        let paddingSpaces = String(repeating: " ", count: paddingSize)
        print("\(paddingSpaces)─── \(title) ───")
    }
    
    // MARK: - UI Screens
    
    // MARK: - Shared Grid Layout Helpers
    //
    // 120-column pipe-free greenbar design. No +---+---+ box drawing — columns separated by
    // 2-space gaps, alternating dark-green background bands give the classic tractor-feed paper
    // look on the clear-dark terminal theme. printStandardHeader/Footer use the same 120 so
    // everything lines up consistently. Both the workspace and search-results screens share one
    // implementation rather than two copies that could drift apart.
    //
    // Column layout (verified at exactly 120 chars):
    // indent(2) + num(2) + gap(2) + flags(2) + gap(2) + name(28) + gap(2) + sym(6) + gap(2) +
    // shares(8) + gap(2) + cost(9) + gap(2) + market(9) + gap(2) + value(11) + gap(2) +
    // gl(13) + gap(2) + glpct(9) + gap(2) + class(1) = 120
    
    private let wNum = 2, wFlags = 2, wName = 25, wSym = 6, wShares = 8,
                wCost = 9, wMarket = 9, wValue = 11, wGL = 13, wGLPct = 9, wClass = 4
    private let colGap = "  "  // 2-space separator between every column
    private let rowIndent = "  "  // 2-space left indent
    
    // Greenbar row background — dark forest green, reads clearly on a clear-dark terminal.
    // Even-numbered visible rows (1, 3, 5...) get the band; odd rows stay transparent.
    private let greenBarBG = "\u{001B}[48;5;22m"
    private let resetCode  = "\u{001B}[0m"
    
    private var gridDivider: String { rowIndent + String(repeating: "─", count: 118) }
    private var gridTop:     String { "╭" + String(repeating: "─", count: 118) + "╮" }
    private var gridSep:     String { "├" + String(repeating: "─", count: 118) + "┤" }
    private var gridBottom:  String { "╰" + String(repeating: "─", count: 118) + "╯" }
    
    // Wraps a 118-char row string in │ borders to complete the grid box
    private func boxRow(_ row: String) -> String { "│" + row + "│" }
    
    private func lcol(_ text: String, _ width: Int) -> String {
        String(text.prefix(width)).padding(toLength: width, withPad: " ", startingAt: 0)
    }
    private func rcol(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }
    private func gainPercent(_ position: StockPosition) -> Double {
        position.totalCost != 0 ? (position.gainLoss / position.totalCost) * 100 : 0
    }
    
    private func buildGridRow(_ cols: [String]) -> String {
        cols.joined(separator: colGap)
    }
    
    private func gridHeaderRow() -> String {
        buildGridRow([
            rcol("#",          wNum),   lcol("",          wFlags),
            lcol("COMPANY NAME", wName), lcol("SYM",      wSym),
            rcol("SHARES",    wShares), rcol("COST",     wCost),
            rcol("MARKET",   wMarket),  rcol("VALUE",    wValue),
            rcol("GAIN/LOSS",   wGL),   rcol("GAIN %", wGLPct),
            lcol("TYPE",        wClass)
        ])
    }
    
    private func gridDataRow(_ s: StockPosition, rowNumber: Int, flags: String, highlighted: Bool) -> String {
        let sign = s.gainLoss >= 0 ? "+" : "-"
        
        let cols = [
            rcol("\(rowNumber)",                              wNum),
            lcol(flags,                                      wFlags),
            lcol(s.companyName,                              wName),
            lcol(s.symbol,                                   wSym),
            rcol(String(format: "%.2f", s.shares),          wShares),
            rcol(Format.comma(s.purchasePrice),              wCost),
            rcol(Format.comma(s.currentPrice),              wMarket),
            rcol(Format.comma(s.totalValue),                 wValue),
            rcol("\(sign)$\(Format.comma(abs(s.gainLoss)))",   wGL),
            rcol(String(format: "%@%.2f%%", sign, abs(gainPercent(s))), wGLPct),
            lcol(s.isPaperStock ? "MOCK" : "LIVE",            wClass)
        ]
        
        let plain = buildGridRow(cols)
        
        if highlighted {
            // Bright reverse-video for the selected row — overrides greenbar background.
            // Pad to 118 so the highlight fills fully to the right │ border.
            let padded = plain.padding(toLength: 118, withPad: " ", startingAt: 0)
            return "\u{001B}[7m\u{001B}[1m\(padded)\(resetCode)"
        }
        
        // Greenbar: odd visible rows (1, 3, 5…) get the dark-green background band
        let isGreenBand = (rowNumber % 2 != 0)
        let glColor = s.gainLoss >= 0 ? "\u{001B}[1;32m" : "\u{001B}[1;31m"
        
        if isGreenBand {
            // Pad to 118 so the green band fills fully to the right │ border
            let padded = plain.padding(toLength: 118, withPad: " ", startingAt: 0)
            return "\(greenBarBG)\(padded)\(resetCode)"
        } else {
            // On plain rows, color the gain/loss numbers green or red as normal
            let gainIdx = cols.indices.dropLast(2).last!  // index of the gain/loss column
            let glPctIdx = gainIdx + 1
            var coloredCols = cols
            coloredCols[gainIdx]  = "\(glColor)\(cols[gainIdx])\(resetCode)"
            coloredCols[glPctIdx] = "\(glColor)\(cols[glPctIdx])\(resetCode)"
            return buildGridRow(coloredCols)
        }
    }
    
    private func gridTotalsRow(_ positions: [StockPosition]) -> String {
        let totalValue = positions.reduce(0.0) { $0 + $1.totalValue }
        let totalCost  = positions.reduce(0.0) { $0 + $1.totalCost  }
        let totalGL    = totalValue - totalCost
        let totalGLPct = totalCost != 0 ? (totalGL / totalCost) * 100 : 0
        let sign       = totalGL >= 0 ? "+" : "-"
        let color      = totalGL >= 0 ? "\u{001B}[1;32m" : "\u{001B}[1;31m"
        
        let valStr   = rcol(Format.comma(totalValue), wValue)
        let glStr    = rcol("\(sign)$\(Format.comma(abs(totalGL)))", wGL)
        let glPctStr = rcol(String(format: "%@%.2f%%", sign, abs(totalGLPct)), wGLPct)
        
        return buildGridRow([
            rcol("", wNum), lcol("", wFlags), lcol("TOTALS", wName), lcol("", wSym),
            rcol("", wShares), rcol("", wCost), rcol("", wMarket),
            "\u{001B}[1m\(valStr)\(resetCode)",
            "\(color)\(glStr)\(resetCode)",
            "\(color)\(glPctStr)\(resetCode)",
            lcol("", wClass)
        ])
    }
    
    // MARK: - Workspace (home screen) — shows the full portfolio directly, matching the
    // workspace-first pattern used by vault/notes/contacts, rather than requiring a menu hop
    // before you can see your own data.
    
    func showWorkspace() {
        keyboard.enableRawMode()
        let maxVisibleRows = 9
        
        while true {
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()
            printPortfolioStatusBlock()
            
            let sorted = stocks.sorted(by: { $0.symbol < $1.symbol })
            
            print(gridTop)
            print(boxRow(gridHeaderRow()))
            print(gridSep)
            
            var visibleSlice: [StockPosition] = []
            
            if sorted.isEmpty {
                let emptyMsg = "   Portfolio is empty. Press 'A' to add your first position."
                let emptyPad = max(0, 118 - emptyMsg.count)
                print("│" + emptyMsg + String(repeating: " ", count: emptyPad) + "│")
            } else {
                if selectedIdx >= sorted.count { selectedIdx = max(0, sorted.count - 1) }
                var startIndex = 0
                if selectedIdx >= maxVisibleRows {
                    startIndex = min(selectedIdx - maxVisibleRows + 1, sorted.count - maxVisibleRows)
                }
                startIndex = max(0, startIndex)
                let endIndex = min(startIndex + maxVisibleRows, sorted.count)
                visibleSlice = Array(sorted[startIndex..<endIndex])
                
                for (rowNum, idx) in (startIndex..<endIndex).enumerated() {
                    let rowFlags = "  "
                    print(boxRow(gridDataRow(sorted[idx], rowNumber: rowNum + 1, flags: rowFlags, highlighted: idx == selectedIdx)))
                }
                
                print(gridSep)
                print(boxRow(gridTotalsRow(sorted)))
            }
            
            print(gridBottom)
            print("")
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
                    openSelectedStock(sorted[selectedIdx])
                    return
                }
            case .number(let num):
                if num >= 1 && num <= visibleSlice.count {
                    keyboard.disableRawMode()
                    openSelectedStock(visibleSlice[num - 1])
                    return
                }
            case .other(let ch):
                let lower = Character(ch.lowercased())
                if lower == "a" {
                    keyboard.disableRawMode()
                    navigate(to: .addNewStock)
                    return
                } else if lower == "/" {
                    keyboard.disableRawMode()
                    navigate(to: .globalSearch)
                    return
                } else if lower == "d" {
                    if !sorted.isEmpty {
                        deleteStockInline(sorted[selectedIdx])
                    }
                } else if lower == "u" {
                    keyboard.disableRawMode()
                    navigate(to: .utilitiesMenu)
                    return
                } else if lower == "r" {
                    keyboard.disableRawMode()
                    syncLiveQuotes(isSilent: false)
                    keyboard.enableRawMode()
                } else {
                    // Nav footer — direct app switching.
                    // [A] is claimed by Add Stock, [S] stays as Stocks (current app, no-op).
                    let navMap: [Character: String] = [
                        "t": "swiftCONTACTS", "c": "swiftCALENDAR",
                        "m": "swiftMAIL",     "n": "swiftNOTES",
                        "v": "swiftVAULT"
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
                Thread.sleep(forTimeInterval: 0.05)
                if case .escape = keyboard.readKey() {
                    keyboard.disableRawMode()
                    returnToLauncher()
                    return
                }
            }
        }
    }
    
    private func deleteStockInline(_ chosen: StockPosition) {
        guard let masterIndex = stocks.firstIndex(where: { $0.id == chosen.id }) else { return }
        keyboard.disableRawMode()
        print("\n Delete \(chosen.symbol) (\(chosen.companyName)) permanently? (y/n): ", terminator: "")
        if let confirm = readLine(), confirm.lowercased() == "y" {
            stocks.remove(at: masterIndex)
            saveDatabase()
            lastStatusMessage = "Deleted \(chosen.symbol)."
            lastStatusWasError = false
            StocksDebugLogger.log("Position deleted: \(chosen.symbol)", category: "STOCKS")
            if selectedIdx > 0 { selectedIdx -= 1 }
        }
        keyboard.enableRawMode()
    }
    
    
    
    /// Fetches a live quote (and company name, if available) for a single symbol, blocking the
    /// calling thread until the network call completes or times out. Used for a one-off lookup
    /// (e.g. right after adding a new position) as opposed to syncLiveQuotes' concurrent batch.
    private func fetchQuoteBlocking(symbol: String, timeout: TimeInterval = 4.0) -> (price: Double, companyName: String?)? {
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)?interval=1m&range=1d") else {
            return nil
        }
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout
        
        let semaphore = DispatchSemaphore(value: 0)
        var result: (price: Double, companyName: String?)? = nil
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            
            guard let data = data, error == nil else {
                StocksDebugLogger.log("Quote lookup network error for \(symbol): \(error?.localizedDescription ?? "unknown")", category: "NET-ERR")
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let chart = json["chart"] as? [String: Any],
                  let resultList = chart["result"] as? [[String: Any]],
                  let firstResult = resultList.first,
                  let meta = firstResult["meta"] as? [String: Any] else {
                StocksDebugLogger.log("Quote lookup parse error for \(symbol): unexpected response shape", category: "PARSE-ERR")
                return
            }
            
            var livePrice = meta["regularMarketPrice"] as? Double
            if livePrice == nil { livePrice = meta["previousClose"] as? Double }
            
            guard let finalPrice = livePrice, finalPrice > 0.0 else {
                StocksDebugLogger.log("Quote lookup returned no usable price for \(symbol)", category: "PARSE-ERR")
                return
            }
            
            result = (finalPrice, meta["longName"] as? String)
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1.0)
        return result
    }
    
    func showAddNewStockScreen() {
        printStandardHeader()
        centerSubtitle("DATA ENTRY: NEW STOCK POSITION")
        print("  " + String(repeating: "─", count: 118))
        print("")
        
        print(" Enter Stock Symbol (e.g. AAPL): ", terminator: "")
        guard let symbol = readLine()?.uppercased(), !symbol.trimmingCharacters(in: .whitespaces).isEmpty else { goBack(); return }
        
        print(" Number of Shares: ", terminator: "")
        guard let sharesStr = readLine(), let shares = Double(sharesStr) else { goBack(); return }
        
        print(" Purchase Price ($): ", terminator: "")
        guard let priceStr = readLine(), let purchasePrice = Double(priceStr) else { goBack(); return }
        
        print(" Stock Classification [l] Live Stock / [m] Mock (Paper) Stock: ", terminator: "")
        guard let typeStr = readLine()?.lowercased() else { goBack(); return }
        let isPaper = (typeStr == "m")
        
        var newPosition = StockPosition(symbol: symbol, shares: shares, purchasePrice: purchasePrice, isPaperStock: isPaper)
        newPosition.companyName = "\(symbol) Inc." // fallback if the live lookup below fails
        
        print(" Looking up live quote for \(symbol)...", terminator: "")
        fflush(stdout)
        
        if let quote = fetchQuoteBlocking(symbol: symbol) {
            newPosition.currentPrice = quote.price
            if let name = quote.companyName { newPosition.companyName = name }
            print(" \u{001B}[1;32mdone.\u{001B}[0m")
        } else {
            // Previously this defaulted to purchasePrice * 1.05 — a fabricated +5% "gain" with
            // no basis in reality. Falling back to the purchase price instead means a failed
            // lookup shows a neutral $0 gain/loss until the next successful sync, rather than
            // quietly inventing a number.
            newPosition.currentPrice = purchasePrice
            print(" \u{001B}[1;33mcouldn't reach the quote server — using purchase price until next sync.\u{001B}[0m")
        }
        
        stocks.append(newPosition)
        saveDatabase()
        
        print("\n\u{001B}[92mSuccess: Transaction block saved to ledger.\u{001B}[0m")
        print(" Press Enter to return to main menu...")
        _ = readLine()
        goBack()
    }
    
    func showGlobalSearchScreen() {
        printStandardHeader()
        centerSubtitle("GLOBAL ENGINE SEARCH TUNNEL")
        print("  " + String(repeating: "─", count: 118))
        print("")
        print(" Enter Target Ticker Symbol or Company Name: ", terminator: "")
        guard let query = readLine()?.uppercased(), !query.isEmpty else { goBack(); return }
        
        let results = stocks.filter { $0.symbol.contains(query) || $0.companyName.uppercased().contains(query) }
        goBack()
        navigate(to: .selectLedgerResult(results: results, title: "REGISTRY MATCHES FOR '\(query)'"))
    }
    
    func showSelectLedgerResultScreen(results: [StockPosition], title: String) {
        var localIdx = 0
        keyboard.enableRawMode()
        let maxVisibleRows = 9
        
        while true {
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()
            centerSubtitle(title)
            print(" (Press ESC to go back to previous menu)\n")
            
            print(gridTop)
            print(boxRow(gridHeaderRow()))
            print(gridSep)
            
            // Map entries back cleanly to maintain local reference parity
            let currentResults = results.compactMap { res in stocks.first(where: { $0.id == res.id }) }
            var visibleSlice: [StockPosition] = []
            
            if currentResults.isEmpty {
                let emptyMsg = "   No matching positions."
                let emptyPad = max(0, 118 - emptyMsg.count)
                print("│" + emptyMsg + String(repeating: " ", count: emptyPad) + "│")
            } else {
                if localIdx >= currentResults.count { localIdx = max(0, currentResults.count - 1) }
                var startIndex = 0
                if localIdx >= maxVisibleRows {
                    startIndex = min(localIdx - maxVisibleRows + 1, currentResults.count - maxVisibleRows)
                }
                startIndex = max(0, startIndex)
                let endIndex = min(startIndex + maxVisibleRows, currentResults.count)
                visibleSlice = Array(currentResults[startIndex..<endIndex])
                
                for (rowNum, idx) in (startIndex..<endIndex).enumerated() {
                    print(boxRow(gridDataRow(currentResults[idx], rowNumber: rowNum + 1, flags: "  ", highlighted: idx == localIdx)))
                }
                
                print(gridSep)
                print(boxRow(gridTotalsRow(currentResults)))
            }
            
            print(gridBottom)
            printStandardFooter(keys: "ENTER/1-9: View | ESC: Back")
            printNavFooter()
            
            switch keyboard.readKey() {
            case .up:
                if !currentResults.isEmpty { localIdx = (localIdx == 0) ? currentResults.count - 1 : localIdx - 1 }
            case .down:
                if !currentResults.isEmpty { localIdx = (localIdx == currentResults.count - 1) ? 0 : localIdx + 1 }
            case .number(let num):
                if num >= 1 && num <= visibleSlice.count {
                    keyboard.disableRawMode()
                    openSelectedStock(visibleSlice[num - 1])
                    return
                }
            case .escape:
                keyboard.disableRawMode()
                goBack()
                return
            case .other(let ch):
                if ch == "r" || ch == "R" {
                    keyboard.disableRawMode()
                    syncLiveQuotes(isSilent: false)
                    keyboard.enableRawMode()
                }
            case .enter:
                if !currentResults.isEmpty {
                    keyboard.disableRawMode()
                    openSelectedStock(currentResults[localIdx])
                    return
                }
            }
        }
    }
    
    private func openSelectedStock(_ selected: StockPosition) {
        if let targetIdx = stocks.firstIndex(where: { $0.id == selected.id }) {
            navigate(to: .viewStock(index: targetIdx))
        }
    }
    
    func showViewStockScreen(index: Int) {
        keyboard.enableRawMode()
        
        while true {
            let s = stocks[index]
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()
            
            // Info box
            let inner = 118
            func infoRow(_ label: String, _ value: String, colored: String? = nil) {
                let plainContent = "  \(label.padding(toLength: 16, withPad: " ", startingAt: 0))\(value)"
                let displayContent = "  \(label.padding(toLength: 16, withPad: " ", startingAt: 0))\(colored ?? value)"
                let pad = max(0, inner - plainContent.count)
                print("│\(displayContent)\(String(repeating: " ", count: pad))│")
            }
            
            let sign = s.gainLoss >= 0 ? "+" : ""
            let glColor = s.gainLoss >= 0 ? "\u{001B}[1;32m" : "\u{001B}[1;31m"
            // Build the full plain Gain/Loss string (dollar + pct) so the padding calculation
            // uses the correct visible length — previously glValue (dollar only) was passed as
            // the plain string while the colored version included both, making the line too long.
            let glFullValue   = "\(sign)$\(Format.comma(s.gainLoss))  \(sign)\(String(format: "%.2f", abs(s.gainLossPct)))%"
            let glFullColored = "\(glColor)\(sign)$\(Format.comma(s.gainLoss))\u{001B}[0m  \(glColor)\(sign)\(String(format: "%.2f", abs(s.gainLossPct)))%\u{001B}[0m"
            
            let dcSign = s.dayChange >= 0 ? "+" : ""
            let dcColor = s.dayChange >= 0 ? "\u{001B}[1;32m" : "\u{001B}[1;31m"
            let dcValue = "\(dcSign)$\(Format.comma(s.dayChange))  (\(dcSign)\(String(format: "%.2f", s.dayChangePct))%)"
            let dcColored = "\(dcColor)\(dcValue)\u{001B}[0m"
            
            // 52-week bar — deduplicated into one code path; both branches share the same
            // field rows, only the ├─ separator and bar row differ.
            let barWidth = 30
            let w52Label = "52-Week Range"
            let has52Data = s.week52High > s.week52Low
            var w52Plain = ""
            var w52Colored = ""
            if has52Data {
                let pct = max(0.0, min(1.0, (s.currentPrice - s.week52Low) / (s.week52High - s.week52Low)))
                let pos = Int(pct * Double(barWidth))
                let bar = String(repeating: "─", count: pos) + "●" + String(repeating: "─", count: barWidth - pos)
                let barColor = pct >= 0.5 ? "\u{001B}[1;32m" : "\u{001B}[1;31m"
                let pctLabel = "(\(Int(pct * 100))%)"
                w52Plain   = "$\(Format.comma(s.week52Low))  \(bar)  $\(Format.comma(s.week52High))  \(pctLabel)"
                w52Colored = "$\(Format.comma(s.week52Low))  \(barColor)\(bar)\u{001B}[0m  $\(Format.comma(s.week52High))  \(pctLabel)"
            } else {
                w52Plain   = "Press [R] to sync"
                w52Colored = "\u{001B}[2m\(w52Plain)\u{001B}[0m"  // dim hint
            }
            
            
            print("╭" + String(repeating: "─", count: inner) + "╮")
            infoRow("Company",        s.companyName)
            infoRow("Symbol",         s.symbol)
            infoRow("Shares",         String(format: "%.2f", s.shares))
            infoRow("Purchase Price", "$\(Format.comma(s.purchasePrice))")
            infoRow("Cost Basis",     "$\(Format.comma(s.totalCost))")
            infoRow("Current Price",  "$\(Format.comma(s.currentPrice))")
            infoRow("Total Value",    "$\(Format.comma(s.totalValue))")
            infoRow("Gain/Loss",      glFullValue,  colored: glFullColored)
            infoRow("Day's Change",   dcValue,       colored: dcColored)
            infoRow("Type",           s.isPaperStock ? "MOCK" : "LIVE")
            infoRow(w52Label,         w52Plain,      colored: w52Colored)
            print("╰" + String(repeating: "─", count: inner) + "╯")
            print("")
            // Single footer box — letter keys, ESC handles back
            printStandardFooter(keys: "[E] Edit Position  |  [D] Delete Position  |  ESC: Back")
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
                    navigate(to: .editStock(index: index))
                    return
                } else if lower == "d" {
                    keyboard.disableRawMode()
                    print("\n Delete \(s.companyName) (\(s.symbol)) permanently? (y/n): ", terminator: "")
                    if let confirm = readLine(), confirm.lowercased() == "y" {
                        stocks.remove(at: index)
                        saveDatabase()
                        lastStatusMessage = "Deleted \(s.symbol)."
                        lastStatusWasError = false
                        StocksDebugLogger.log("Position deleted: \(s.symbol)", category: "STOCKS")
                        print("\n Position deleted. Press Enter.")
                        _ = readLine()
                        goBack()
                        return
                    }
                    keyboard.enableRawMode()
                }
            default: break
            }
        }
    }
    
    func showEditStockScreen(index: Int) {
        var s = stocks[index]
        
        printStandardHeader()
        print(" Edit Position — press Enter to keep the current value.\n")
        
        print(" Company Name [\(s.companyName)]: ", terminator: "")
        if let val = readLine(), !val.isEmpty { s.companyName = val }
        
        print(" Ticker Symbol [\(s.symbol)]: ", terminator: "")
        if let val = readLine(), !val.isEmpty { s.symbol = val.uppercased() }
        
        print(" Shares Bound [\(String(format: "%.2f", s.shares))]: ", terminator: "")
        if let val = readLine(), let num = Double(val) { s.shares = num }
        
        print(" Cost Basis Price [\(Format.comma(s.purchasePrice))]: ", terminator: "")
        if let val = readLine(), let num = Double(val) { s.purchasePrice = num }
        
        print(" Current Market Price [\(Format.comma(s.currentPrice))]: ", terminator: "")
        if let val = readLine(), let num = Double(val) { s.currentPrice = num }
        
        print(" Classification [\(s.isPaperStock ? "m" : "l")] (l=Live / m=Mock): ", terminator: "")
        if let val = readLine(), !val.isEmpty { s.isPaperStock = (val.lowercased() == "m") }
        
        stocks[index] = s
        saveDatabase()
        
        print("\n Framework matrix profile updated! Press Enter.")
        _ = readLine()
        goBack()
    }
    
    func showUtilitiesMenu() {
        let options = [
            "Backup Database Archive",
            "Restore Database Archive",
            "Clear Active Database Ledgers",
            "Back to Portfolio"
        ]
        var localIdx = 0
        keyboard.enableRawMode()
        
        while true {
            print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
            printStandardHeader()
            centerSubtitle("DATABASE UTILITIES")
            print("  " + String(repeating: "─", count: 118))
            print("")
            
            for (i, option) in options.enumerated() {
                let prefix = (i == localIdx) ? " -> " : "    "
                print("\(prefix)[\(i + 1)]. \(option)")
            }
            print("")
            print("  " + String(repeating: "─", count: 118))
            print("")
            printStandardFooter(keys: "↑/↓: Navigate | ENTER: Select | ESC: Back")
            printNavFooter()
            
            switch keyboard.readKey() {
            case .up: localIdx = (localIdx == 0) ? options.count - 1 : localIdx - 1
            case .down: localIdx = (localIdx == options.count - 1) ? 0 : localIdx + 1
            case .number(let num):
                if num >= 1 && num <= options.count {
                    localIdx = num - 1
                    keyboard.disableRawMode()
                    executeUtilitiesSelection(index: localIdx)
                    return
                }
            case .escape:
                keyboard.disableRawMode()
                goBack()
                return
            case .enter:
                keyboard.disableRawMode()
                executeUtilitiesSelection(index: localIdx)
                return
            default: break
            }
        }
    }
    
    private func executeUtilitiesSelection(index: Int) {
        switch index {
        case 0: backupDatabase()
        case 1: restoreDatabase()
        case 2: clearDatabase()
        case 3: goBack()
        default: break
        }
    }
    
    
    // MARK: - Core Persistence Ledgers
    
    func saveDatabase() {
        if let data = try? JSONEncoder().encode(stocks) {
            try? data.write(to: fileURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }
    
    func loadDatabase() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([StockPosition].self, from: data) {
            self.stocks = decoded
        }
    }
    
    func backupDatabase() {
        printStandardHeader()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("\n Error: No database file found to backup yet. Add a position first.")
            print(" Press Enter to continue...")
            _ = readLine()
            return
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmm"
        let timestamp = formatter.string(from: Date())
        let backupURL = resolveAppDataDirectory().appendingPathComponent("stocks_backup_\(timestamp).json")
        
        do {
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
            print("\n Backup created successfully: \(backupURL.lastPathComponent)")
            lastStatusMessage = "Backup created: \(backupURL.lastPathComponent)"
            lastStatusWasError = false
            StocksDebugLogger.log("Backup created: \(backupURL.lastPathComponent)", category: "STOCKS")
        } catch {
            print("\n Failed to create backup: \(error.localizedDescription)")
            lastStatusMessage = "Backup failed: \(error.localizedDescription)"
            lastStatusWasError = true
            StocksDebugLogger.log("Backup failed: \(error.localizedDescription)", category: "STOCKS-ERR")
        }
        print(" Press Enter to continue...")
        _ = readLine()
    }
    
    func restoreDatabase() {
        let appDir = resolveAppDataDirectory()
        do {
            let files = try FileManager.default.contentsOfDirectory(at: appDir, includingPropertiesForKeys: nil)
            let backupFiles = files.filter { $0.lastPathComponent.hasPrefix("stocks_backup_") && $0.lastPathComponent.hasSuffix(".json") }
                .sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
            
            if backupFiles.isEmpty {
                printStandardHeader()
                print("\n No backup snapshots found in \(appDir.path).")
                print(" Press Enter to continue...")
                _ = readLine()
                return
            }
            
            var selectedBackupIdx = 0
            keyboard.enableRawMode()
            
            while true {
                print("\u{001B}[2J\u{001B}[1;1H", terminator: "")
                printStandardHeader()
                centerSubtitle("AVAILABLE STOCKS BACKUPS")
                print(" Choose a recovery point via Arrow Keys or Number Keys\n")
                
                for (index, file) in backupFiles.enumerated() {
                    let prefix = (index == selectedBackupIdx) ? " -> " : "    "
                    print("\(prefix)[\(index + 1)]. \(file.lastPathComponent)")
                }
                print("  " + String(repeating: "─", count: 118))
                printStandardFooter(keys: "↑/↓: Navigate | ENTER: Select | ESC: Back")
            printNavFooter()
                
                switch keyboard.readKey() {
                case .up: selectedBackupIdx = (selectedBackupIdx == 0) ? backupFiles.count - 1 : selectedBackupIdx - 1
                case .down: selectedBackupIdx = (selectedBackupIdx == backupFiles.count - 1) ? 0 : selectedBackupIdx + 1
                case .number(let num):
                    if num >= 1 && num <= backupFiles.count {
                        selectedBackupIdx = num - 1
                        triggerDatabaseRestore(file: backupFiles[selectedBackupIdx])
                        return
                    }
                case .escape:
                    keyboard.disableRawMode()
                    return
                case .enter:
                    triggerDatabaseRestore(file: backupFiles[selectedBackupIdx])
                    return
                default: break
                }
            }
        } catch {
            keyboard.disableRawMode()
            print("\n Error listing backups: \(error.localizedDescription)")
            print(" Press Enter to continue...")
            _ = readLine()
        }
    }
    
    private func triggerDatabaseRestore(file: URL) {
        keyboard.disableRawMode()
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try FileManager.default.copyItem(at: file, to: fileURL)
            loadDatabase()
            StocksDebugLogger.log("Restored from \(file.lastPathComponent)", category: "STOCKS")
            print("\n \u{001B}[1;32mRestored from \(file.lastPathComponent) successfully!\u{001B}[0m")
            lastStatusMessage = "Restored from \(file.lastPathComponent)."
            lastStatusWasError = false
        } catch {
            print("\n \u{001B}[1;31mRestore failed: \(error.localizedDescription)\u{001B}[0m")
            lastStatusMessage = "Restore failed: \(error.localizedDescription)"
            lastStatusWasError = true
        }
        print(" Press Enter to continue...")
        _ = readLine()
    }
    
    func clearDatabase() {
        printStandardHeader()
        if stocks.isEmpty {
            print("\n Portfolio is already empty.")
            print(" Press Enter to continue...")
            _ = readLine()
            return
        }
        
        print("\n WARNING: This will delete ALL \(stocks.count) position(s) permanently!")
        print(" Type 'CONFIRM' to clear everything: ", terminator: "")
        if let validation = readLine(), validation == "CONFIRM" {
            stocks.removeAll()
            saveDatabase()
            StocksDebugLogger.log("All positions wiped by user request", category: "STOCKS")
            print("\n Portfolio successfully wiped clean!")
            lastStatusMessage = "Portfolio wiped."
            lastStatusWasError = false
        } else {
            print("\n Wipe canceled. No data was deleted.")
        }
        print(" Press Enter to continue...")
        _ = readLine()
    }
}

// MARK: - Central Process Launcher Interface Relay

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

func printNavFooter(currentApp: String = "swiftSTOCKS") {
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

let application = StocksManager()
application.run()