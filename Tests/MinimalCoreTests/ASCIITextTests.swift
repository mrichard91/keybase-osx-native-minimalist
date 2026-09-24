import XCTest
@testable import MinimalCore

final class ASCIITextTests: XCTestCase {
    func testComposerFragmentsNormalizeWithoutRenderingUnicode() throws {
        XCTAssertEqual(try ASCIIText.normalizeInput(""), "")
        XCTAssertEqual(try ASCIIText.normalizeInput("\t\r\n"), "    \n")
        XCTAssertEqual(try ASCIIText.normalizeInput("😀"), ":grinning:")
        XCTAssertThrowsError(try ASCIIText.normalizeInput("a\u{202E}"))
        XCTAssertThrowsError(try ASCIIText.normalizeInput(String(repeating: "x", count: 10_001)))
    }

    func testOnlyOfficialBuiltInEmojiAliasesAreKnown() {
        for value in [":grinning:", ":+1:", ":information_desk_person:", ":skin-tone-4:", ":female-technologist:"] {
            XCTAssertTrue(ASCIIText.isKnownEmojiShortcode(value), value)
        }
        for value in [":a_custom_emoji:", ":thumbsup:", ":thumbsup:garbage", "thumbsup", "😀", ":\u{202E}:"] {
            XCTAssertFalse(ASCIIText.isKnownEmojiShortcode(value), value)
        }
    }

    func testPlainTextAndWhitespace() throws {
        let text = "<b>hello</b> https://example.com :custom_emoji:\r\nnext\rtab\tend"
        let expected = "<b>hello</b> https://example.com :custom_emoji:\nnext\ntab    end"
        XCTAssertEqual(ASCIIText.sanitize(text), expected)
        XCTAssertEqual(try ASCIIText.validateOutgoing(text), expected)
    }

    func testControlsAndBidiAreVisibleAndOutgoingRejected() {
        let scalars: [UInt32] = [0, 7, 8, 11, 12, 27, 31, 127, 128, 0x200B, 0x200D, 0x202E, 0x2066, 0x2069, 0xFEFF]
        for value in scalars {
            let raw = String(Unicode.Scalar(value)!)
            XCTAssertTrue(ASCIIText.sanitize(raw).hasPrefix("[U+"), "Scalar \(value)")
            XCTAssertThrowsError(try ASCIIText.validateOutgoing("x" + raw)) { error in
                XCTAssertEqual(error as? ASCIIText.ValidationError, .unsupportedScalar(value))
            }
        }
        XCTAssertEqual(ASCIIText.sanitize("\u{1B}[31mred\u{1B}[0m"), "[U+001B][31mred[U+001B][0m")
    }

    func testKnownEmojiUsePinnedOfficialShortcodes() throws {
        let samples = [
            ("😀", ":grinning:"),
            ("👍", ":+1:"),
            ("👍🏽", ":+1::skin-tone-4:"),
            ("👩🏽‍💻", ":female-technologist::skin-tone-4:"),
            ("👨‍👩‍👧‍👦", ":man-woman-girl-boy:"),
            ("🇺🇸", ":us:"),
            ("❤️", ":heart:"),
            ("❤", ":heart:"),
            ("1️⃣", ":one:"),
            ("1⃣", ":one:"),
            ("🏳️‍🌈", ":rainbow-flag:"),
            ("👩🏿‍❤️‍💋‍👩🏻", ":woman-kiss-woman::skin-tone-6::skin-tone-2:")
        ]
        for (raw, expected) in samples {
            XCTAssertEqual(ASCIIText.sanitize(raw), expected, raw)
            XCTAssertEqual(try ASCIIText.validateOutgoing(raw), expected, raw)
        }
    }

    func testUnicodeIsNotConfusablyTransliterated() {
        XCTAssertEqual(ASCIIText.sanitize("café"), "caf[U+00E9]")
        XCTAssertEqual(ASCIIText.sanitize("e\u{301}"), "e[U+0301]")
        XCTAssertEqual(ASCIIText.sanitize("pаypal"), "p[U+0430]ypal")
        XCTAssertEqual(ASCIIText.sanitize("a\u{FE0F}"), "a[U+FE0F]")
        XCTAssertEqual(ASCIIText.sanitize("😀\u{200D}x"), ":grinning:[U+200D]x")
        XCTAssertThrowsError(try ASCIIText.validateOutgoing("pаypal"))
        XCTAssertThrowsError(try ASCIIText.validateOutgoing("😀\u{200D}x"))
    }

    func testOutgoingLengthAndBlankValidation() throws {
        XCTAssertEqual(try ASCIIText.validateOutgoing(String(repeating: "x", count: 10_000)).utf8.count, 10_000)
        XCTAssertThrowsError(try ASCIIText.validateOutgoing(String(repeating: "x", count: 10_001))) { error in
            XCTAssertEqual(error as? ASCIIText.ValidationError, .tooLong)
        }
        // Emoji expansion counts against the limit, including shortcode colons.
        XCTAssertThrowsError(try ASCIIText.validateOutgoing(String(repeating: "😀", count: 1_001)))
        for blank in ["", " ", "\r\n\t "] {
            XCTAssertThrowsError(try ASCIIText.validateOutgoing(blank)) { error in
                XCTAssertEqual(error as? ASCIIText.ValidationError, .empty)
            }
        }
    }

    func testDisplayBoundsAndNoBrokenTokenTruncation() {
        XCTAssertEqual(ASCIIText.sanitize("hello", limit: 0), "")
        XCTAssertEqual(ASCIIText.sanitize("hello", limit: -1), "")
        XCTAssertEqual(ASCIIText.sanitize("hello", limit: 5), "hello")
        XCTAssertEqual(ASCIIText.sanitize(String(repeating: "é", count: 50), limit: 20), "[U+00E9][truncated]")
        XCTAssertEqual(ASCIIText.sanitize("😀", limit: 3), "[tr")
        let huge = String(repeating: "x", count: 50_000)
        XCTAssertEqual(ASCIIText.sanitize(huge, limit: Int.max).utf8.count, ASCIIText.maximumDisplayBytes)
        XCTAssertTrue(ASCIIText.sanitize(huge).hasSuffix("[truncated]"))
    }

    func testASCIIInvariantAcrossScalarSpaceAndHugeGrapheme() {
        // This includes every valid scalar, not only ordinary message samples.
        var batch = ""
        for value in UInt32(0)...UInt32(0x10FFFF) {
            if let scalar = Unicode.Scalar(value) { batch.unicodeScalars.append(scalar) }
            if value % 1024 == 1023 || value == 0x10FFFF {
                let rendered = ASCIIText.sanitize(batch)
                XCTAssertTrue(rendered.utf8.allSatisfy { $0 == 10 || (32...126).contains($0) })
                XCTAssertLessThanOrEqual(rendered.utf8.count, ASCIIText.maximumDisplayBytes)
                batch = ""
            }
        }
        let hugeGrapheme = "a" + String(repeating: "\u{0301}", count: 100_000)
        let rendered = ASCIIText.sanitize(hugeGrapheme, limit: 256)
        XCTAssertLessThanOrEqual(rendered.utf8.count, 256)
        XCTAssertTrue(rendered.hasSuffix("[truncated]"))
    }
}
