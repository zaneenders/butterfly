import Logging
import NIOCore

extension SocketAddress? {
  func getID(_ logger: Logger?) throws -> WebSocketActorId {
    guard let address = self else {
      logger?.error("no remote address?")
      throw WebSocketSystemError.message("no remote address?")
    }
    guard let ip = address.ipAddress, let p = address.port else {
      logger?.error("Client failed to connect with no IP address.")
      throw WebSocketSystemError.message("Client failed to connect with no IP address.")
    }
    return WebSocketActorId(host: ip, port: p)
  }
}
