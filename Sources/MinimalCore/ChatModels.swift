import Foundation
import CoreFoundation

public struct Conversation: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let topic: String
    public let isTeam: Bool
    public let unread: Bool
    public let lastMessageAt: Date?

    public var displayName: String { isTeam ? "\(name) #\(topic)" : name }

    public init(id: String, name: String, topic: String, isTeam: Bool, unread: Bool, lastMessageAt: Date? = nil) {
        self.id = id
        self.name = ASCIIText.sanitize(name)
        self.topic = ASCIIText.sanitize(topic)
        self.isTeam = isTeam
        self.unread = unread
        self.lastMessageAt = lastMessageAt
    }

    public static func mostRecentFirst(_ lhs: Conversation, _ rhs: Conversation) -> Bool {
        switch (lhs.lastMessageAt, rhs.lastMessageAt) {
        case let (left?, right?) where left != right: return left > right
        case (_?, nil): return true
        case (nil, _?): return false
        default: return lhs.id < rhs.id
        }
    }
}

public struct Message: Identifiable, Equatable, Sendable {
    public let id: String
    public let sender: String
    public let body: String
    public let timestamp: Date?
    public let isNotice: Bool

    public init(id: String, sender: String, body: String, timestamp: Date?, isNotice: Bool) {
        self.id = id
        self.sender = ASCIIText.sanitize(sender)
        self.body = ASCIIText.sanitize(body)
        self.timestamp = timestamp
        self.isNotice = isNotice
    }
}

public struct MessagePage: Equatable, Sendable {
    public let messages: [Message]
    public let next: String?
    public let hasMore: Bool

    public init(messages: [Message], next: String?, hasMore: Bool) {
        self.messages = messages
        self.next = next
        self.hasMore = hasMore
    }
}

public enum KeybaseClientError: LocalizedError, Equatable {
    case invalidReply
    case service(String)
    case identityFailure
    case invalidConversation
    case invalidRecipients
    case invalidChannel
    case channelNotFound
    case previewsNotDisabled
    case commandNotAllowed
    case customEmojiNotAllowed
    case automaticPreviewNotAllowed
    case offline

    public var errorDescription: String? {
        switch self {
        case .invalidReply: return "Keybase returned an unexpected response. Update the official Keybase app and reconnect."
        case .service(let message): return "Keybase: " + ASCIIText.sanitize(String(message.prefix(500)))
        case .identityFailure: return "Keybase reported an identity verification failure. Resolve it with the official Keybase tools before continuing."
        case .invalidConversation: return "This conversation is unavailable or is not a private text chat."
        case .invalidRecipients: return "Enter Keybase usernames separated by commas (letters, numbers, and underscores only)."
        case .invalidChannel: return "Enter an ASCII team and channel name using letters, numbers, underscores, hyphens, and team dots."
        case .channelNotFound: return "That team channel was not found. Enter an existing team and channel that your account can access."
        case .previewsNotDisabled: return "Sending is blocked because Keybase link previews could not be disabled."
        case .commandNotAllowed: return "Slash commands are disabled because Keybase can interpret them as actions."
        case .customEmojiNotAllowed: return "Only built-in emoji shortcodes are supported. This colon-delimited text could make Keybase load custom media."
        case .automaticPreviewNotAllowed: return "Keybase always previews Giphy and Keybase maps links, even when previews are disabled. Those domains are blocked."
        case .offline: return "The Keybase service is offline. Reconnect before loading or sending messages."
        }
    }
}

/// A deliberately small projection of the official chat JSON API. Media metadata,
/// reactions, HTML, URLs, payment objects, and custom emoji payloads are never decoded.
enum ChatDecoder {
    static let maximumReplyBytes = 8 * 1024 * 1024
    static let maximumMessages = 500

    static func result(from data: Data) throws -> Any {
        guard data.count <= maximumReplyBytes,
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw KeybaseClientError.invalidReply }
        if let error = envelope["error"], !(error is NSNull) {
            let message = (error as? [String: Any])?["message"] as? String
            throw KeybaseClientError.service(message ?? "The command failed.")
        }
        guard let result = envelope["result"], !(result is NSNull) else {
            throw KeybaseClientError.invalidReply
        }
        if let dictionary = result as? [String: Any] {
            if let failures = dictionary["identify_failures"], !(failures is NSNull) {
                guard let array = failures as? [Any] else { throw KeybaseClientError.invalidReply }
                guard array.isEmpty else { throw KeybaseClientError.identityFailure }
            }
            if dictionary["offline"] as? Bool == true { throw KeybaseClientError.offline }
        }
        return result
    }

    static func validConversationID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func validPageToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 4096 && Data(base64Encoded: token) != nil
    }

    static func privateChat(_ channel: [String: Any]) -> Bool {
        (channel["public"] == nil || channel["public"] as? Bool == false) &&
        (channel["topic_type"] as? String)?.lowercased() == "chat" &&
        ["team", "impteamnative", "impteamupgrade", "kbfs"].contains(
            (channel["members_type"] as? String)?.lowercased() ?? "")
    }

    static func conversations(from result: Any) throws -> [Conversation] {
        guard let dictionary = result as? [String: Any] else { throw KeybaseClientError.invalidReply }
        if dictionary["conversations"] is NSNull { return [] }
        guard let raw = dictionary["conversations"] as? [[String: Any]], raw.count <= 20_000 else {
            throw KeybaseClientError.invalidReply
        }
        var seen = Set<String>()
        return try raw.compactMap { item in
            guard let channel = item["channel"] as? [String: Any] else { throw KeybaseClientError.invalidReply }
            guard privateChat(channel), (item["error"] as? String ?? "").isEmpty else { return nil }
            // Finalized conversations have a successor; do not offer their old identity set for sending.
            if let successors = item["superseded_by"] as? [Any], !successors.isEmpty { return nil }
            guard let id = item["id"] as? String, validConversationID(id),
                  let name = channel["name"] as? String, name.utf8.count <= 4096,
                  let unread = item["unread"] as? Bool else { throw KeybaseClientError.invalidReply }
            guard seen.insert(id).inserted else { throw KeybaseClientError.invalidReply }
            // Official ConvSummary exports inbox message activity as Unix
            // milliseconds and seconds. Keep subsecond ordering when available.
            let lastMessageAt: Date?
            if let milliseconds = item["active_at_ms"] {
                lastMessageAt = try conversationDate(milliseconds, unitsPerSecond: 1_000)
            } else if let seconds = item["active_at"] {
                lastMessageAt = try conversationDate(seconds, unitsPerSecond: 1)
            } else {
                lastMessageAt = nil
            }
            return Conversation(id: id, name: name, topic: channel["topic_name"] as? String ?? "",
                                isTeam: channel["members_type"] as? String == "team", unread: unread,
                                lastMessageAt: lastMessageAt)
        }
    }

    private static func conversationDate(_ raw: Any, unitsPerSecond: Double) throws -> Date {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue >= 0,
              value.doubleValue.rounded(.towardZero) == value.doubleValue,
              value.doubleValue / unitsPerSecond < 253_402_300_800 else {
            throw KeybaseClientError.invalidReply
        }
        return Date(timeIntervalSince1970: value.doubleValue / unitsPerSecond)
    }

    static func messageID(_ raw: Any?) -> UInt32? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue > 0, value.doubleValue <= Double(UInt32.max),
              value.doubleValue.rounded(.towardZero) == value.doubleValue else { return nil }
        return value.uint32Value
    }

    static func page(from result: Any, conversationID: String) throws -> MessagePage {
        guard let dictionary = result as? [String: Any],
              let raw = dictionary["messages"] as? [[String: Any]], raw.count <= maximumMessages else {
            throw KeybaseClientError.invalidReply
        }
        var seen = Set<UInt32>()
        var messages: [Message] = []
        for (index, wrapper) in raw.enumerated() {
            if wrapper["error"] != nil {
                messages.append(Message(id: "error-\(index)", sender: "system", body: "[Message could not be verified or decrypted]", timestamp: nil, isNotice: true))
                continue
            }
            guard let item = wrapper["msg"] as? [String: Any],
                  let id = messageID(item["id"]), seen.insert(id).inserted,
                  item["conversation_id"] as? String == conversationID,
                  let channel = item["channel"] as? [String: Any], privateChat(channel),
                  let content = item["content"] as? [String: Any], let kind = content["type"] as? String else {
                throw KeybaseClientError.invalidReply
            }
            let sender = (item["sender"] as? [String: Any])?["username"] as? String ?? "unknown"
            var timestamp: Date?
            if let seconds = item["sent_at"] as? NSNumber,
               seconds.doubleValue >= 0, seconds.doubleValue <= 253_402_300_799 {
                timestamp = Date(timeIntervalSince1970: seconds.doubleValue)
            }
            let body: String
            let notice: Bool
            if item["is_ephemeral"] as? Bool == true || item["is_ephemeral_expired"] as? Bool == true {
                // Do not keep an expiring plaintext beyond its lifetime between refreshes.
                body = "[Disappearing message omitted]"; notice = true
            } else if item["revoked_device"] as? Bool == true {
                body = "[Message from a revoked device hidden]"; notice = true
            } else {
                switch kind {
                case "text":
                    guard let text = content["text"] as? [String: Any], let value = text["body"] as? String else {
                        throw KeybaseClientError.invalidReply
                    }
                    body = value; notice = false
                case "edit":
                    // The official service applies edits to their original text. Do not show an
                    // unaffiliated edit payload as a second message or resurrect removed text.
                    body = "[Message edited]"; notice = true
                case "delete", "deletehistory": body = "[Message deleted]"; notice = true
                case "system", "join", "leave", "metadata", "headline": body = "[Conversation updated]"; notice = true
                case "attachment", "attachmentuploaded": body = "[Attachment omitted]"; notice = true
                case "unfurl": body = "[Link preview omitted]"; notice = true
                case "reaction": body = "[Reaction omitted]"; notice = true
                case "sendpayment", "requestpayment": body = "[Payment content omitted]"; notice = true
                default: body = "[Unsupported message omitted]"; notice = true
                }
            }
            messages.append(Message(id: String(id), sender: sender, body: body, timestamp: timestamp, isNotice: notice))
        }
        messages.sort { (UInt32($0.id) ?? 0) < (UInt32($1.id) ?? 0) }
        var next: String?
        var hasMore = false
        if let pagination = dictionary["pagination"] as? [String: Any] {
            // Official Go JSON omits Last when false. A present value must be
            // a JSON Boolean; NSNumber's Bool bridge also accepts numeric 0/1.
            var last = false
            if let rawLast = pagination["last"] {
                guard let value = rawLast as? NSNumber,
                      CFGetTypeID(value) == CFBooleanGetTypeID() else {
                    throw KeybaseClientError.invalidReply
                }
                last = value.boolValue
            }
            if let token = pagination["next"] as? String, !token.isEmpty {
                guard validPageToken(token) else { throw KeybaseClientError.invalidReply }
                next = token
            }
            hasMore = !last && next != nil
        }
        return MessagePage(messages: messages, next: next, hasMore: hasMore)
    }
}
