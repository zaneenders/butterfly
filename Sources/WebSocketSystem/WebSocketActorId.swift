import Foundation

public typealias EntityName = String

public struct WebSocketActorId: Sendable, Codable, Hashable {
  public let uuid: UUID
  public let entity: EntityAddress

  public var host: String { entity.address.host }
  public var port: Int { entity.address.port }

  public init(host: String, port: Int, name: EntityName) {
    self.uuid = UUID()
    self.entity = EntityAddress(host: host, port: port, name: name)
  }
}

extension WebSocketActorId: CustomDebugStringConvertible {
  public var debugDescription: String {
    "ActorID(\(entity.name))[\(entity.address.host):\(entity.address.port) \(uuid)]"
  }
}

public struct EntityAddress: Sendable, Codable, Hashable {
  public let name: String
  public let address: Address

  public init(host: String, port: Int, name: String) {
    self.name = name
    self.address = Address(host: host, port: port)
  }
}

public struct Address: Sendable, Codable, Hashable {
  public let host: String
  public let port: Int
}
