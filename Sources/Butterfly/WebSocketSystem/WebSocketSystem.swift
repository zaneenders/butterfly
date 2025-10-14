import Distributed
import Foundation
import Logging

struct WebSocketActorId: Sendable, Codable, Hashable {
    let host: String
    let port: Int
}

final class WebSocketSystem: DistributedActorSystem, Sendable {
    typealias ActorID = WebSocketActorId
    typealias InvocationEncoder = CallEncoder
    typealias InvocationDecoder = CallDecoder
    typealias ResultHandler = Handler
    typealias SerializationRequirement = Codable & Sendable
    let logger: Logger

    enum Mode {
        case client
        case server
    }

    init(_ mode: Mode) {
        self.logger = .create(label: "WebSocketSystem[\(mode)]", logLevel: .trace)
    }

    func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
    where Act: DistributedActor, ActorID == Act.ID {
        throw WebSocketSystemError.message(#function)
    }

    func assignID<Act>(_ actorType: Act.Type) -> ActorID
    where Act: DistributedActor, ActorID == Act.ID {
        WebSocketActorId(host: "localhost", port: 42069)
    }

    func actorReady<Act>(_ actor: Act) where Act: DistributedActor, ActorID == Act.ID {

    }

    func resignID(_ id: ActorID) {

    }

    func makeInvocationEncoder() -> InvocationEncoder {
        CallEncoder(actorSystem: self, logLevel: logger.logLevel)
    }

    func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type
    ) async throws where Act: DistributedActor, Err: Error, WebSocketActorId == Act.ID {

    }

    public func remoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws -> Res
    where
        Act: DistributedActor, Act.ID == WebSocketActorId, Err: Error, Res: SerializationRequirement
    {
        throw WebSocketSystemError.message(#function)
    }
}

extension WebSocketSystem {

    struct CallEncoder: DistributedTargetInvocationEncoder {

        typealias SerializationRequirement = Sendable & Codable

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
            logger.trace(#function)
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

    public struct CallDecoder: DistributedTargetInvocationDecoder {
        public typealias SerializationRequirement = Sendable & Codable

        let logger: Logger
        let message: NetworkMessage
        let decoder: JSONDecoder
        var argumentsIterator: Array<Data>.Iterator

        init(message: NetworkMessage, decoder: JSONDecoder, logLevel: Logger.Level) {
            self.logger = Logger.create(label: "CallDecoder", logLevel: logLevel)
            self.message = message
            self.decoder = decoder
            self.argumentsIterator = message.arguments.makeIterator()
        }

        public mutating func decodeGenericSubstitutions() throws -> [any Any.Type] {
            logger.trace(#function)
            return message.genericSubstitutions.compactMap { name in
                _typeByName(name)
            }
        }

        public mutating func decodeErrorType() throws -> (any Any.Type)? {
            if let r = message.throwingTypeName {
                logger.trace("\(#function) \(r)")
                return _typeByName(r)
            } else {
                logger.error(#function)
                return nil
            }
        }

        public mutating func decodeReturnType() throws -> (any Any.Type)? {
            if let r = message.returnTypeName {
                logger.trace("\(#function) \(r)")
                return _typeByName(r)
            } else {
                logger.trace("\(#function) nil")
                return nil
            }
        }

        public mutating func decodeNextArgument<Argument: SerializationRequirement>() throws
            -> Argument
        {
            guard let data = argumentsIterator.next() else {
                logger.error(#function)
                throw WebSocketSystemError.message("out of arguments")
            }
            do {
                let value = try decoder.decode(Argument.self, from: data)
                logger.trace("\(#function) \(value)")
                return value
            } catch {
                logger.error("\(#function) \(error)")
                throw error
            }
        }
    }

    public struct Handler: DistributedTargetInvocationResultHandler {
        public typealias SerializationRequirement = Sendable & Codable

        let logger: Logger

        init(
            logLevel: Logger.Level
        ) {
            self.logger = Logger.create(label: "Handler", logLevel: logLevel)
        }

        public func onReturn<Success: SerializationRequirement>(value: Success) async throws {
            logger.trace("\(#function)")
        }

        public func onReturnVoid() async throws {
            logger.trace("\(#function)")
            return
        }

        public func onThrow<Err>(error: Err) async throws where Err: Error {
            logger.trace("\(#function)")
        }
    }
}

enum WebSocketSystemError: Error {
    case message(String)
}

struct WebSocketMessage: Codable, Sendable {
    let actorID: WebSocketActorId
    let target: String
    let genericSubstitutions: [String]
    let arguments: [Data]
    let returnTypeName: String?
    let throwingTypeName: String?
}
