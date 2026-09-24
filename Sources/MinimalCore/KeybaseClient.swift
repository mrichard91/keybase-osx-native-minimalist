import Foundation

/// Retains official Keybase identity, key custody, encryption, and provisioning.
/// This adapter accepts only private chat operations and a bounded JSON response.
public actor KeybaseClient {
    public typealias CommandRunner = @Sendable (URL, [String], Data?, TimeInterval, Int) async throws -> ProcessOutput
    private let executable: URL
    private let runner: CommandRunner
    private let bundledBackend: Bool
    private var knownConversations: [String: Conversation] = [:]
    public static let arguments = ["--no-auto-fork", "--no-debug", "--app-start-mode", "minimalist"]

    public init(executable: URL) {
        self.executable = executable
        self.bundledBackend = KeybaseExecutable.isBundled(executable)
        self.runner = { executable, arguments, input, timeout, limit in
            try KeybaseExecutable.validate(executable)
            return try await ProcessRunner.run(executable: executable, arguments: arguments, input: input,
                                               timeout: timeout, outputLimit: limit)
        }
    }

    /// Test seam: production callers always use the signature-verifying initializer.
    init(executable: URL, bundledBackend: Bool = false, runner: @escaping CommandRunner) {
        self.executable = executable
        self.runner = runner
        self.bundledBackend = bundledBackend
    }

    public func account() async throws -> String {
        let output = try await runner(executable, Self.arguments + ["whoami"], nil, 15, 64 * 1024)
        try successful(output)
        guard let raw = String(data: output.stdout, encoding: .utf8), raw.utf8.allSatisfy({ $0 < 128 }) else {
            throw KeybaseClientError.invalidReply
        }
        let username = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validUsername(username) else { throw KeybaseClientError.invalidReply }
        return username
    }

    /// The bundled backend fixes previews off without changing account settings.
    /// Compatibility mode changes the official shared preference. Check before sends.
    public func prepareSecurity() async throws {
        let settings = try await api("getunfurlsettings") as? [String: Any]
        guard let mode = settings?["mode"] as? String else { throw KeybaseClientError.invalidReply }
        if mode != "never" {
            guard !bundledBackend else { throw KeybaseClientError.previewsNotDisabled }
            guard let saved = try await api("setunfurlsettings", options: ["mode": "never", "whitelist": []]) as? Bool,
                  saved else { throw KeybaseClientError.previewsNotDisabled }
            let verified = try await api("getunfurlsettings") as? [String: Any]
            guard verified?["mode"] as? String == "never" else { throw KeybaseClientError.previewsNotDisabled }
        }
    }

    public func conversations() async throws -> [Conversation] {
        let result = try await api("list", options: ["topic_type": "CHAT", "fail_offline": true])
        let conversations = try ChatDecoder.conversations(from: result)
        knownConversations = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        return conversations
    }

    public func read(conversationID: String, next: String? = nil) async throws -> MessagePage {
        try validateConversationID(conversationID)
        if knownConversations[conversationID] == nil { _ = try await refreshConversation(conversationID) }
        var pagination: [String: Any] = ["num": 100]
        if let next {
            guard ChatDecoder.validPageToken(next) else { throw KeybaseClientError.invalidReply }
            pagination["next"] = next
        }
        let result = try await api("read", options: ["conversation_id": conversationID, "pagination": pagination,
                                                   "peek": true, "fail_offline": true])
        return try ChatDecoder.page(from: result, conversationID: conversationID)
    }

    public func markRead(conversationID: String, messageID: String) async throws {
        try validateConversationID(conversationID)
        guard knownConversations[conversationID] != nil,
              let id = UInt32(messageID), id > 0 else { throw KeybaseClientError.invalidConversation }
        _ = try await api("mark", options: ["conversation_id": conversationID, "message_id": id])
    }

    public func send(conversationID: String, body: String) async throws {
        try validateConversationID(conversationID)
        let plainBody = try ASCIIText.validateOutgoing(body)
        // The bundled service treats these strings literally. The full official
        // service performs optional actions while sending, so compatibility needs
        // the extra conservative text restrictions below.
        if !bundledBackend {
            guard !plainBody.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") else {
                throw KeybaseClientError.commandNotAllowed
            }
            // Official NEVER mode still auto-whitelists these domains, including
            // giphy.com subdomains. Reject the domain text conservatively, including
            // percent encodings, instead of maintaining a second URL parser.
            var domainText = plainBody.lowercased()
            for _ in 0..<3 {
                if domainText.contains("giphy.com") || domainText.contains("keybasemaps") {
                    throw KeybaseClientError.automaticPreviewNotAllowed
                }
                guard let decoded = domainText.removingPercentEncoding, decoded != domainText else { break }
                domainText = decoded.lowercased()
            }
            // Official EmojiSource.Harvest scans this grammar, even for a text send,
            // and can download/re-upload custom emoji. Stock names cannot be shadowed
            // without a # suffix. Reject every other match before invoking the service.
            let emojiPattern = try NSRegularExpression(pattern: ":([^:\\s]+):")
            let range = NSRange(plainBody.startIndex..<plainBody.endIndex, in: plainBody)
            for match in emojiPattern.matches(in: plainBody, range: range) {
                guard let matchedRange = Range(match.range, in: plainBody),
                      ASCIIText.isKnownEmojiShortcode(String(plainBody[matchedRange])) else {
                    throw KeybaseClientError.customEmojiNotAllowed
                }
            }
        }
        _ = try await refreshConversation(conversationID)
        try await prepareSecurity()
        // Explicit false prevents the CLI ChatUI from approving inline Stellar payments.
        let result = try await api("send", options: ["conversation_id": conversationID,
                                                     "message": ["body": plainBody], "nonblock": false,
                                                     "confirm_lumen_send": false])
        guard let dictionary = result as? [String: Any], ChatDecoder.messageID(dictionary["id"]) != nil else {
            // Never retry automatically: a failed response can follow a successful send.
            throw KeybaseClientError.service("The send result could not be confirmed. Refresh the conversation before trying again.")
        }
    }

    public func openDirect(usernames: String) async throws -> Conversation {
        // Validate before case folding: Unicode characters such as Kelvin sign
        // can lowercase to ASCII and otherwise target an unintended account.
        guard usernames.utf8.count <= 4096, usernames.utf8.allSatisfy({ $0 < 128 }) else {
            throw KeybaseClientError.invalidRecipients
        }
        let users = usernames.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !users.isEmpty, users.count <= 20, users.allSatisfy(Self.validUsername),
              Set(users).count == users.count else { throw KeybaseClientError.invalidRecipients }
        let result = try await api("newconv", options: ["channel": ["name": users.joined(separator: ","),
                                    "public": false, "members_type": "impteamnative", "topic_type": "CHAT"]])
        guard let id = (result as? [String: Any])?["id"] as? String else { throw KeybaseClientError.invalidReply }
        return try await refreshConversation(id)
    }

    /// Only joins an existing channel. It never creates teams or channels.
    public func openTeam(name: String, channel: String) async throws -> Conversation {
        guard name.utf8.count <= 255, channel.utf8.count <= 255,
              name.utf8.allSatisfy({ $0 < 128 }), channel.utf8.allSatisfy({ $0 < 128 }) else {
            throw KeybaseClientError.invalidChannel
        }
        let team = name.trimmingCharacters(in: .whitespaces).lowercased()
        let topic = channel.trimmingCharacters(in: .whitespaces).lowercased()
        guard Self.validName(team, extra: "_."), Self.validName(topic, extra: "_-") else {
            throw KeybaseClientError.invalidChannel
        }
        let result = try await api("listconvsonname", options: ["name": team, "members_type": "team", "topic_type": "CHAT"])
        let matches = try ChatDecoder.conversations(from: result).filter {
            $0.isTeam && $0.name == team && $0.topic == topic
        }
        guard matches.count == 1, let conversation = matches.first else { throw KeybaseClientError.channelNotFound }
        _ = try await api("join", options: ["conversation_id": conversation.id])
        knownConversations[conversation.id] = conversation
        return conversation
    }

    private func refreshConversation(_ id: String) async throws -> Conversation {
        try validateConversationID(id)
        let result = try await api("list", options: ["conversation_id": id, "topic_type": "CHAT", "fail_offline": true])
        let list = try ChatDecoder.conversations(from: result)
        guard list.count == 1, let conversation = list.first, conversation.id == id else {
            knownConversations.removeValue(forKey: id)
            throw KeybaseClientError.invalidConversation
        }
        knownConversations[id] = conversation
        return conversation
    }

    private func validateConversationID(_ id: String) throws {
        guard ChatDecoder.validConversationID(id) else { throw KeybaseClientError.invalidConversation }
    }

    private static func validUsername(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (2...16).contains(bytes.count) && bytes.first.map { (97...122).contains($0) || (48...57).contains($0) } == true &&
            bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }

    private static func validName(_ value: String, extra: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || extra.utf8.contains($0)
        }
    }

    private func api(_ method: String, options: [String: Any]? = nil) async throws -> Any {
        var request: [String: Any] = ["method": method]
        if let options { request["params"] = ["options": options] }
        var input = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        input.append(10)
        let output = try await runner(executable, Self.arguments + ["chat", "api"], input, 45, ChatDecoder.maximumReplyBytes)
        try successful(output)
        return try ChatDecoder.result(from: output.stdout)
    }

    private func successful(_ output: ProcessOutput) throws {
        guard output.status == 0 else {
            // CLI stderr can contain account details; only the bounded sanitized error is shown.
            let detail = String(data: output.stderr.prefix(2048), encoding: .utf8) ?? "The Keybase service command failed."
            throw KeybaseClientError.service(detail.isEmpty ? "The Keybase service command failed." : detail)
        }
    }
}
