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

    struct OutgoingMessage {
        let id: UUID
        let frame: WebSocketFrame
        let continuation: MailboxPayload
    }

    struct AwaitingInbound {
        let id: UUID
        let continuation: MailboxPayload
    }
}
