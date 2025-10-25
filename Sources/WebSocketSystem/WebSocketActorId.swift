public struct WebSocketActorId: Hashable, Codable, Sendable {
  public let host: String
  public let port: Int

  public init(host: String, port: Int) {
    self.host = host
    self.port = port
  }
}
