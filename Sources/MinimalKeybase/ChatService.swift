import MinimalCore

/// The UI depends on chat operations rather than process execution. The production
/// implementation always uses KeybaseClient; UI tests provide an in-memory actor.
protocol ChatService: Sendable {
    func account() async throws -> String
    func prepareSecurity() async throws
    func conversations() async throws -> [Conversation]
    func read(conversationID: String, next: String?) async throws -> MessagePage
    func markRead(conversationID: String, messageID: String) async throws
    func send(conversationID: String, body: String) async throws
    func openDirect(usernames: String) async throws -> Conversation
    func openTeam(name: String, channel: String) async throws -> Conversation
}

extension KeybaseClient: ChatService {}
