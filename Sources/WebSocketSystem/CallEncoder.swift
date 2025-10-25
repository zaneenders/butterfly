import Distributed
import Foundation
import Logging

extension WebSocketSystem {

  public struct CallEncoder: DistributedTargetInvocationEncoder {

    public typealias SerializationRequirement = Sendable & Codable

    private let logger: Logger
    private let actorSystem: WebSocketSystem
    private(set) var genericSubs: [String] = []
    private(set) var argumentData: [Data] = []
    private(set) var returnType: String?
    private(set) var throwType: String?

    init(actorSystem: WebSocketSystem, logLevel: Logger.Level) {
      self.logger = Logger.create(label: "CallEncoder", logLevel: logLevel)
      self.actorSystem = actorSystem
    }

    public mutating func recordArgument<Value: SerializationRequirement>(
      _ argument: RemoteCallArgument<Value>
    )
      throws
    {
      let data = try actorSystem.encoder.encode(argument.value)
      self.argumentData.append(data)
    }

    public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {
      logger.trace(#function)
      if let name = _mangledTypeName(type) {
        genericSubs.append(name)
      } else {
        logger.critical(#function)
        assert(false)
      }
    }

    public mutating func recordErrorType<E>(_ type: E.Type) throws where E: Error {
      logger.trace(#function)
      if let name = _mangledTypeName(type) {
        throwType = name
      } else {
        logger.critical(#function)
        assert(false)
      }
    }

    public mutating func recordReturnType<R: SerializationRequirement>(_ type: R.Type) throws {
      logger.trace(#function)
      if let name = _mangledTypeName(type) {
        returnType = name
      } else {
        logger.critical(#function)
        assert(false)
      }
    }

    public mutating func doneRecording() throws {
      logger.trace(#function)
    }
  }
}
