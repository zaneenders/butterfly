public struct WebSocketActorId: Sendable, Codable, Hashable {
    public init(host: String, port: Int) {
        if host == "localhost" {
            // TODO: support ipv4 or don't encode localhost
            self.host = "::1"
        } else {
            self.host = host
        }
        self.port = port
    }
    public let host: String
    public let port: Int
}

extension WebSocketActorId: CustomDebugStringConvertible {
    public var debugDescription: String {
        "ActorId[\(host):\(port)]"
    }
}
