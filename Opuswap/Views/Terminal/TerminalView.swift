import SwiftUI
import AppKit
import Darwin

// MARK: - ANSIパーサー

enum ANSIAction {
    case print(Character)
    case cursorUp(Int)
    case cursorDown(Int)
    case cursorForward(Int)
    case cursorBackward(Int)
    case cursorPosition(row: Int, col: Int)
    case cursorHome
    case eraseDisplay(Int)        // 0: カーソル以降, 1: カーソル以前, 2: 全体
    case eraseLine(Int)           // 0: カーソル以降, 1: カーソル以前, 2: 全行
    case setScrollRegion(top: Int, bottom: Int)
    case scrollUp(Int)
    case scrollDown(Int)
    case setGraphicRendition([Int])
    case saveCursor
    case restoreCursor
    case bell
    case carriageReturn
    case lineFeed
    case backspace
    case tab
    case setCharset(Int, Character)
    case switchToAltBuffer
    case switchToMainBuffer
    case cursorShow
    case cursorHide
    case reset
}

class ANSIParser {
    enum State {
        case ground
        case escape
        case csiEntry
        case csiParam
        case oscString
        case charset
    }

    private var state: State = .ground
    private var params: [Int] = []
    private var currentParam: String = ""
    private var oscString: String = ""
    private var charsetIndex: Int = 0

    // 不完全なUTF-8バイト列をバッファリング
    private var incompleteBytes: [UInt8] = []

    func parse(_ data: Data) -> [ANSIAction] {
        var actions: [ANSIAction] = []

        // 前回の不完全なバイト列と今回のデータを結合
        let bytes = incompleteBytes + [UInt8](data)
        incompleteBytes = []

        var i = 0

        while i < bytes.count {
            // UTF-8マルチバイト文字の処理
            if state == .ground && bytes[i] >= 0x80 {
                // UTF-8の先頭バイトから必要な長さを計算
                let expectedLength = utf8ExpectedLength(bytes[i])
                let available = bytes.count - i

                if available < expectedLength {
                    // 不完全なUTF-8シーケンス - バッファに保存して次回処理
                    incompleteBytes = Array(bytes[i...])
                    break
                }

                let (char, consumed) = decodeUTF8(bytes, startIndex: i)
                if let c = char {
                    actions.append(.print(c))
                }
                i += consumed
                continue
            }

            let byte = bytes[i]
            i += 1

            switch state {
            case .ground:
                actions.append(contentsOf: processGround(byte))

            case .escape:
                actions.append(contentsOf: processEscape(byte))

            case .csiEntry, .csiParam:
                actions.append(contentsOf: processCSI(byte))

            case .oscString:
                processOSC(byte)

            case .charset:
                let c = Character(UnicodeScalar(byte))
                actions.append(.setCharset(charsetIndex, c))
                state = .ground
            }
        }

        return actions
    }

    private func utf8ExpectedLength(_ firstByte: UInt8) -> Int {
        if firstByte & 0b10000000 == 0 { return 1 }
        if firstByte & 0b11100000 == 0b11000000 { return 2 }
        if firstByte & 0b11110000 == 0b11100000 { return 3 }
        if firstByte & 0b11111000 == 0b11110000 { return 4 }
        return 1 // 不正なバイト
    }

    private func decodeUTF8(_ bytes: [UInt8], startIndex: Int) -> (Character?, Int) {
        let first = bytes[startIndex]
        var codePoint: UInt32 = 0
        var length: Int = 1

        if first & 0b10000000 == 0 {
            codePoint = UInt32(first)
            length = 1
        } else if first & 0b11100000 == 0b11000000 {
            length = 2
        } else if first & 0b11110000 == 0b11100000 {
            length = 3
        } else if first & 0b11111000 == 0b11110000 {
            length = 4
        }

        guard startIndex + length <= bytes.count else {
            return (nil, 1)
        }

        if length == 1 {
            return (Character(UnicodeScalar(first)), 1)
        }

        codePoint = UInt32(first & (0xFF >> (length + 1)))
        for j in 1..<length {
            let b = bytes[startIndex + j]
            guard b & 0b11000000 == 0b10000000 else {
                return (nil, 1)
            }
            codePoint = (codePoint << 6) | UInt32(b & 0b00111111)
        }

        if let scalar = UnicodeScalar(codePoint) {
            return (Character(scalar), length)
        }
        return (nil, length)
    }

    private func processGround(_ byte: UInt8) -> [ANSIAction] {
        switch byte {
        case 0x1B: // ESC
            state = .escape
            return []
        case 0x07: // BEL
            return [.bell]
        case 0x08: // BS
            return [.backspace]
        case 0x09: // TAB
            return [.tab]
        case 0x0A, 0x0B, 0x0C: // LF, VT, FF
            return [.lineFeed]
        case 0x0D: // CR
            return [.carriageReturn]
        case 0x20...0x7E:
            return [.print(Character(UnicodeScalar(byte)))]
        default:
            return []
        }
    }

    private func processEscape(_ byte: UInt8) -> [ANSIAction] {
        switch byte {
        case 0x5B: // [
            state = .csiEntry
            params = []
            currentParam = ""
            return []
        case 0x5D: // ]
            state = .oscString
            oscString = ""
            return []
        case 0x28: // (
            state = .charset
            charsetIndex = 0
            return []
        case 0x29: // )
            state = .charset
            charsetIndex = 1
            return []
        case 0x37: // 7 - DECSC
            state = .ground
            return [.saveCursor]
        case 0x38: // 8 - DECRC
            state = .ground
            return [.restoreCursor]
        case 0x4D: // M - RI (Reverse Index)
            state = .ground
            return [.scrollDown(1)]
        case 0x63: // c - RIS (Reset)
            state = .ground
            return [.reset]
        default:
            state = .ground
            return []
        }
    }

    private func processCSI(_ byte: UInt8) -> [ANSIAction] {
        switch byte {
        case 0x30...0x39: // 0-9
            currentParam.append(Character(UnicodeScalar(byte)))
            state = .csiParam
            return []
        case 0x3B: // ;
            params.append(Int(currentParam) ?? 0)
            currentParam = ""
            return []
        case 0x3F: // ?
            // Private mode prefix
            return []
        default:
            // Finish param
            if !currentParam.isEmpty {
                params.append(Int(currentParam) ?? 0)
                currentParam = ""
            }
            state = .ground
            return executeCSI(byte)
        }
    }

    private func executeCSI(_ byte: UInt8) -> [ANSIAction] {
        switch byte {
        case 0x41: // A - CUU
            return [.cursorUp(params.first ?? 1)]
        case 0x42: // B - CUD
            return [.cursorDown(params.first ?? 1)]
        case 0x43: // C - CUF
            return [.cursorForward(params.first ?? 1)]
        case 0x44: // D - CUB
            return [.cursorBackward(params.first ?? 1)]
        case 0x48, 0x66: // H, f - CUP
            let row = (params.count > 0 ? params[0] : 1)
            let col = (params.count > 1 ? params[1] : 1)
            return [.cursorPosition(row: row, col: col)]
        case 0x4A: // J - ED
            return [.eraseDisplay(params.first ?? 0)]
        case 0x4B: // K - EL
            return [.eraseLine(params.first ?? 0)]
        case 0x53: // S - SU
            return [.scrollUp(params.first ?? 1)]
        case 0x54: // T - SD
            return [.scrollDown(params.first ?? 1)]
        case 0x6D: // m - SGR
            return [.setGraphicRendition(params.isEmpty ? [0] : params)]
        case 0x72: // r - DECSTBM
            let top = params.count > 0 ? params[0] : 1
            let bottom = params.count > 1 ? params[1] : 0
            return [.setScrollRegion(top: top, bottom: bottom)]
        case 0x73: // s - SCP
            return [.saveCursor]
        case 0x75: // u - RCP
            return [.restoreCursor]
        case 0x68: // h - SM/DECSET (if ? prefix)
            if params.contains(1049) {
                return [.switchToAltBuffer]
            } else if params.contains(25) {
                return [.cursorShow]
            }
            return []
        case 0x6C: // l - RM/DECRST (if ? prefix)
            if params.contains(1049) {
                return [.switchToMainBuffer]
            } else if params.contains(25) {
                return [.cursorHide]
            }
            return []
        default:
            return []
        }
    }

    private func processOSC(_ byte: UInt8) {
        if byte == 0x07 || byte == 0x1B { // BEL or ESC
            state = .ground
            // OSCは今回は無視（タイトル設定など）
        } else {
            oscString.append(Character(UnicodeScalar(byte)))
        }
    }
}

// MARK: - ターミナルセル

struct TerminalCell {
    var character: Character = " "
    var foreground: NSColor = .white
    var background: NSColor = .clear
    var bold: Bool = false
    var underline: Bool = false
    var inverse: Bool = false
    var width: Int = 1  // 1=半角, 2=全角
}

// MARK: - ターミナルバッファ

class TerminalBuffer {
    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var cells: [[TerminalCell]]
    private(set) var cursorRow: Int = 0
    private(set) var cursorCol: Int = 0
    private var savedCursorRow: Int = 0
    private var savedCursorCol: Int = 0
    private var scrollTop: Int = 0
    private var scrollBottom: Int

    // 現在のスタイル
    private var currentForeground: NSColor = .white
    private var currentBackground: NSColor = .clear
    private var currentBold: Bool = false

    // スクロールバック
    private var scrollback: [[TerminalCell]] = []
    private let maxScrollback = 10000

    // 代替バッファ
    private var mainBuffer: [[TerminalCell]]?
    private var mainCursorRow: Int = 0
    private var mainCursorCol: Int = 0
    private(set) var isAltBuffer: Bool = false

    init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        self.scrollBottom = rows - 1
        self.cells = Self.createEmptyCells(cols: cols, rows: rows)
    }

    private static func createEmptyCells(cols: Int, rows: Int) -> [[TerminalCell]] {
        Array(repeating: Array(repeating: TerminalCell(), count: cols), count: rows)
    }

    func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        self.scrollBottom = rows - 1

        // 既存のセルを維持しながらリサイズ
        var newCells = Self.createEmptyCells(cols: cols, rows: rows)
        for row in 0..<min(rows, cells.count) {
            for col in 0..<min(cols, cells[row].count) {
                newCells[row][col] = cells[row][col]
            }
        }
        cells = newCells

        // カーソル位置を調整
        cursorRow = min(cursorRow, rows - 1)
        cursorCol = min(cursorCol, cols - 1)
    }

    func processAction(_ action: ANSIAction) {
        switch action {
        case .print(let char):
            printChar(char)
        case .cursorUp(let n):
            cursorRow = max(scrollTop, cursorRow - n)
        case .cursorDown(let n):
            cursorRow = min(scrollBottom, cursorRow + n)
        case .cursorForward(let n):
            cursorCol = min(cols - 1, cursorCol + n)
        case .cursorBackward(let n):
            cursorCol = max(0, cursorCol - n)
        case .cursorPosition(let row, let col):
            cursorRow = max(0, min(rows - 1, row - 1))
            cursorCol = max(0, min(cols - 1, col - 1))
        case .cursorHome:
            cursorRow = 0
            cursorCol = 0
        case .eraseDisplay(let mode):
            eraseDisplay(mode)
        case .eraseLine(let mode):
            eraseLine(mode)
        case .setScrollRegion(let top, let bottom):
            scrollTop = max(0, top - 1)
            scrollBottom = bottom > 0 ? min(rows - 1, bottom - 1) : rows - 1
            cursorRow = scrollTop
            cursorCol = 0
        case .scrollUp(let n):
            scrollUp(n)
        case .scrollDown(let n):
            scrollDown(n)
        case .setGraphicRendition(let params):
            applyGraphicRendition(params)
        case .saveCursor:
            savedCursorRow = cursorRow
            savedCursorCol = cursorCol
        case .restoreCursor:
            cursorRow = savedCursorRow
            cursorCol = savedCursorCol
        case .carriageReturn:
            cursorCol = 0
        case .lineFeed:
            lineFeed()
        case .backspace:
            cursorCol = max(0, cursorCol - 1)
        case .tab:
            cursorCol = min(cols - 1, (cursorCol / 8 + 1) * 8)
        case .switchToAltBuffer:
            if !isAltBuffer {
                mainBuffer = cells
                mainCursorRow = cursorRow
                mainCursorCol = cursorCol
                cells = Self.createEmptyCells(cols: cols, rows: rows)
                cursorRow = 0
                cursorCol = 0
                isAltBuffer = true
            }
        case .switchToMainBuffer:
            if isAltBuffer, let main = mainBuffer {
                cells = main
                cursorRow = mainCursorRow
                cursorCol = mainCursorCol
                mainBuffer = nil
                isAltBuffer = false
            }
        case .reset:
            reset()
        default:
            break
        }
    }

    private func printChar(_ char: Character) {
        // 文字幅を計算（全角=2, 半角=1）
        let width = charWidth(char)

        // 右端を超える場合は改行
        if cursorCol + width > cols {
            cursorCol = 0
            lineFeed()
        }

        guard cursorRow >= 0 && cursorRow < rows else { return }

        // セルに書き込み
        cells[cursorRow][cursorCol] = TerminalCell(
            character: char,
            foreground: currentForeground,
            background: currentBackground,
            bold: currentBold,
            width: width
        )

        // 全角の場合、次のセルをプレースホルダーにする
        if width == 2 && cursorCol + 1 < cols {
            cells[cursorRow][cursorCol + 1] = TerminalCell(
                character: " ",
                foreground: currentForeground,
                background: currentBackground,
                bold: currentBold,
                width: 0  // プレースホルダー
            )
        }

        cursorCol += width
        if cursorCol >= cols {
            cursorCol = cols - 1
        }
    }

    private func charWidth(_ char: Character) -> Int {
        // 簡易的な全角判定
        guard let scalar = char.unicodeScalars.first else { return 1 }
        let value = scalar.value

        // CJK文字（ひらがな、カタカナ、漢字、全角記号）
        if (0x3000...0x9FFF).contains(value) ||
           (0xFF00...0xFFEF).contains(value) ||
           (0x20000...0x2FFFF).contains(value) {
            return 2
        }
        return 1
    }

    private func lineFeed() {
        if cursorRow >= scrollBottom {
            scrollUp(1)
        } else {
            cursorRow += 1
        }
    }

    private func scrollUp(_ n: Int) {
        for _ in 0..<n {
            // スクロール領域の先頭行をスクロールバックに追加
            if scrollTop == 0 && !isAltBuffer {
                scrollback.append(cells[scrollTop])
                if scrollback.count > maxScrollback {
                    scrollback.removeFirst()
                }
            }

            // 行を上に移動
            for row in scrollTop..<scrollBottom {
                cells[row] = cells[row + 1]
            }
            // 最下行をクリア
            cells[scrollBottom] = Array(repeating: TerminalCell(), count: cols)
        }
    }

    private func scrollDown(_ n: Int) {
        for _ in 0..<n {
            for row in stride(from: scrollBottom, to: scrollTop, by: -1) {
                cells[row] = cells[row - 1]
            }
            cells[scrollTop] = Array(repeating: TerminalCell(), count: cols)
        }
    }

    private func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0: // カーソルから末尾
            eraseLine(0)
            for row in (cursorRow + 1)..<rows {
                cells[row] = Array(repeating: TerminalCell(), count: cols)
            }
        case 1: // 先頭からカーソル
            eraseLine(1)
            for row in 0..<cursorRow {
                cells[row] = Array(repeating: TerminalCell(), count: cols)
            }
        case 2, 3: // 全体
            cells = Self.createEmptyCells(cols: cols, rows: rows)
        default:
            break
        }
    }

    private func eraseLine(_ mode: Int) {
        guard cursorRow >= 0 && cursorRow < rows else { return }
        switch mode {
        case 0: // カーソルから行末
            for col in cursorCol..<cols {
                cells[cursorRow][col] = TerminalCell()
            }
        case 1: // 行頭からカーソル
            for col in 0...cursorCol {
                cells[cursorRow][col] = TerminalCell()
            }
        case 2: // 全行
            cells[cursorRow] = Array(repeating: TerminalCell(), count: cols)
        default:
            break
        }
    }

    private func applyGraphicRendition(_ params: [Int]) {
        var i = 0
        while i < params.count {
            let p = params[i]
            switch p {
            case 0:
                currentForeground = .white
                currentBackground = .clear
                currentBold = false
            case 1:
                currentBold = true
            case 22:
                currentBold = false
            case 30...37:
                currentForeground = ansiColor(p - 30)
            case 38:
                // 256色 or True Color
                if i + 2 < params.count && params[i + 1] == 5 {
                    currentForeground = color256(params[i + 2])
                    i += 2
                } else if i + 4 < params.count && params[i + 1] == 2 {
                    currentForeground = NSColor(
                        red: CGFloat(params[i + 2]) / 255,
                        green: CGFloat(params[i + 3]) / 255,
                        blue: CGFloat(params[i + 4]) / 255,
                        alpha: 1
                    )
                    i += 4
                }
            case 39:
                currentForeground = .white
            case 40...47:
                currentBackground = ansiColor(p - 40)
            case 48:
                if i + 2 < params.count && params[i + 1] == 5 {
                    currentBackground = color256(params[i + 2])
                    i += 2
                } else if i + 4 < params.count && params[i + 1] == 2 {
                    currentBackground = NSColor(
                        red: CGFloat(params[i + 2]) / 255,
                        green: CGFloat(params[i + 3]) / 255,
                        blue: CGFloat(params[i + 4]) / 255,
                        alpha: 1
                    )
                    i += 4
                }
            case 49:
                currentBackground = .clear
            case 90...97:
                currentForeground = ansiBrightColor(p - 90)
            case 100...107:
                currentBackground = ansiBrightColor(p - 100)
            default:
                break
            }
            i += 1
        }
    }

    private func ansiColor(_ index: Int) -> NSColor {
        switch index {
        case 0: return NSColor(red: 0, green: 0, blue: 0, alpha: 1)         // black
        case 1: return NSColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1)   // red
        case 2: return NSColor(red: 0.2, green: 0.8, blue: 0.2, alpha: 1)   // green
        case 3: return NSColor(red: 0.8, green: 0.8, blue: 0.2, alpha: 1)   // yellow
        case 4: return NSColor(red: 0.3, green: 0.5, blue: 0.9, alpha: 1)   // blue
        case 5: return NSColor(red: 0.8, green: 0.3, blue: 0.8, alpha: 1)   // magenta
        case 6: return NSColor(red: 0.3, green: 0.8, blue: 0.8, alpha: 1)   // cyan
        case 7: return NSColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1)   // white
        default: return .white
        }
    }

    private func ansiBrightColor(_ index: Int) -> NSColor {
        switch index {
        case 0: return NSColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1)   // bright black
        case 1: return NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1)   // bright red
        case 2: return NSColor(red: 0.4, green: 1.0, blue: 0.4, alpha: 1)   // bright green
        case 3: return NSColor(red: 1.0, green: 1.0, blue: 0.4, alpha: 1)   // bright yellow
        case 4: return NSColor(red: 0.5, green: 0.7, blue: 1.0, alpha: 1)   // bright blue
        case 5: return NSColor(red: 1.0, green: 0.5, blue: 1.0, alpha: 1)   // bright magenta
        case 6: return NSColor(red: 0.5, green: 1.0, blue: 1.0, alpha: 1)   // bright cyan
        case 7: return NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1)   // bright white
        default: return .white
        }
    }

    private func color256(_ index: Int) -> NSColor {
        if index < 16 {
            return index < 8 ? ansiColor(index) : ansiBrightColor(index - 8)
        } else if index < 232 {
            // 6x6x6カラーキューブ
            let i = index - 16
            let r = CGFloat((i / 36) % 6) / 5.0
            let g = CGFloat((i / 6) % 6) / 5.0
            let b = CGFloat(i % 6) / 5.0
            return NSColor(red: r, green: g, blue: b, alpha: 1)
        } else {
            // グレースケール
            let gray = CGFloat(index - 232) / 23.0
            return NSColor(white: gray, alpha: 1)
        }
    }

    private func reset() {
        cells = Self.createEmptyCells(cols: cols, rows: rows)
        cursorRow = 0
        cursorCol = 0
        scrollTop = 0
        scrollBottom = rows - 1
        currentForeground = .white
        currentBackground = .clear
        currentBold = false
        isAltBuffer = false
        mainBuffer = nil
    }

    func getScrollback() -> [[TerminalCell]] {
        return scrollback
    }
}

// MARK: - ターミナルレンダラー

class TerminalRenderer {
    private let buffer: TerminalBuffer
    private let fontSize: CGFloat = 14
    private lazy var font: NSFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    private lazy var boldFont: NSFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)

    init(buffer: TerminalBuffer) {
        self.buffer = buffer
    }

    func render() -> NSAttributedString {
        let result = NSMutableAttributedString()

        // スクロールバック
        for row in buffer.getScrollback() {
            result.append(renderRow(row))
            result.append(NSAttributedString(string: "\n"))
        }

        // メインバッファ
        for (rowIndex, row) in buffer.cells.enumerated() {
            result.append(renderRow(row))
            if rowIndex < buffer.rows - 1 {
                result.append(NSAttributedString(string: "\n"))
            }
        }

        return result
    }

    private func renderRow(_ row: [TerminalCell]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var col = 0

        while col < row.count {
            let cell = row[col]

            // プレースホルダーはスキップ
            if cell.width == 0 {
                col += 1
                continue
            }

            let attrs: [NSAttributedString.Key: Any] = [
                .font: cell.bold ? boldFont : font,
                .foregroundColor: cell.foreground,
                .backgroundColor: cell.background == .clear ? NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1) : cell.background
            ]

            result.append(NSAttributedString(string: String(cell.character), attributes: attrs))
            col += max(1, cell.width)
        }

        // 行末の空白を削除しない（表示が崩れる可能性あり）
        return result
    }

    func cursorPosition() -> (row: Int, col: Int) {
        return (buffer.cursorRow, buffer.cursorCol)
    }

    /// プレーンテキストとしてレンダリング（履歴保存用）
    func renderAsPlainText() -> String {
        var lines: [String] = []

        // スクロールバック
        for row in buffer.getScrollback() {
            lines.append(rowToString(row))
        }

        // メインバッファ
        for row in buffer.cells {
            lines.append(rowToString(row))
        }

        // 末尾の空行を削除
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }

        return lines.joined(separator: "\n")
    }

    private func rowToString(_ row: [TerminalCell]) -> String {
        var result = ""
        var col = 0
        while col < row.count {
            let cell = row[col]
            if cell.width == 0 {
                col += 1
                continue
            }
            result.append(cell.character)
            col += max(1, cell.width)
        }
        // 末尾の空白を削除
        return result.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }
}

// MARK: - PTYコントローラー

// Cのfork関数をインポート（Swiftで明示的にunavailableになっているため）
@_silgen_name("fork")
private func c_fork() -> pid_t

class PTYController {
    private var masterFD: Int32 = -1
    private var pid: pid_t = -1
    private var readSource: DispatchSourceRead?

    var onOutput: ((Data) -> Void)?
    var onProcessExit: ((Int32) -> Void)?

    var isRunning: Bool {
        pid > 0
    }

    func start(command: String, environment: [String: String], workingDirectory: String, size: (cols: Int, rows: Int)) -> Bool {
        var ws = winsize()
        ws.ws_col = UInt16(size.cols)
        ws.ws_row = UInt16(size.rows)
        ws.ws_xpixel = 0
        ws.ws_ypixel = 0

        var master: Int32 = 0
        var slave: Int32 = 0

        // openpty
        guard openpty(&master, &slave, nil, nil, &ws) == 0 else {
            return false
        }

        let childPid = c_fork()

        if childPid == -1 {
            close(master)
            close(slave)
            return false
        }

        if childPid == 0 {
            // 子プロセス
            close(master)

            setsid()

            // 制御端末を設定
            var dummy: Int32 = 0
            _ = ioctl(slave, TIOCSCTTY, &dummy)

            dup2(slave, STDIN_FILENO)
            dup2(slave, STDOUT_FILENO)
            dup2(slave, STDERR_FILENO)

            if slave > STDERR_FILENO {
                close(slave)
            }

            // 作業ディレクトリ変更
            chdir(workingDirectory)

            // 環境変数設定
            for (key, value) in environment {
                setenv(key, value, 1)
            }

            // シェル経由でコマンドを実行
            // -l: ログインシェル（.zprofile読み込み）
            // -i: インタラクティブシェル（.zshrc読み込み）
            let shell = environment["SHELL"] ?? "/bin/zsh"
            let args = [shell, "-l", "-i", "-c", command]
            let cArgs = args.map { strdup($0) } + [nil]
            execv(shell, cArgs)
            _exit(1)
        }

        // 親プロセス
        close(slave)
        masterFD = master
        pid = childPid

        // ノンブロッキングに設定
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        // 読み取り監視
        readSource = DispatchSource.makeReadSource(fileDescriptor: master, queue: .main)
        readSource?.setEventHandler { [weak self] in
            self?.readData()
        }
        readSource?.setCancelHandler { [weak self] in
            if let fd = self?.masterFD, fd >= 0 {
                close(fd)
            }
        }
        readSource?.resume()

        // 子プロセス監視
        DispatchQueue.global().async { [weak self] in
            var status: Int32 = 0
            waitpid(childPid, &status, 0)
            // WEXITSTATUS: (status >> 8) & 0xFF
            let exitCode = (status >> 8) & 0xFF
            DispatchQueue.main.async {
                self?.onProcessExit?(exitCode)
            }
        }

        return true
    }

    private func readData() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(masterFD, &buffer, buffer.count)

        if bytesRead > 0 {
            let data = Data(bytes: buffer, count: bytesRead)
            onOutput?(data)
        }
    }

    func write(_ data: Data) {
        guard masterFD >= 0 else { return }
        data.withUnsafeBytes { ptr in
            _ = Darwin.write(masterFD, ptr.baseAddress, ptr.count)
        }
    }

    func write(_ string: String) {
        if let data = string.data(using: .utf8) {
            write(data)
        }
    }

    func resize(cols: Int, rows: Int) {
        guard masterFD >= 0 else { return }
        var ws = winsize()
        ws.ws_col = UInt16(cols)
        ws.ws_row = UInt16(rows)
        _ = ioctl(masterFD, TIOCSWINSZ, &ws)
    }

    func stop() {
        readSource?.cancel()
        readSource = nil

        if pid > 0 {
            kill(pid, SIGTERM)
            pid = -1
        }

        masterFD = -1
    }

    deinit {
        stop()
    }
}

// MARK: - シンタックスハイライト

class SyntaxHighlighter {
    // コマンド（緑）
    private let commands: Set<String> = [
        "git", "cd", "ls", "cat", "grep", "find", "mkdir", "rm", "cp", "mv",
        "echo", "pwd", "clear", "vim", "nano", "code", "npm", "yarn", "python",
        "pip", "brew", "docker", "kubectl", "curl", "wget", "ssh", "scp",
        "node", "ruby", "go", "cargo", "make", "cmake", "gcc", "clang",
        "sudo", "man", "which", "whereis", "touch", "chmod", "chown", "tar",
        "zip", "unzip", "head", "tail", "less", "more", "sort", "uniq", "wc"
    ]

    // gitサブコマンド（青）
    private let gitSubcommands: Set<String> = [
        "status", "add", "commit", "push", "pull", "checkout", "branch", "merge",
        "rebase", "log", "diff", "stash", "clone", "fetch", "reset", "remote",
        "init", "config", "tag", "show", "blame", "cherry-pick", "revert"
    ]

    // 色定義
    private let commandColor = NSColor(red: 0.4, green: 0.9, blue: 0.4, alpha: 1)      // 緑
    private let subcommandColor = NSColor(red: 0.5, green: 0.7, blue: 1.0, alpha: 1)   // 青
    private let flagColor = NSColor(red: 1.0, green: 0.8, blue: 0.3, alpha: 1)         // 黄
    private let pathColor = NSColor(red: 0.3, green: 0.9, blue: 0.9, alpha: 1)         // シアン
    private let stringColor = NSColor(red: 1.0, green: 0.6, blue: 0.3, alpha: 1)       // オレンジ
    private let defaultColor = NSColor.white

    func highlight(_ text: String, fontSize: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let tokens = tokenize(text)

        for (index, token) in tokens.enumerated() {
            let color = colorFor(token: token, index: index, tokens: tokens)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: color
            ]
            result.append(NSAttributedString(string: token, attributes: attrs))
        }

        return result
    }

    private func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote: Character? = nil

        for char in text {
            if let quote = inQuote {
                current.append(char)
                if char == quote {
                    tokens.append(current)
                    current = ""
                    inQuote = nil
                }
            } else if char == "\"" || char == "'" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                current.append(char)
                inQuote = char
            } else if char == " " {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                tokens.append(" ")
            } else {
                current.append(char)
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    private func colorFor(token: String, index: Int, tokens: [String]) -> NSColor {
        // 空白
        if token == " " { return defaultColor }

        // 文字列（クォート内）
        if token.hasPrefix("\"") || token.hasPrefix("'") {
            return stringColor
        }

        // フラグ（-で始まる）
        if token.hasPrefix("-") {
            return flagColor
        }

        // パス（/, ~, .で始まる）
        if token.hasPrefix("/") || token.hasPrefix("~") || token.hasPrefix("./") || token.hasPrefix("../") {
            return pathColor
        }

        // 最初のトークン（空白以外）を見つける
        let nonSpaceTokens = tokens.filter { $0 != " " }
        let nonSpaceIndex = nonSpaceTokens.firstIndex(of: token) ?? 0

        // 最初のトークン = コマンド
        if nonSpaceIndex == 0 {
            if commands.contains(token.lowercased()) {
                return commandColor
            }
            return defaultColor
        }

        // 2番目のトークン
        if nonSpaceIndex == 1 {
            let firstCommand = nonSpaceTokens.first ?? ""
            // gitの後はサブコマンド
            if firstCommand == "git" && gitSubcommands.contains(token.lowercased()) {
                return subcommandColor
            }
            // cdの後はパス扱い
            if firstCommand == "cd" {
                return pathColor
            }
        }

        // ファイルっぽい（拡張子あり）
        if token.contains(".") && !token.hasPrefix(".") {
            return pathColor
        }

        return defaultColor
    }

    func getColorRanges(_ text: String) -> [(NSRange, NSColor)] {
        var result: [(NSRange, NSColor)] = []
        let tokens = tokenize(text)
        var location = 0

        for (index, token) in tokens.enumerated() {
            let range = NSRange(location: location, length: token.count)
            let color = colorFor(token: token, index: index, tokens: tokens)
            result.append((range, color))
            location += token.count
        }

        return result
    }
}

// MARK: - 補完候補

struct CompletionItem: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let type: CompletionType
    let icon: String

    enum CompletionType {
        case file, directory, command, history, snippet
    }

    var displayText: String {
        switch type {
        case .directory: return text + "/"
        default: return text
        }
    }
}

// MARK: - 補完プロバイダー

class CompletionProvider {
    private var commandHistory: [String] = []
    private let historyPath: String

    // よく使うコマンド一覧
    private let availableCommands = [
        "git", "cd", "ls", "cat", "grep", "find", "mkdir", "rm", "cp", "mv",
        "echo", "pwd", "clear", "vim", "nano", "code", "npm", "yarn", "pnpm", "bun",
        "node", "python", "python3", "pip", "pip3", "brew", "docker", "kubectl",
        "curl", "wget", "ssh", "scp", "tar", "zip", "unzip", "chmod", "chown",
        "touch", "head", "tail", "less", "more", "man", "which", "env", "export",
        "cargo", "rustc", "go", "swift", "xcodebuild", "claude"
    ]

    private let gitSubcommands = [
        "status", "add", "commit", "push", "pull", "checkout", "branch", "merge",
        "rebase", "log", "diff", "stash", "clone", "fetch", "reset", "remote"
    ]

    // BSD系コマンドのオプション（静的定義）
    private let staticOptions: [String: [String]] = [
        "ls": ["-l", "-a", "-la", "-lh", "-R", "-t", "-S", "-r", "-1"],
        "cat": ["-n", "-b", "-s", "-v", "-e", "-t"],
        "grep": ["-i", "-r", "-n", "-l", "-v", "-c", "-E", "-o", "-w", "-A", "-B", "-C"],
        "find": ["-name", "-type", "-size", "-mtime", "-exec", "-delete", "-print", "-maxdepth"],
        "cp": ["-r", "-R", "-f", "-i", "-n", "-v", "-p", "-a"],
        "mv": ["-f", "-i", "-n", "-v"],
        "rm": ["-r", "-R", "-f", "-i", "-v", "-d"],
        "mkdir": ["-p", "-v", "-m"],
        "chmod": ["-R", "-v", "-f"],
        "chown": ["-R", "-v", "-f", "-h"],
        "head": ["-n", "-c", "-q"],
        "tail": ["-n", "-f", "-F", "-c", "-q"],
        "less": ["-N", "-S", "-R", "-F", "-X"],
        "tar": ["-x", "-c", "-v", "-f", "-z", "-j", "-t", "-C"],
        "zip": ["-r", "-q", "-v", "-e", "-9"],
        "unzip": ["-l", "-o", "-q", "-d"],
        "curl": ["-o", "-O", "-L", "-v", "-s", "-S", "-X", "-H", "-d", "-F", "-u", "-k", "-I"],
        "wget": ["-O", "-q", "-c", "-r", "-P", "-N"],
        "ssh": ["-p", "-i", "-v", "-L", "-R", "-N", "-f", "-q"],
        "scp": ["-r", "-P", "-i", "-v", "-q", "-C"],
        "ps": ["-a", "-u", "-x", "-e", "-f", "-l"],
        "kill": ["-9", "-15", "-TERM", "-KILL", "-HUP"],
        "df": ["-h", "-H", "-T", "-i"],
        "du": ["-h", "-s", "-a", "-c", "-d"],
        "touch": ["-a", "-m", "-c", "-t"],
        "which": ["-a", "-s"],
        "env": ["-i", "-u"],
        "cd": ["-", "~"],
    ]

    // 動的に取得したオプションのキャッシュ
    private var optionCache: [String: [String]] = [:]
    private var optionFetchInProgress: Set<String> = []

    // よく使うコマンドの組み合わせ（スペースなし入力用）
    private let commandCombinations = [
        "git status", "git add", "git commit", "git push", "git pull",
        "git checkout", "git branch", "git merge", "git rebase", "git log",
        "git diff", "git stash", "git clone", "git fetch", "git reset",
        "cd ~", "ls -la", "ls -l", "npm install", "npm run", "npm start",
        "yarn install", "yarn add", "docker ps", "docker build", "docker run"
    ]

    // プロジェクトタイプ
    private enum ProjectType {
        case node, rust, go, python, swift, git, unknown
    }

    // ターミナル出力から抽出したコマンド
    private var recentOutputCommands: [String] = []

    // 直前に実行したコマンド（エラーチェック用）
    private var lastExecutedCommand: String?

    // エラーパターン
    private let errorPatterns = [
        "command not found",
        "No such file or directory",
        "Permission denied",
        "not recognized as",
        "unknown command",
        "invalid option",
        "unrecognized option"
    ]

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Opuswap")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        historyPath = dir.appendingPathComponent("terminal_history").path
        loadHistory()
    }

    func addToHistory(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 一時的に保存（エラーチェック後に確定）
        lastExecutedCommand = trimmed
    }

    // エラーでなければ履歴に確定
    func confirmLastCommand() {
        guard let cmd = lastExecutedCommand else { return }
        if commandHistory.last != cmd {
            commandHistory.append(cmd)
            saveHistory()
        }
        lastExecutedCommand = nil
    }

    // エラー出力があれば履歴に追加しない
    func checkOutputForError(_ output: String) {
        guard lastExecutedCommand != nil else { return }

        let lowered = output.lowercased()
        let hasError = errorPatterns.contains { lowered.contains($0.lowercased()) }

        if hasError {
            // エラーなので履歴に追加しない
            lastExecutedCommand = nil
        } else if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 正常出力があれば確定
            confirmLastCommand()
        }
    }

    func getCompletions(for input: String, cwd: String) -> [CompletionItem] {
        // 先頭の空白だけ削除（末尾は保持）
        let trimmedStart = input.drop(while: { $0.isWhitespace })

        // 空入力時はスニペットを表示
        guard !trimmedStart.isEmpty else {
            return getEmptyInputSuggestions(cwd: cwd)
        }

        var results: [CompletionItem] = []

        // 入力を分割（末尾の空文字も保持）
        let parts = String(trimmedStart).split(separator: " ", omittingEmptySubsequences: false)
        let isFirstWord = parts.count <= 1
        let lastPart = parts.last.map(String.init) ?? ""

        if isFirstWord {
            let cmd = String(trimmedStart)
            // コマンド補完
            results += getCommandCompletions(prefix: cmd)
            // コマンド組み合わせ補完（gitp → git push など）
            results += getCombinationCompletions(prefix: cmd)
            // 履歴補完
            results += getHistoryCompletions(prefix: cmd)
            // コマンド名が完全一致したらオプションも表示
            if availableCommands.contains(cmd) || staticOptions[cmd] != nil {
                results += getOptionCompletions(command: cmd, prefix: "")
            }
        } else {
            let baseCmd = String(parts.first ?? "")

            // gitサブコマンド
            if baseCmd == "git" && parts.count == 2 {
                results += getGitCompletions(prefix: lastPart)
            }

            // オプション補完（-で始まる or 空の場合）
            if lastPart.hasPrefix("-") || lastPart.isEmpty {
                results += getOptionCompletions(command: baseCmd, prefix: lastPart)
            }

            // cd の後はディレクトリのみ表示（空でも表示）
            if baseCmd == "cd" {
                results += getDirectoryCompletions(prefix: lastPart, cwd: cwd)
            } else if !lastPart.hasPrefix("-") {
                // ファイルパス補完（オプション以外）
                results += getFileCompletions(prefix: lastPart, cwd: cwd)
            }
        }

        // 重複除去 & 名前順ソート
        var seen = Set<String>()
        return results
            .filter { seen.insert($0.text).inserted }
            .sorted { $0.text.lowercased() < $1.text.lowercased() }
    }

    private func getDirectoryCompletions(prefix: String, cwd: String) -> [CompletionItem] {
        let basePath: String
        let searchPrefix: String

        if prefix.contains("/") {
            var path = prefix
            if path.hasPrefix("~") {
                path = path.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
            } else if !path.hasPrefix("/") {
                path = (cwd as NSString).appendingPathComponent(path)
            }

            // 最後が / で終わる場合はそのディレクトリの中身を表示
            if prefix.hasSuffix("/") {
                basePath = path
                searchPrefix = ""
            } else {
                let url = URL(fileURLWithPath: path)
                basePath = url.deletingLastPathComponent().path
                searchPrefix = url.lastPathComponent
            }
        } else {
            basePath = cwd
            searchPrefix = prefix
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: basePath) else {
            return []
        }

        return contents
            .filter { name -> Bool in
                let fullPath = (basePath as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)
                let matchesPrefix = searchPrefix.isEmpty || name.lowercased().hasPrefix(searchPrefix.lowercased())
                return exists && isDir.boolValue && matchesPrefix && !name.hasPrefix(".")
            }
            .sorted()
            .map { CompletionItem(text: $0, type: .directory, icon: "folder.fill") }
    }

    private func getCommandCompletions(prefix: String) -> [CompletionItem] {
        availableCommands
            .filter { $0.hasPrefix(prefix) && $0 != prefix }
            .prefix(15)
            .map { CompletionItem(text: $0, type: .command, icon: "terminal") }
    }

    private func getGitCompletions(prefix: String) -> [CompletionItem] {
        gitSubcommands
            .filter { $0.hasPrefix(prefix) && $0 != prefix }
            .map { CompletionItem(text: $0, type: .command, icon: "arrow.triangle.branch") }
    }

    private func getOptionCompletions(command: String, prefix: String) -> [CompletionItem] {
        // 静的定義があればそれを使用
        if let staticOpts = staticOptions[command] {
            return staticOpts
                .filter { prefix.isEmpty || $0.hasPrefix(prefix) }
                .filter { $0 != prefix }
                .map { CompletionItem(text: $0, type: .command, icon: "minus") }
        }

        // キャッシュにあればそれを使用
        if let cached = optionCache[command] {
            return cached
                .filter { prefix.isEmpty || $0.hasPrefix(prefix) }
                .filter { $0 != prefix }
                .map { CompletionItem(text: $0, type: .command, icon: "minus") }
        }

        // まだ取得中でなければバックグラウンドで取得開始
        if !optionFetchInProgress.contains(command) {
            fetchOptionsAsync(for: command)
        }

        return []
    }

    private func fetchOptionsAsync(for command: String) {
        optionFetchInProgress.insert(command)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let options = self?.parseHelpOutput(for: command) ?? []

            DispatchQueue.main.async {
                self?.optionCache[command] = options
                self?.optionFetchInProgress.remove(command)
            }
        }
    }

    private func parseHelpOutput(for command: String) -> [String] {
        // --help で出力を取得（タイムアウト付き）
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // timeout コマンドで2秒制限、入力なしで実行
        process.arguments = ["-c", "timeout 2 \(command) --help 2>&1 </dev/null || timeout 2 \(command) -h 2>&1 </dev/null"]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return []
        }

        // 2秒でタイムアウト
        let deadline = DispatchTime.now() + .seconds(2)
        let group = DispatchGroup()
        group.enter()

        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }

        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        // オプションを抽出（-x, --option 形式）
        var options: [String] = []
        let pattern = #"(?:^|\s)(-{1,2}[a-zA-Z][\w-]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let matches = regex.matches(in: output, range: NSRange(output.startIndex..., in: output))
        for match in matches {
            if let range = Range(match.range(at: 1), in: output) {
                let option = String(output[range])
                if !options.contains(option) {
                    options.append(option)
                }
            }
        }

        // 最大20件に制限
        return Array(options.prefix(20))
    }

    private func getCombinationCompletions(prefix: String) -> [CompletionItem] {
        let normalizedPrefix = prefix.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard normalizedPrefix.count >= 2 else { return [] }

        var results: [CompletionItem] = []

        // 1. ハードコード + 履歴からマッチング
        var allCombinations = commandCombinations
        for cmd in commandHistory {
            if cmd.contains(" ") && !commandCombinations.contains(cmd) {
                allCombinations.append(cmd)
            }
        }

        results += allCombinations
            .filter { cmd in
                let normalized = cmd.lowercased()
                    .replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: "-", with: "")
                return normalized.hasPrefix(normalizedPrefix) && cmd != prefix
            }
            .map { CompletionItem(text: $0, type: .command, icon: "terminal") }

        // 2. 動的にオプション展開（lsla → ls -la, greprn → grep -rn）
        // 入力にマッチするコマンドだけを対象にする
        for baseCmd in availableCommands where normalizedPrefix.hasPrefix(baseCmd) && normalizedPrefix.count > baseCmd.count {
            let optionPart = String(normalizedPrefix.dropFirst(baseCmd.count))
            // アルファベットのみならオプションとして展開
            if optionPart.allSatisfy({ $0.isLetter }) {
                let expanded = "\(baseCmd) -\(optionPart)"
                if !results.contains(where: { $0.text == expanded }) {
                    results.append(CompletionItem(text: expanded, type: .command, icon: "terminal"))
                }
            }
        }

        return results
    }

    private func getHistoryCompletions(prefix: String) -> [CompletionItem] {
        commandHistory.reversed()
            .filter { $0.hasPrefix(prefix) && $0 != prefix }
            .prefix(5)
            .map { CompletionItem(text: $0, type: .history, icon: "clock") }
    }

    func getHistoryItems() -> [CompletionItem] {
        // 古い順（上が古い、下が新しい）、空を除外
        commandHistory
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(15)
            .map { CompletionItem(text: $0, type: .history, icon: "clock") }
    }

    private func getFileCompletions(prefix: String, cwd: String) -> [CompletionItem] {
        let basePath: String
        let searchPrefix: String

        if prefix.contains("/") {
            var path = prefix
            if path.hasPrefix("~") {
                path = path.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
            } else if !path.hasPrefix("/") {
                path = (cwd as NSString).appendingPathComponent(path)
            }
            let url = URL(fileURLWithPath: path)
            basePath = url.deletingLastPathComponent().path
            searchPrefix = url.lastPathComponent
        } else {
            basePath = cwd
            searchPrefix = prefix
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: basePath) else {
            return []
        }

        return contents
            .filter { $0.hasPrefix(searchPrefix) && $0 != searchPrefix && !$0.hasPrefix(".") }
            .sorted()
            .map { name -> CompletionItem in
                let fullPath = (basePath as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)
                return CompletionItem(
                    text: name,
                    type: isDir.boolValue ? .directory : .file,
                    icon: isDir.boolValue ? "folder.fill" : "doc"
                )
            }
    }

    private func loadHistory() {
        if let data = FileManager.default.contents(atPath: historyPath),
           let history = try? JSONDecoder().decode([String].self, from: data) {
            commandHistory = history
        }
    }

    private func saveHistory() {
        let recent = Array(commandHistory.suffix(500))
        if let data = try? JSONEncoder().encode(recent) {
            FileManager.default.createFile(atPath: historyPath, contents: data)
        }
    }

    // MARK: - プロジェクトタイプ検出

    private func detectProjectType(in directory: String) -> ProjectType {
        let fm = FileManager.default
        if fm.fileExists(atPath: "\(directory)/package.json") { return .node }
        if fm.fileExists(atPath: "\(directory)/Cargo.toml") { return .rust }
        if fm.fileExists(atPath: "\(directory)/go.mod") { return .go }
        if fm.fileExists(atPath: "\(directory)/requirements.txt") ||
           fm.fileExists(atPath: "\(directory)/pyproject.toml") { return .python }
        if fm.fileExists(atPath: "\(directory)/Package.swift") { return .swift }
        if fm.fileExists(atPath: "\(directory)/.git") { return .git }
        return .unknown
    }

    private func snippetsFor(_ type: ProjectType) -> [String] {
        switch type {
        case .node:
            return ["npm install", "npm run dev", "npm test", "npm start"]
        case .rust:
            return ["cargo build", "cargo run", "cargo test"]
        case .go:
            return ["go build", "go run .", "go test ./..."]
        case .python:
            return ["pip install -r requirements.txt", "python main.py", "pytest"]
        case .swift:
            return ["swift build", "swift run", "swift test"]
        case .git:
            return ["git status", "git pull", "git log --oneline"]
        case .unknown:
            return ["ls -la", "pwd"]
        }
    }

    // MARK: - ターミナル出力からコマンド抽出

    func extractCommandsFromOutput(_ text: String) {
        var extracted: [String] = []

        // バッククォート内のコマンド: `git push origin main`
        let backtickRegex = try? NSRegularExpression(pattern: "`([^`]+)`", options: [])
        let range = NSRange(text.startIndex..., in: text)
        backtickRegex?.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            if let matchRange = match?.range(at: 1),
               let swiftRange = Range(matchRange, in: text) {
                let cmd = String(text[swiftRange])
                // コマンドっぽいもののみ（先頭が英字）
                if let first = cmd.first, first.isLetter, cmd.count < 100 {
                    extracted.append(cmd)
                }
            }
        }

        // コマンドプロンプト形式: $ git status や > npm install
        let promptRegex = try? NSRegularExpression(pattern: "^[\\$\\>]\\s+(.+)$", options: .anchorsMatchLines)
        promptRegex?.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            if let matchRange = match?.range(at: 1),
               let swiftRange = Range(matchRange, in: text) {
                let cmd = String(text[swiftRange]).trimmingCharacters(in: .whitespaces)
                if !cmd.isEmpty && cmd.count < 100 {
                    extracted.append(cmd)
                }
            }
        }

        // 重複除去して最新10件を保持
        let unique = Array(NSOrderedSet(array: extracted)) as? [String] ?? extracted
        recentOutputCommands = Array(unique.suffix(10))
    }

    // MARK: - 空入力時のサジェスト

    private func getEmptyInputSuggestions(cwd: String) -> [CompletionItem] {
        var results: [CompletionItem] = []

        // 1. ターミナル出力から抽出したコマンド（最優先）
        results += recentOutputCommands.reversed().prefix(3).map {
            CompletionItem(text: $0, type: .snippet, icon: "text.quote")
        }

        // 2. 履歴から最近5件
        results += commandHistory.reversed().prefix(5).map {
            CompletionItem(text: $0, type: .history, icon: "clock")
        }

        // 3. プロジェクトタイプ別スニペット
        let projectType = detectProjectType(in: cwd)
        results += snippetsFor(projectType).map {
            CompletionItem(text: $0, type: .snippet, icon: "star")
        }

        // 重複除去
        var seen = Set<String>()
        return results.filter { seen.insert($0.text).inserted }.prefix(20).map { $0 }
    }
}

// MARK: - 補完ポップアップ

class CompletionPopupView: NSView {
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var items: [CompletionItem] = []
    var onSelect: ((CompletionItem) -> Void)?

    var selectedIndex: Int = 0 {
        didSet {
            if selectedIndex >= 0 && selectedIndex < items.count {
                tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
                tableView.scrollRowToVisible(selectedIndex)
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.15, green: 0.15, blue: 0.18, alpha: 0.95).cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.gray.withAlphaComponent(0.3).cgColor

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false

        tableView = NSTableView()
        tableView.backgroundColor = .clear
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.delegate = self
        tableView.dataSource = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion"))
        column.width = 280
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    func updateItems(_ newItems: [CompletionItem], selectLast: Bool = false) {
        items = newItems
        selectedIndex = selectLast ? items.count - 1 : 0

        tableView.reloadData()

        // サイズ調整（最大300px）
        let height = min(CGFloat(items.count) * 26 + 8, 300)
        frame.size.height = height

        if !items.isEmpty {
            // 即座にスクロール位置を設定
            if selectLast {
                let maxScroll = max(0, tableView.frame.height - scrollView.contentView.bounds.height)
                scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: maxScroll))
            } else {
                scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 0))
            }
            tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        }
    }

    func selectNext() {
        if selectedIndex < items.count - 1 {
            selectedIndex += 1
        }
    }

    func selectPrevious() {
        if selectedIndex > 0 {
            selectedIndex -= 1
        }
    }

    func selectLast() {
        if !items.isEmpty {
            selectedIndex = items.count - 1
        }
    }

    func confirmSelection() -> CompletionItem? {
        guard selectedIndex >= 0 && selectedIndex < items.count else { return nil }
        return items[selectedIndex]
    }
}

extension CompletionPopupView: NSTableViewDelegate, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0 && row < items.count else { return nil }
        let item = items[row]

        let cell = NSTableCellView()
        cell.wantsLayer = true

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: item.icon, accessibilityDescription: nil)
        icon.contentTintColor = item.type == .directory ? .systemBlue : .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: item.displayText)
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail

        let typeLabel = NSTextField(labelWithString: item.type == .directory ? "dir" : item.type == .history ? "history" : "")
        typeLabel.font = NSFont.systemFont(ofSize: 10)
        typeLabel.textColor = .tertiaryLabelColor
        typeLabel.setContentHuggingPriority(.required, for: .horizontal)

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(typeLabel)

        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let newIndex = tableView.selectedRow
        if newIndex >= 0 && newIndex < items.count {
            selectedIndex = newIndex
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        true
    }
}

// MARK: - タブ付きターミナルコンテナ

struct TerminalContainerView: View {
    let paneId: UUID
    let cwd: String

    @State private var tabs: [TerminalTab] = []
    @State private var selectedTabId: UUID?
    @State private var terminalRefs: [UUID: TerminalNSView] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(.green)
                Text("Terminal")
                    .font(.headline)
                Spacer()
                Button { addTab() } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            if tabs.count > 1 {
                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        HStack(spacing: 4) {
                            Text(tab.title)
                                .font(.caption)
                            if tabs.count > 1 {
                                Button {
                                    closeTab(tab)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(selectedTabId == tab.id ? Color.accentColor.opacity(0.2) : Color.clear)
                        .onTapGesture { selectedTabId = tab.id }
                    }
                    Spacer()
                }
                .background(Color(nsColor: .controlBackgroundColor))
            }

            Divider()

            ZStack {
                ForEach(tabs) { tab in
                    TerminalViewRepresentable(tabId: tab.id, cwd: cwd, paneId: paneId, onTerminalCreated: { terminal in
                        terminalRefs[tab.id] = terminal
                    })
                    .opacity(selectedTabId == tab.id ? 1 : 0)
                }
            }
        }
        .onAppear {
            if tabs.isEmpty {
                let initialTab = TerminalTab()
                tabs.append(initialTab)
                selectedTabId = initialTab.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .executeTerminalCommand)) { notification in
            handleExecuteCommand(notification)
        }
    }

    private func handleExecuteCommand(_ notification: Notification) {
        guard let info = notification.userInfo,
              let targetPaneId = info["paneId"] as? UUID,
              targetPaneId == paneId,
              let command = info["command"] as? String else { return }

        // 選択中のタブのターミナルでコマンドを実行
        if let tabId = selectedTabId, let terminal = terminalRefs[tabId] {
            terminal.executeCommand(command)
        }
    }

    private func addTab() {
        let newTab = TerminalTab()
        tabs.append(newTab)
        selectedTabId = newTab.id
    }

    private func closeTab(_ tab: TerminalTab) {
        guard tabs.count > 1 else { return }
        terminalRefs.removeValue(forKey: tab.id)
        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs.remove(at: index)
            if selectedTabId == tab.id {
                selectedTabId = tabs[max(0, index - 1)].id
            }
        }
    }
}

struct TerminalTab: Identifiable {
    let id = UUID()
    var title: String = "zsh"
}

// MARK: - NSViewRepresentable

struct TerminalViewRepresentable: NSViewRepresentable {
    let tabId: UUID
    let cwd: String
    let paneId: UUID
    let onTerminalCreated: (TerminalNSView) -> Void

    func makeNSView(context: Context) -> TerminalNSView {
        let terminal = TerminalNSView(initialDirectory: cwd, paneId: paneId)
        onTerminalCreated(terminal)
        return terminal
    }

    func updateNSView(_ nsView: TerminalNSView, context: Context) {}
}

// MARK: - 自作ターミナルビュー

class TerminalNSView: NSView {
    private var scrollView: NSScrollView!
    private var textView: TerminalTextView!
    private var shell: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?

    // PTYモード用（自前実装）
    private var ptyController: PTYController?
    private var ansiParser = ANSIParser()
    private var terminalBuffer: TerminalBuffer?
    private var terminalRenderer: TerminalRenderer?
    private(set) var isPTYMode: Bool = false
    private var currentLine: String = ""
    private(set) var promptLocation: Int = 0

    // 補完関連
    private var completionProvider = CompletionProvider()
    private var completionPopup: CompletionPopupView?
    private(set) var currentDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    var isCompletionVisible: Bool { completionPopup?.superview != nil }

    // シンタックスハイライト
    private let syntaxHighlighter = SyntaxHighlighter()
    private var highlightWorkItem: DispatchWorkItem?

    // セッション再開用
    private var paneId: UUID?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
        startShell()
    }

    convenience init(initialDirectory: String) {
        self.init(frame: .zero, initialDirectory: initialDirectory)
    }

    convenience init(initialDirectory: String, paneId: UUID) {
        self.init(frame: .zero, initialDirectory: initialDirectory)
        self.paneId = paneId
        setupNotificationObserver()
    }

    init(frame: NSRect, initialDirectory: String) {
        super.init(frame: frame)
        currentDirectory = initialDirectory
        setupUI()
        startShell()
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    private func setupNotificationObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExecuteCommand(_:)),
            name: .executeTerminalCommand,
            object: nil
        )
    }

    @objc private func handleExecuteCommand(_ notification: Notification) {
        guard let info = notification.userInfo,
              let targetPaneId = info["paneId"] as? UUID,
              targetPaneId == paneId,
              let command = info["command"] as? String else { return }
        executeCommand(command)
    }

    private func setupUI() {
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)

        textView = TerminalTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)
        textView.insertionPointColor = .green
        textView.textColor = .white
        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.terminalDelegate = self

        scrollView.documentView = textView
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func startShell() {
        let process = Process()
        let input = Pipe()
        let output = Pipe()

        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-i", "-l"]
        // currentDirectoryが有効ならそれを使用、なければホームディレクトリ
        let workingDir = URL(fileURLWithPath: currentDirectory)
        process.currentDirectoryURL = FileManager.default.fileExists(atPath: currentDirectory)
            ? workingDir
            : FileManager.default.homeDirectoryForCurrentUser

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = "ja_JP.UTF-8"
        env["LC_ALL"] = "ja_JP.UTF-8"
        env["CLICOLOR"] = "1"
        env["CLICOLOR_FORCE"] = "1"
        process.environment = env

        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.appendOutput(str)
            }
        }

        do {
            try process.run()
            self.shell = process
            self.inputPipe = input
            self.outputPipe = output
        } catch {
            appendOutput("シェル起動失敗: \(error.localizedDescription)\n")
        }
    }

    func sendToShell(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        if isPTYMode, let pty = ptyController {
            // PTYに送信
            pty.write(text)
        } else {
            inputPipe?.fileHandleForWriting.write(data)
        }
    }

    func executeCommand(_ command: String) {
        textView.scrollToEndOfDocument(nil)

        // PTYモード中はそのまま送信
        if isPTYMode {
            sendToShell(command + "\n")
            return
        }

        // TTYが必要なコマンドかチェック（コマンド全体に含まれるかで判定）
        let ttyCommands = ["claude", "vim", "nvim", "nano", "less", "more", "top", "htop"]
        let needsTTY = ttyCommands.contains { command.contains($0) }

        if needsTTY {
            startPTYProcess(command: command)
        } else {
            sendToShell(command + "\n")
        }
    }

    private func startPTYProcess(command: String) {
        // ターミナルサイズを計算
        let charWidth: CGFloat = 8  // 平均文字幅
        let charHeight: CGFloat = 16
        let cols = max(80, Int(bounds.width / charWidth))
        let rows = max(24, Int(bounds.height / charHeight))

        // バッファとレンダラーを初期化
        terminalBuffer = TerminalBuffer(cols: cols, rows: rows)
        if let buffer = terminalBuffer {
            terminalRenderer = TerminalRenderer(buffer: buffer)
        }

        // PTYコントローラーを作成
        let pty = PTYController()
        pty.onOutput = { [weak self] data in
            self?.handlePTYOutput(data)
        }
        pty.onProcessExit = { [weak self] exitCode in
            DispatchQueue.main.async {
                self?.stopPTY()
            }
        }

        // 環境変数を設定
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = "ja_JP.UTF-8"
        env["LC_ALL"] = "ja_JP.UTF-8"
        env["COLORTERM"] = "truecolor"

        // PTY開始
        let success = pty.start(
            command: command,
            environment: env,
            workingDirectory: currentDirectory,
            size: (cols: cols, rows: rows)
        )

        if success {
            ptyController = pty
            isPTYMode = true

            // 画面クリアして準備（空の状態をレンダリング）
            if let storage = textView.textStorage, let renderer = terminalRenderer {
                let emptyRender = renderer.render()
                storage.beginEditing()
                storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: emptyRender)
                storage.endEditing()
            }
            promptLocation = 0

            // IME状態もクリア
            textView.unmarkText()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        } else {
            appendOutput("PTY起動失敗\n")
        }
    }

    private func handlePTYOutput(_ data: Data) {
        guard let buffer = terminalBuffer, let renderer = terminalRenderer else { return }

        // ANSIシーケンスをパース
        let actions = ansiParser.parse(data)

        // バッファに適用
        for action in actions {
            buffer.processAction(action)
        }

        // レンダリングしてテキストビューに表示
        let rendered = renderer.render()

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let storage = self.textView.textStorage else { return }

            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: rendered)
            storage.endEditing()

            // カーソル位置を設定
            let cursorPos = renderer.cursorPosition()
            let scrollbackCount = buffer.getScrollback().count
            let lineIndex = scrollbackCount + cursorPos.row
            var charPos = 0

            // 行ごとの文字数を計算してカーソル位置を特定
            let lines = storage.string.components(separatedBy: "\n")
            for i in 0..<min(lineIndex, lines.count) {
                charPos += lines[i].count + 1  // +1 for newline
            }
            if lineIndex < lines.count {
                charPos += min(cursorPos.col, lines[lineIndex].count)
            }

            self.promptLocation = storage.length
            self.textView.setSelectedRange(NSRange(location: charPos, length: 0))
            // カーソル位置が見えるようにスクロール（末尾ではなくカーソル位置へ）
            self.textView.scrollRangeToVisible(NSRange(location: charPos, length: 0))
        }
    }

    private func stopPTY() {
        // PTYの最終出力を保存（スタイル付き）
        let finalOutput = terminalRenderer?.render() ?? NSAttributedString()

        // PTYを停止
        ptyController?.stop()
        ptyController = nil
        terminalBuffer = nil
        terminalRenderer = nil

        // IMEの状態をクリア
        textView.unmarkText()

        // PTYモードを終了
        isPTYMode = false

        // 履歴を保持したまま通常モードに戻る
        if let storage = textView.textStorage {
            storage.beginEditing()
            let mutableOutput = NSMutableAttributedString(attributedString: finalOutput)
            mutableOutput.append(NSAttributedString(string: "\n"))
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: mutableOutput)
            storage.endEditing()
        }
        promptLocation = textView.string.count

        // 改行を送信してプロンプトを表示させる
        if let data = "\n".data(using: .utf8) {
            inputPipe?.fileHandleForWriting.write(data)
        }
    }

    func appendOutput(_ text: String) {
        // 選択範囲を保持
        let savedSelection = textView.selectedRange()
        let hadSelection = savedSelection.length > 0

        if let storage = textView.textStorage {
            storage.beginEditing()

            // 現在のテキストが改行で終わっていなければ改行を追加
            if storage.length > 0 {
                let lastChar = storage.string.last
                if lastChar != "\n" {
                    let newline = NSAttributedString(string: "\n", attributes: defaultAttrs())
                    storage.append(newline)
                }
            }

            let attributed = parseANSI(text)
            storage.append(attributed)
            storage.endEditing()
        }

        // 選択中でなければスクロール、選択中なら選択を復元
        if hadSelection {
            textView.setSelectedRange(savedSelection)
        } else {
            textView.scrollToEndOfDocument(nil)
        }

        promptLocation = textView.textStorage?.length ?? 0

        // エラーチェック（エラーなら履歴に追加しない）
        completionProvider.checkOutputForError(text)

        // 出力からコマンドを抽出（スニペット用）
        completionProvider.extractCommandsFromOutput(text)
    }

    private func parseANSI(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var currentColor: NSColor = .white
        var bold = false

        var cleaned = text
        // OSCシーケンス（タイトル設定など）
        cleaned = cleaned.replacingOccurrences(of: "\u{1B}\\][^\u{07}]*\u{07}", with: "", options: .regularExpression)
        // Private modeシーケンス（bracketed paste等）: ESC [ ? 数字 h/l
        cleaned = cleaned.replacingOccurrences(of: "\u{1B}\\[\\?[0-9]+[hl]", with: "", options: .regularExpression)
        // CSIシーケンス全般（色以外）: ESC [ 数字/; 文字
        cleaned = cleaned.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[ABCDEFGHJKSTfnl]", with: "", options: .regularExpression)
        // 文字セット切り替え
        cleaned = cleaned.replacingOccurrences(of: "\u{1B}\\([AB0]", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\u{1B}[=>]", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\r", with: "")

        let pattern = "\u{1B}\\[([0-9;]*)m"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return NSAttributedString(string: cleaned, attributes: defaultAttrs())
        }

        var lastEnd = cleaned.startIndex
        let nsString = cleaned as NSString

        regex.enumerateMatches(in: cleaned, range: NSRange(location: 0, length: nsString.length)) { match, _, _ in
            guard let match = match else { return }
            let matchStart = cleaned.index(cleaned.startIndex, offsetBy: match.range.location)

            if matchStart > lastEnd {
                let segment = String(cleaned[lastEnd..<matchStart])
                result.append(NSAttributedString(string: segment, attributes: makeAttrs(color: currentColor, bold: bold)))
            }

            if match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
                let codes = nsString.substring(with: match.range(at: 1)).split(separator: ";").compactMap { Int($0) }
                for code in codes.isEmpty ? [0] : codes {
                    switch code {
                    case 0: currentColor = .white; bold = false
                    case 1: bold = true
                    case 22: bold = false
                    case 30: currentColor = .black
                    case 31: currentColor = NSColor(red: 1, green: 0.3, blue: 0.3, alpha: 1)
                    case 32: currentColor = NSColor(red: 0.3, green: 0.9, blue: 0.3, alpha: 1)
                    case 33: currentColor = NSColor(red: 1, green: 0.9, blue: 0.3, alpha: 1)
                    case 34: currentColor = NSColor(red: 0.4, green: 0.6, blue: 1, alpha: 1)
                    case 35: currentColor = NSColor(red: 0.9, green: 0.5, blue: 0.9, alpha: 1)
                    case 36: currentColor = NSColor(red: 0.5, green: 0.9, blue: 0.9, alpha: 1)
                    case 37, 39: currentColor = .white
                    case 90: currentColor = .gray
                    case 91: currentColor = NSColor(red: 1, green: 0.5, blue: 0.5, alpha: 1)
                    case 92: currentColor = NSColor(red: 0.5, green: 1, blue: 0.5, alpha: 1)
                    case 93: currentColor = NSColor(red: 1, green: 1, blue: 0.5, alpha: 1)
                    case 94: currentColor = NSColor(red: 0.6, green: 0.8, blue: 1, alpha: 1)
                    case 95: currentColor = NSColor(red: 1, green: 0.7, blue: 1, alpha: 1)
                    case 96: currentColor = NSColor(red: 0.7, green: 1, blue: 1, alpha: 1)
                    case 97: currentColor = .white
                    default: break
                    }
                }
            }
            lastEnd = cleaned.index(cleaned.startIndex, offsetBy: match.range.location + match.range.length)
        }

        if lastEnd < cleaned.endIndex {
            result.append(NSAttributedString(string: String(cleaned[lastEnd...]), attributes: makeAttrs(color: currentColor, bold: bold)))
        }

        return result
    }

    private func defaultAttrs() -> [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), .foregroundColor: NSColor.white]
    }

    private func makeAttrs(color: NSColor, bold: Bool) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: bold ? .bold : .regular), .foregroundColor: color]
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(textView)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.window?.makeFirstResponder(self?.textView)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        shell?.terminate()
        ptyController?.stop()
    }

    // MARK: - 補完機能

    func updateCompletion() {
        let currentText = textView.string
        let input = String(currentText.suffix(currentText.count - promptLocation))

        let completions = completionProvider.getCompletions(for: input, cwd: currentDirectory)

        if completions.isEmpty {
            hideCompletion()
        } else {
            showCompletion(items: completions)
        }
    }

    func showHistoryCompletion() {
        let historyItems = completionProvider.getHistoryItems()
        if historyItems.isEmpty {
            hideCompletion()
        } else {
            showCompletion(items: historyItems, selectLast: true)
        }
    }

    private func showCompletion(items: [CompletionItem], selectLast: Bool = false) {
        if completionPopup == nil {
            completionPopup = CompletionPopupView(frame: NSRect(x: 0, y: 0, width: 300, height: 150))
        }

        guard let popup = completionPopup else { return }
        popup.updateItems(items, selectLast: selectLast)

        // カーソル位置に表示
        if let layoutManager = textView.layoutManager,
           let textContainer = textView.textContainer {
            let glyphRange = layoutManager.glyphRange(for: textContainer)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let cursorY = rect.maxY + textView.textContainerInset.height

            popup.frame.origin = NSPoint(
                x: 16,
                y: bounds.height - cursorY - popup.frame.height - 8
            )
        }

        if popup.superview == nil {
            addSubview(popup)
        }
    }

    func hideCompletion() {
        completionPopup?.removeFromSuperview()
    }

    func selectNextCompletion() {
        completionPopup?.selectNext()
    }

    func selectPreviousCompletion() {
        completionPopup?.selectPrevious()
    }

    func applyCompletion() -> Bool {
        guard let item = completionPopup?.confirmSelection() else { return false }

        // 現在のテキストを取得（最新の状態）
        let currentText = textView.string
        let input = String(currentText.suffix(currentText.count - promptLocation))
        let parts = input.split(separator: " ", omittingEmptySubsequences: false)

        var newInput: String

        // ディレクトリ/ファイル補完の場合はパスを考慮
        if item.type == .directory || item.type == .file {
            let lastPart = String(parts.last ?? "")

            // パスの最後のコンポーネントだけを置き換え
            let newPath: String
            if lastPart.contains("/") {
                // パスの途中: 最後の / より前を保持して、補完を追加
                let pathPrefix = String(lastPart.dropLast(lastPart.count - (lastPart.lastIndex(of: "/")!.utf16Offset(in: lastPart) + 1)))
                newPath = pathPrefix + item.text + "/"
            } else if lastPart.isEmpty {
                // 空の場合はそのまま追加
                newPath = item.text + "/"
            } else {
                // パスなし: 補完で置き換え
                newPath = item.text + "/"
            }

            var newParts = Array(parts.dropLast())
            newParts.append(Substring(newPath))
            newInput = newParts.joined(separator: " ")
        } else if item.text.hasPrefix("-") {
            // オプション: コマンドの後に追加
            let lastPart = String(parts.last ?? "")
            if lastPart.hasPrefix("-") {
                // 既にオプション入力中なら置き換え
                var newParts = Array(parts.dropLast())
                newParts.append(Substring(item.text))
                newInput = newParts.joined(separator: " ") + " "
            } else {
                // コマンド名の後にオプションを追加
                newInput = input + " " + item.text + " "
            }
        } else {
            // コマンド等: 従来通り最後のパートを置き換え
            var newParts = Array(parts.dropLast())
            newParts.append(Substring(item.displayText))
            newInput = newParts.joined(separator: " ")

            // コマンドの場合はスペースを追加
            if item.type == .command {
                newInput += " "
            }
        }

        // テキストを更新（textStorageを直接操作）
        if let storage = textView.textStorage {
            let range = NSRange(location: promptLocation, length: storage.length - promptLocation)
            storage.beginEditing()
            storage.replaceCharacters(in: range, with: newInput)
            storage.endEditing()
        }
        textView.setSelectedRange(NSRange(location: promptLocation + newInput.count, length: 0))

        hideCompletion()

        // ハイライトを更新
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.updateSyntaxHighlight()
        }

        // cd, git, ディレクトリ選択後は次の補完をすぐ表示
        if item.text == "cd" || item.text == "git" || item.type == .directory {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.updateCompletion()
            }
        }

        return true
    }

    func updateSyntaxHighlight() {
        // 前回のワークをキャンセル
        highlightWorkItem?.cancel()

        // デバウンス: 50ms後に実行
        let workItem = DispatchWorkItem { [weak self] in
            self?.applySyntaxHighlight()
        }
        highlightWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    private func applySyntaxHighlight() {
        guard let textStorage = textView.textStorage else { return }
        let fullText = textView.string
        guard fullText.count > promptLocation else { return }

        // 選択範囲がある場合はハイライトをスキップ
        let selection = textView.selectedRange()
        if selection.length > 0 {
            return
        }

        // 入力部分のみハイライト
        let inputText = String(fullText.suffix(fullText.count - promptLocation))
        let colorRanges = syntaxHighlighter.getColorRanges(inputText)

        // 属性のみを更新（テキストは変更しない）
        for (range, color) in colorRanges {
            let adjustedRange = NSRange(location: promptLocation + range.location, length: range.length)
            if adjustedRange.location + adjustedRange.length <= textStorage.length {
                textStorage.addAttribute(.foregroundColor, value: color, range: adjustedRange)
            }
        }
    }

    func recordCommand(_ command: String) {
        completionProvider.addToHistory(command)

        // cdコマンドの場合、currentDirectoryを更新
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("cd ") || trimmed == "cd" {
            var path: String
            if trimmed == "cd" {
                path = FileManager.default.homeDirectoryForCurrentUser.path
            } else {
                path = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if path.hasPrefix("~") {
                    path = path.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
                } else if !path.hasPrefix("/") {
                    path = (currentDirectory as NSString).appendingPathComponent(path)
                }
            }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                currentDirectory = path
            }
        }
    }
}

// MARK: - TerminalTextView

protocol TerminalTextViewDelegate: AnyObject {
    func sendToShell(_ text: String)
    func executeCommand(_ command: String)
    var promptLocation: Int { get }
    var currentDirectory: String { get }
    var isCompletionVisible: Bool { get }
    var isPTYMode: Bool { get }
    func updateCompletion()
    func hideCompletion()
    func selectNextCompletion()
    func selectPreviousCompletion()
    func applyCompletion() -> Bool
    func recordCommand(_ command: String)
    func updateSyntaxHighlight()
    func showHistoryCompletion()
}

class TerminalTextView: NSTextView {
    weak var terminalDelegate: TerminalTextViewDelegate?
    private var preservedSelection: NSRange?

    override var acceptsFirstResponder: Bool { true }

    // 選択範囲を保存
    func saveSelection() {
        let range = selectedRange()
        if range.length > 0 {
            preservedSelection = range
        }
    }

    // 選択範囲を復元
    func restoreSelection() {
        if let saved = preservedSelection, saved.location + saved.length <= string.count {
            setSelectedRange(saved)
        }
        preservedSelection = nil
    }

    override func setSelectedRange(_ charRange: NSRange) {
        // 選択がクリアされる場合、保存された選択があれば無視
        if charRange.length == 0, let saved = preservedSelection, saved.length > 0 {
            return
        }
        super.setSelectedRange(charRange)
    }

    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        // ドラッグ中でなければ選択のクリアを防ぐ
        if !stillSelectingFlag && charRange.length == 0, let saved = preservedSelection, saved.length > 0 {
            return
        }
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelectingFlag)
        // ドラッグ終了時に保存
        if !stillSelectingFlag && charRange.length > 0 {
            preservedSelection = charRange
        }
    }

    // 選択をクリア（明示的に呼ぶ用）
    func clearPreservedSelection() {
        preservedSelection = nil
    }

    override func keyDown(with event: NSEvent) {
        let key = event.keyCode
        let isCompletionVisible = terminalDelegate?.isCompletionVisible ?? false

        // PTYモード中はキー入力を直接送信
        if terminalDelegate?.isPTYMode == true {
            // IME入力中（変換候補表示中）かどうかをチェック
            // markedRange().length > 0 の場合のみIME入力中（lengthが0なら確定済み）
            let marked = markedRange()
            let isComposing = marked.location != NSNotFound && marked.length > 0

            // IME入力中は通常のキー処理（Enter=確定、Esc=キャンセル等）
            if isComposing {
                interpretKeyEvents([event])
                return
            }

            // 特殊キーの処理
            switch key {
            case 36: // Enter
                if event.modifierFlags.contains(.shift) {
                    // Shift+Enter: 改行
                    terminalDelegate?.sendToShell("\n")
                } else {
                    // Enter: 送信
                    terminalDelegate?.sendToShell("\r")
                }
            case 51: // Backspace
                terminalDelegate?.sendToShell("\u{7F}")
            case 53: // Escape
                terminalDelegate?.sendToShell("\u{1B}")
            case 48: // Tab
                terminalDelegate?.sendToShell("\t")
            case 126: // Up
                terminalDelegate?.sendToShell("\u{1B}[A")
            case 125: // Down
                terminalDelegate?.sendToShell("\u{1B}[B")
            case 124: // Right
                terminalDelegate?.sendToShell("\u{1B}[C")
            case 123: // Left
                terminalDelegate?.sendToShell("\u{1B}[D")
            default:
                // Ctrl+キーの処理
                if event.modifierFlags.contains(.control) {
                    if let chars = event.charactersIgnoringModifiers, let c = chars.first {
                        let code = Int(c.asciiValue ?? 0)
                        if code >= 97 && code <= 122 { // a-z
                            let ctrlCode = code - 96
                            terminalDelegate?.sendToShell(String(UnicodeScalar(ctrlCode)!))
                        }
                    }
                } else {
                    // 通常の文字入力はinterpretKeyEventsで処理（IME対応）
                    interpretKeyEvents([event])
                }
            }
            return
        }

        // Esc - 補完を閉じる
        if key == 53 {
            if isCompletionVisible {
                terminalDelegate?.hideCompletion()
                return
            }
        }

        // Tab - 補完確定 or トリガー
        if key == 48 {
            if isCompletionVisible {
                if terminalDelegate?.applyCompletion() == true {
                    return
                }
            } else {
                terminalDelegate?.updateCompletion()
                return
            }
        }

        // 上下矢印
        if key == 126 { // Up
            if isCompletionVisible {
                terminalDelegate?.selectPreviousCompletion()
            } else {
                // 補完が出てなければ履歴一覧を表示
                terminalDelegate?.showHistoryCompletion()
            }
            return
        }
        if key == 125 { // Down
            if isCompletionVisible {
                terminalDelegate?.selectNextCompletion()
            }
            return
        }

        // Enter
        if key == 36 {
            terminalDelegate?.hideCompletion()
            let currentText = string
            let input = String(currentText.suffix(currentText.count - (terminalDelegate?.promptLocation ?? 0)))
            terminalDelegate?.recordCommand(input)
            terminalDelegate?.executeCommand(input)
            return
        }

        // Ctrl+C (シェルに送信)
        if event.modifierFlags.contains(.control), event.charactersIgnoringModifiers == "c" {
            terminalDelegate?.hideCompletion()
            terminalDelegate?.sendToShell("\u{03}")
            return
        }

        // Ctrl+D
        if event.modifierFlags.contains(.control), event.charactersIgnoringModifiers == "d" {
            terminalDelegate?.sendToShell("\u{04}")
            return
        }

        // Ctrl+Z
        if event.modifierFlags.contains(.control), event.charactersIgnoringModifiers == "z" {
            terminalDelegate?.sendToShell("\u{1A}")
            return
        }

        // Backspace - プロンプト以前を消さない
        if key == 51 {
            let promptLoc = terminalDelegate?.promptLocation ?? 0
            if selectedRange().location <= promptLoc {
                return
            }
        }

        // 左矢印 - プロンプト以前に行かない
        if key == 123 {
            let promptLoc = terminalDelegate?.promptLocation ?? 0
            if selectedRange().location <= promptLoc {
                return
            }
        }

        super.keyDown(with: event)

        // 入力後にハイライトと補完を更新（デバウンスは各メソッド内で処理）
        terminalDelegate?.updateSyntaxHighlight()
        terminalDelegate?.updateCompletion()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // PTYモード中はPTYに送信
        if terminalDelegate?.isPTYMode == true {
            if let str = string as? String {
                terminalDelegate?.sendToShell(str)
            }
            return
        }

        // 通常モードは標準処理
        super.insertText(string, replacementRange: replacementRange)
    }

    override func doCommand(by selector: Selector) {
        // PTYモード中は標準コマンドを無視（IME以外の処理はkeyDownで行う）
        if terminalDelegate?.isPTYMode == true {
            // insertNewline:, deleteBackward:等の標準コマンドを無視
            // IME関連の処理（insertText）は別メソッドで正常に動作
            return
        }
        super.doCommand(by: selector)
    }

    override func paste(_ sender: Any?) {
        // PTYモード中はPTYに送信
        if terminalDelegate?.isPTYMode == true {
            if let str = NSPasteboard.general.string(forType: .string) {
                terminalDelegate?.sendToShell(str)
            }
            return
        }

        if let str = NSPasteboard.general.string(forType: .string) {
            insertText(str, replacementRange: selectedRange())
        }
        terminalDelegate?.updateSyntaxHighlight()
        terminalDelegate?.updateCompletion()
    }

    override func insertNewline(_ sender: Any?) {
        // Enterキー: コマンド実行
        terminalDelegate?.hideCompletion()
        clearPreservedSelection()
        let currentText = string
        let input = String(currentText.suffix(currentText.count - (terminalDelegate?.promptLocation ?? 0)))
        terminalDelegate?.recordCommand(input)

        terminalDelegate?.executeCommand(input)
    }

    @objc override func copy(_ sender: Any?) {
        let range = selectedRange()
        if range.length > 0 {
            let selectedText = (string as NSString).substring(with: range)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selectedText, forType: .string)
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // クリック後、カーソルがプロンプト以前なら末尾に移動
        let promptLoc = terminalDelegate?.promptLocation ?? 0
        if selectedRange().location < promptLoc {
            setSelectedRange(NSRange(location: string.count, length: 0))
        }
    }
}

extension TerminalNSView: TerminalTextViewDelegate {}
