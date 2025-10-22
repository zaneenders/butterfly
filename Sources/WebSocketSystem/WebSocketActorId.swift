import Foundation

public struct WebSocketActorId: Sendable, Codable, Hashable {
    public let uuid: UUID
    public let address: Address

    public var host: String { address.host }
    public var port: Int { address.port }

    public init(host: String, port: Int) {
        self.uuid = UUID()
        let normalizedHost = host == "localhost" ? "::1" : host
        self.address = Address(host: normalizedHost, port: port)
    }
}

extension WebSocketActorId: CustomDebugStringConvertible {
    public var debugDescription: String {
        "ActorId[\(address.host):\(address.port) \(uuid)]"
    }
}

public struct Address: Sendable, Codable, Hashable {
    public let host: String
    public let port: Int
}
