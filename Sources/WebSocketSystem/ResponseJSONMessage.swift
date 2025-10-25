import Foundation

struct ResponseJSONMessage: Codable, Sendable {
  let id: UUID
  let json: String
}
