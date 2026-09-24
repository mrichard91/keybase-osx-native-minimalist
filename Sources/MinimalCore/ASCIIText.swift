import Foundation

/// The single boundary between untrusted message strings and plain-text UI.
/// This type never interprets markup, links, ANSI escapes, or Unicode controls.
public enum ASCIIText {
    public static let maximumDisplayBytes = 32_768
    public static let maximumOutgoingBytes = 10_000

    public enum ValidationError: Error, LocalizedError, Equatable, Sendable {
        case empty
        case tooLong
        case unsupportedScalar(UInt32)

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "Enter a message containing printable ASCII text."
            case .tooLong:
                return "Messages must contain at most 10,000 ASCII bytes after emoji conversion."
            case .unsupportedScalar(let value):
                return "Unsupported character \(ASCIIText.escape(value)). Use ASCII text and emoji shortcodes such as :smile:."
            }
        }
    }

    /// Produces printable ASCII and LF only. The limit is in output bytes and
    /// is clamped to 0...32,768, including the visible truncation marker.
    /// Traversal is bounded by that output cap, even for a huge grapheme cluster.
    public static func sanitize(_ text: String, limit: Int = maximumDisplayBytes) -> String {
        let cap = min(max(limit, 0), maximumDisplayBytes)
        guard cap > 0 else { return "" }
        var output: [UInt8] = []
        var boundaries: [Int] = []
        output.reserveCapacity(min(cap, 1_024))
        let scalars = text.unicodeScalars
        var index = scalars.startIndex

        while index < scalars.endIndex {
            let token: String
            if let match = emoji.match(in: scalars, from: index) {
                token = match.text
                index = match.end
            } else {
                let scalar = scalars[index]
                scalars.formIndex(after: &index)
                switch scalar.value {
                case 10: token = "\n"
                case 13:
                    if index < scalars.endIndex, scalars[index].value == 10 {
                        scalars.formIndex(after: &index)
                    }
                    token = "\n"
                case 9: token = "    "
                case 32...126: token = String(scalar)
                default: token = escape(scalar.value)
                }
            }
            let bytes = Array(token.utf8)
            guard bytes.count <= cap - output.count else {
                let marker = Array("[truncated]".utf8.prefix(cap))
                while output.count > cap - marker.count, let boundary = boundaries.popLast() {
                    output.removeLast(output.count - boundary)
                }
                output.append(contentsOf: marker)
                break
            }
            boundaries.append(output.count)
            output.append(contentsOf: bytes)
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Converts known emoji to official ASCII shortcodes. Other non-ASCII and
    /// control characters are rejected, never silently removed or transliterated.
    /// CRLF/CR become LF; tabs become four spaces. The returned text is the exact
    /// string that the transport must send, without converting shortcodes back.
    public static func validateOutgoing(_ text: String) throws -> String {
        let output = try normalizeInput(text)
        guard output.utf8.contains(where: { $0 > 32 }) else { throw ValidationError.empty }
        return output
    }

    /// Normalizes a composer edit before AppKit can render it. Empty/whitespace
    /// fragments are valid here; final sending also applies the nonblank check.
    public static func normalizeInput(_ text: String) throws -> String {
        var output = ""
        output.reserveCapacity(256)
        var count = 0
        let scalars = text.unicodeScalars
        var index = scalars.startIndex

        while index < scalars.endIndex {
            let token: String
            if let match = emoji.match(in: scalars, from: index) {
                token = match.text
                index = match.end
            } else {
                let scalar = scalars[index]
                scalars.formIndex(after: &index)
                switch scalar.value {
                case 10: token = "\n"
                case 13:
                    if index < scalars.endIndex, scalars[index].value == 10 {
                        scalars.formIndex(after: &index)
                    }
                    token = "\n"
                case 9: token = "    "
                case 32...126: token = String(scalar)
                default: throw ValidationError.unsupportedScalar(scalar.value)
                }
            }
            count += token.utf8.count
            guard count <= maximumOutgoingBytes else { throw ValidationError.tooLong }
            output.append(token)
        }
        return output
    }

    /// Exact official built-in names/aliases only. This does not resolve a
    /// team's custom emoji or perform any network request.
    public static func isKnownEmojiShortcode(_ value: String) -> Bool {
        emoji.aliases.contains(value)
    }

    private static func escape(_ value: UInt32) -> String {
        let hex = String(value, radix: 16, uppercase: true)
        return "[U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex + "]"
    }

    private static let emoji = EmojiTable()
}

/// A finite scalar trie avoids unbounded grapheme segmentation and regexes on
/// attacker-controlled strings. The bundled table is data, not executable code.
private struct EmojiTable: Sendable {
    private struct Node: Sendable {
        var next: [UInt32: Int] = [:]
        var shortcode: String?
    }
    struct Match {
        let text: String
        let end: String.UnicodeScalarView.Index
    }
    private let nodes: [Node]
    let aliases: Set<String>
    private static let maximumMatchScalars = 32

    private static var resourceBundle: Bundle? {
        // SwiftPM's generated Bundle.module looks beside the executable, whereas
        // a distributed .app stores this resource bundle in Contents/Resources.
        // Missing resources in an installed app must fail closed, without trying
        // a developer's build directory or the generated accessor's fatalError.
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let resources = Bundle.main.resourceURL else { return nil }
            return Bundle(url: resources.appendingPathComponent("KeybaseMinimal_MinimalCore.bundle"))
        }
        return Bundle.module
    }

    private static func validShortcode(_ shortcode: String) -> Bool {
        (3...100).contains(shortcode.utf8.count) && shortcode.hasPrefix(":" ) && shortcode.hasSuffix(":") &&
        shortcode.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || [UInt8(43), 45, 58, 95].contains(byte)
        }
    }

    init() {
        var nodes = [Node()]
        let bundle = Self.resourceBundle
        if let url = bundle?.url(forResource: "emoji-shortcodes", withExtension: "json"),
           let data = try? Data(contentsOf: url), data.count <= 256_000,
           let table = try? JSONDecoder().decode([String: String].self, from: data) {
            for (unicode, shortcode) in table.sorted(by: { $0.key < $1.key }) {
                // Fail closed if the resource is malformed. Restrict names to the
                // official format so a resource can never inject display controls.
                guard !unicode.isEmpty, unicode.unicodeScalars.count <= 16,
                      Self.validShortcode(shortcode) else { continue }
                let exact = unicode.unicodeScalars.map(\.value)
                // Standard emoji may arrive with or without VS16. Never drop a
                // standalone selector or a selector attached to ordinary text.
                for sequence in [exact, exact.filter { $0 != 0xFE0F }] {
                    guard sequence.contains(where: { $0 > 127 }) else { continue }
                    var position = 0
                    for scalar in sequence {
                        if let next = nodes[position].next[scalar] {
                            position = next
                        } else {
                            let next = nodes.count
                            nodes.append(Node())
                            nodes[position].next[scalar] = next
                            position = next
                        }
                    }
                    if nodes[position].shortcode == nil {
                        nodes[position].shortcode = shortcode
                    }
                }
            }
        }
        // Missing resources simply leave every non-ASCII scalar escaped inbound
        // and rejected outbound; they cannot cause raw Unicode display.
        self.nodes = nodes
        if let url = bundle?.url(forResource: "emoji-aliases", withExtension: "json"),
           let data = try? Data(contentsOf: url), data.count <= 256_000,
           let values = try? JSONDecoder().decode([String].self, from: data) {
            aliases = Set(values.filter(Self.validShortcode))
        } else {
            aliases = Set(nodes.compactMap(\.shortcode))
        }
    }

    func match(in scalars: String.UnicodeScalarView, from start: String.UnicodeScalarView.Index) -> Match? {
        var index = start
        var position = 0
        var previous: Unicode.Scalar?
        var tones = ""
        var best: Match?
        var consumed = 0
        while index < scalars.endIndex, consumed < Self.maximumMatchScalars {
            let scalar = scalars[index]
            if let next = nodes[position].next[scalar.value] {
                position = next
            } else if (0x1F3FB...0x1F3FF).contains(scalar.value),
                      previous?.properties.isEmojiModifierBase == true, position != 0 {
                tones += ":skin-tone-\(scalar.value - 0x1F3F9):"
            } else if scalar.value == 0xFE0F, let previous,
                      previous.value > 127, previous.properties.isEmoji, position != 0 {
                // A presentation selector may follow an otherwise fully qualified
                // emoji. The preceding-scalar check prevents repeated selectors.
            } else {
                break
            }
            scalars.formIndex(after: &index)
            consumed += 1
            previous = scalar
            if let shortcode = nodes[position].shortcode {
                best = Match(text: shortcode + tones, end: index)
            }
        }
        return best
    }
}
