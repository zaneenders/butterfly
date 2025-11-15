import Foundation
import NIOWebSocket

extension WebSocketSystem {

  public enum Mode: Sendable {
    case server
    case client
  }

  public enum Config {
    case client(ClientConfig)
    case server(ServerConfig)
  }

  struct AwaitingInbound {
    let id: UUID
    let continuation: MailboxPayload
  }
}
