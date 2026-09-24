import Foundation

public enum AccountText {
    /// Account responses remain one bounded printable-ASCII line. Secrets never
    /// enter command-line arguments, the process environment, or input history.
    public static func responseData(_ value: String) -> Data? {
        guard value.utf8.count <= 1000,
              value.utf8.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) else { return nil }
        return Data((value + "\n").utf8)
    }
}
/// Discards all terminal-control sequences and non-ASCII bytes before AppKit sees
/// them. State persists across reads, including split OSC/CSI escape sequences.
public final class TerminalTextFilter {
    public init() {}
    private enum State { case plain, escape, csi, string, stringEscape }
    private var state = State.plain
    private var replacingNonASCII = false

    public func consume(_ data: Data) -> String {
        var result = [UInt8]()
        for byte in data {
            switch state {
            case .plain:
                if byte == 0x1b { state = .escape; replacingNonASCII = false }
                else if byte == 9 {
                    result.append(contentsOf: [32, 32, 32, 32]); replacingNonASCII = false
                } else if byte == 10 || (byte >= 32 && byte <= 126) {
                    result.append(byte); replacingNonASCII = false
                } else if byte >= 128 {
                    if !replacingNonASCII { result.append(contentsOf: "[non-ASCII]".utf8) }
                    replacingNonASCII = true
                } else { replacingNonASCII = false }
            case .escape:
                switch byte {
                case 0x5b: state = .csi
                case 0x5d, 0x50, 0x5e, 0x5f: state = .string
                case 0x20...0x2f: break
                default: state = .plain
                }
            case .csi:
                if byte >= 0x40 && byte <= 0x7e { state = .plain }
            case .string:
                if byte == 7 { state = .plain }
                else if byte == 0x1b { state = .stringEscape }
            case .stringEscape:
                state = byte == 0x5c ? .plain : .string
            }
        }
        return String(decoding: result, as: UTF8.self)
    }
}
