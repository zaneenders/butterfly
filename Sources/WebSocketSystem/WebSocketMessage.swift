import Foundation

struct WebSocketMessage: Codable, Sendable {
  let messageID: UUID
  let actorID: WebSocketActorId
  let target: String
  let genericSubstitutions: [String]
  let arguments: [Data]
  let returnTypeName: String?
  let throwingTypeName: String?
}
