import Distributed
import Foundation
import Logging
import NIOWebSocket

extension WebSocketSystem {

    public struct CallDecoder: DistributedTargetInvocationDecoder {
        public typealias SerializationRequirement = Sendable & Codable

        let logger: Logger
        let message: WebSocketMessage
        let decoder: JSONDecoder
        var argumentsIterator: Array<Data>.Iterator

        init(message: WebSocketMessage, decoder: JSONDecoder, logLevel: Logger.Level) {
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
}
