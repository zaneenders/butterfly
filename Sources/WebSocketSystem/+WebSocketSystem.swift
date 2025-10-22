import Foundation
import NIOWebSocket

extension WebSocketSystem {

    public enum Mode: Sendable {
        case server
        case client
    }

    public enum Config {
        case client(host: String, port: Int, uri: String)
        case server(host: String, port: Int, uri: String)
    }

    struct AwaitingInbound {
        let id: UUID
        let continuation: MailboxPayload
    }
}
