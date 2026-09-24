import XCTest
@testable import MinimalCore

private let testConversationID = String(repeating: "a", count: 64)

private func conversation(_ id: String = testConversationID, name: String = "alice,bob", topic: String = "",
                          members: String = "impteamnative", isPublic: Bool = false) -> [String: Any] {
    ["id": id, "channel": ["name": name, "topic_name": topic, "members_type": members,
                              "topic_type": "chat", "public": isPublic], "unread": true]
}

private func listResult(_ entries: [[String: Any]]) -> [String: Any] {
    ["conversations": entries, "offline": false]
}

private func reply(_ result: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["result": result])
}

private func rawMessage(id: Int, kind: String = "text", body: String = "hello") -> [String: Any] {
    ["msg": ["id": id, "conversation_id": testConversationID,
              "channel": conversation()["channel"]!, "sender": ["username": "alice"],
              "sent_at": 1_700_000_000, "content": ["type": kind, "text": ["body": body]]]]
}

private actor FakeCommands {
    var responses: [Data]
    var inputs: [Data] = []
    var arguments: [[String]] = []

    init(_ results: [Any]) throws { responses = try results.map(reply) }

    func run(_ executable: URL, _ args: [String], _ input: Data?, _ timeout: TimeInterval, _ limit: Int) throws -> ProcessOutput {
        guard !responses.isEmpty else { throw KeybaseClientError.invalidReply }
        arguments.append(args)
        inputs.append(input ?? Data())
        return ProcessOutput(stdout: responses.removeFirst(), stderr: Data(), status: 0)
    }

    func requests() throws -> [[String: Any]] {
        try inputs.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
    }

    func methods() throws -> [String] { try requests().compactMap { $0["method"] as? String } }
    func recordedArguments() -> [[String]] { arguments }
}

final class KeybaseClientTests: XCTestCase {
    private func client(_ commands: FakeCommands) -> KeybaseClient {
        KeybaseClient(executable: URL(fileURLWithPath: "/test/keybase"), runner: { url, args, input, timeout, limit in
            try await commands.run(url, args, input, timeout, limit)
        })
    }

    func testInboxFiltersPublicUnknownAndNonChatConversations() throws {
        var development = conversation(String(repeating: "b", count: 64))
        var channel = development["channel"] as! [String: Any]
        channel["topic_type"] = "dev"
        development["channel"] = channel
        let result = listResult([conversation(), conversation(String(repeating: "c", count: 64), isPublic: true),
                                 development, conversation(String(repeating: "d", count: 64), members: "unknown")])
        let values = try ChatDecoder.conversations(from: result)
        XCTAssertEqual(values.map(\.id), [testConversationID])
        XCTAssertEqual(values.first?.displayName, "alice,bob")
        XCTAssertTrue(values.first?.unread == true)
    }

    func testEmptyInboxIsNullInOfficialGoJSON() throws {
        XCTAssertEqual(try ChatDecoder.conversations(from: ["conversations": NSNull()]), [])
    }

    func testIdentityFailuresAndOfflineAreNotIgnored() throws {
        XCTAssertThrowsError(try ChatDecoder.result(from: reply(["identify_failures": [["username": "alice"]]]))) {
            XCTAssertEqual($0 as? KeybaseClientError, .identityFailure)
        }
        XCTAssertThrowsError(try ChatDecoder.result(from: reply(["offline": true]))) {
            XCTAssertEqual($0 as? KeybaseClientError, .offline)
        }
    }

    func testTextDecodedAsPlainASCIIAndMediaPayloadNeverDisplayed() throws {
        let result: [String: Any] = ["messages": [
            rawMessage(id: 4, kind: "attachment", body: "file:///etc/passwd"),
            rawMessage(id: 3, kind: "unfurl", body: "<script>secret</script>"),
            rawMessage(id: 2, kind: "edit", body: "old removed secret"),
            rawMessage(id: 1, body: "<b>hello</b> 😀\u{202e}"),
        ], "pagination": ["next": "b2xk", "last": false]]
        let page = try ChatDecoder.page(from: result, conversationID: testConversationID)
        XCTAssertEqual(page.messages.map(\.id), ["1", "2", "3", "4"])
        XCTAssertTrue(page.messages[0].body.hasPrefix("<b>hello</b> :grinning:"))
        XCTAssertTrue(page.messages.allSatisfy { $0.body.unicodeScalars.allSatisfy(\.isASCII) })
        XCTAssertEqual(page.messages[1].body, "[Message edited]")
        XCTAssertEqual(page.messages[2].body, "[Link preview omitted]")
        XCTAssertEqual(page.messages[3].body, "[Attachment omitted]")
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.next, "b2xk")
    }

    func testEphemeralAndRevokedContentIsNeverRetained() throws {
        var ephemeral = rawMessage(id: 1)
        var first = ephemeral["msg"] as! [String: Any]
        first["is_ephemeral"] = true
        ephemeral["msg"] = first
        var revoked = rawMessage(id: 2)
        var second = revoked["msg"] as! [String: Any]
        second["revoked_device"] = true
        revoked["msg"] = second
        let page = try ChatDecoder.page(from: ["messages": [ephemeral, revoked]], conversationID: testConversationID)
        XCTAssertEqual(page.messages.map(\.body), ["[Disappearing message omitted]", "[Message from a revoked device hidden]"])
    }

    func testCrossConversationAndMalformedIDsFailClosed() throws {
        XCTAssertThrowsError(try ChatDecoder.page(from: ["messages": [rawMessage(id: 1)]], conversationID: String(repeating: "b", count: 64)))
        var value = rawMessage(id: 1)
        var inner = value["msg"] as! [String: Any]
        inner["id"] = true
        value["msg"] = inner
        XCTAssertThrowsError(try ChatDecoder.page(from: ["messages": [value]], conversationID: testConversationID))
        XCTAssertThrowsError(try ChatDecoder.page(from: ["messages": [rawMessage(id: 1), rawMessage(id: 1)]], conversationID: testConversationID))
    }

    func testReadUsesPeekAndBoundedPagination() async throws {
        let commands = try FakeCommands([listResult([conversation()]), ["messages": [], "pagination": ["last": true]]])
        _ = try await client(commands).read(conversationID: testConversationID, next: "b2xk")
        let requests = try await commands.requests()
        XCTAssertEqual(requests[1]["method"] as? String, "read")
        let options = (requests[1]["params"] as! [String: Any])["options"] as! [String: Any]
        XCTAssertEqual(options["peek"] as? Bool, true)
        XCTAssertEqual(options["fail_offline"] as? Bool, true)
        let pagination = options["pagination"] as! [String: Any]
        XCTAssertEqual(pagination["num"] as? Int, 100)
        XCTAssertEqual(pagination["next"] as? String, "b2xk")
        let args = await commands.recordedArguments()
        XCTAssertEqual(args[1], KeybaseClient.arguments + ["chat", "api"])
    }

    func testSendDisablesAndVerifiesPreviewsAndNormalizesEmoji() async throws {
        let commands = try FakeCommands([listResult([conversation()]), ["mode": "always"], true,
                                        ["mode": "never"], ["id": 7, "message": "message sent"]])
        try await client(commands).send(conversationID: testConversationID, body: "hello 😀")
        let methods = try await commands.methods()
        XCTAssertEqual(methods, ["list", "getunfurlsettings", "setunfurlsettings", "getunfurlsettings", "send"])
        let requests = try await commands.requests()
        let options = (requests.last!["params"] as! [String: Any])["options"] as! [String: Any]
        XCTAssertEqual((options["message"] as! [String: Any])["body"] as? String, "hello :grinning:")
        XCTAssertEqual(options["confirm_lumen_send"] as? Bool, false)
        XCTAssertEqual(options["nonblock"] as? Bool, false)
    }

    func testSendBlockedIfPreviewSettingDoesNotStick() async throws {
        let commands = try FakeCommands([listResult([conversation()]), ["mode": "always"], true, ["mode": "always"]])
        do {
            try await client(commands).send(conversationID: testConversationID, body: "hello")
            XCTFail("Unsafe send was accepted")
        } catch { XCTAssertEqual(error as? KeybaseClientError, .previewsNotDisabled) }
        let methods = try await commands.methods()
        XCTAssertFalse(methods.contains("send"))
    }

    func testSlashCommandsAndUnicodeAreRejectedBeforeAnyProcess() async throws {
        for text in ["/giphy dogs", " \n/flip", "hello 中文", ":custom-emoji:", ":smile#2:", ":SMILE:"] {
            let commands = try FakeCommands([])
            do { try await client(commands).send(conversationID: testConversationID, body: text); XCTFail("Unsafe body accepted") }
            catch { }
            let methods = try await commands.methods()
            XCTAssertTrue(methods.isEmpty)
        }
    }

    func testSendIdentityFailureStopsBeforeMutation() async throws {
        let commands = try FakeCommands([["identify_failures": [["username": "alice"]], "conversations": [conversation()]]])
        do { try await client(commands).send(conversationID: testConversationID, body: "hello"); XCTFail("Unsafe identity accepted") }
        catch { XCTAssertEqual(error as? KeybaseClientError, .identityFailure) }
        let methods = try await commands.methods()
        XCTAssertEqual(methods, ["list"])
    }

    func testNeverModeAutomaticPreviewExceptionsBlockedBeforeService() async throws {
        for body in ["https://media.giphy.com/media/id/giphy.gif", "https://GIPHY.COM/test", "https://keybasemaps/path",
                     "https://%67iphy.com/test", "https://giphy%2ecom/test"] {
            let commands = try FakeCommands([])
            do { try await client(commands).send(conversationID: testConversationID, body: body); XCTFail("Automatic preview accepted") }
            catch { XCTAssertEqual(error as? KeybaseClientError, .automaticPreviewNotAllowed) }
            let methods = try await commands.methods()
            XCTAssertTrue(methods.isEmpty)
        }
    }

    func testExistingTeamChannelJoinedByIDWithoutCreation() async throws {
        let item = conversation(name: "example", topic: "general", members: "team")
        let commands = try FakeCommands([listResult([item]), [String: Any]()])
        let value = try await client(commands).openTeam(name: "example", channel: "general")
        XCTAssertEqual(value.displayName, "example #general")
        let methods = try await commands.methods()
        XCTAssertEqual(methods, ["listconvsonname", "join"])
    }

    func testMissingTeamChannelNeverCreated() async throws {
        let commands = try FakeCommands([listResult([])])
        do { _ = try await client(commands).openTeam(name: "example", channel: "new-channel"); XCTFail("Missing channel created") }
        catch { XCTAssertEqual(error as? KeybaseClientError, .channelNotFound) }
        let methods = try await commands.methods()
        XCTAssertEqual(methods, ["listconvsonname"])
    }

    func testUnicodeRecipientsRejectedBeforeCaseFoldingOrServiceCalls() async throws {
        let commands = try FakeCommands([])
        let client = client(commands)
        do { _ = try await client.openDirect(usernames: "\u{212a}atie"); XCTFail("Unicode username was case-folded") }
        catch { XCTAssertEqual(error as? KeybaseClientError, .invalidRecipients) }
        do { _ = try await client.openTeam(name: "\u{212a}eybase", channel: "general"); XCTFail("Unicode team was case-folded") }
        catch { XCTAssertEqual(error as? KeybaseClientError, .invalidChannel) }
        do { _ = try await client.openTeam(name: "keybase", channel: "\u{212a}eys"); XCTFail("Unicode channel was case-folded") }
        catch { XCTAssertEqual(error as? KeybaseClientError, .invalidChannel) }
        let methods = try await commands.methods()
        XCTAssertTrue(methods.isEmpty)
    }
}
