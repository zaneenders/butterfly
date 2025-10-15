import Distributed
import Foundation
import Logging
import NIOCore
import NIOWebSocket

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
        case server
        case client
    }
    let mode: Mode
    let server: NIOAsyncChannel<EventLoopFuture<ServerUpgradeResult>, Never>?
    let client: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>?

    enum Config {
        case client(host: String, port: Int, uri: String)
        case server(host: String, port: Int, uri: String)
    }
    init(_ mode: Config) async throws {  // TODO: sync start up?
        self.logger = .create(label: "WebSocketSystem[\(mode)]", logLevel: .trace)
        switch mode {
        case .server(let host, let port, _):
            self.server = try await boot(host: host, port: port)
            self.client = nil
            self.mode = .server
        case .client(let host, let port, let uri):
            self.server = nil
            let r = try await connect(host: host, port: port, uri: uri)
            switch r {
            case .notUpgraded:
                throw WSClientError.notUpgraded
            case .websocket(let channel):
                self.client = channel
            }
            self.mode = .client
        }
        switch self.mode {
        case .server:
            Task {
                try await withThrowingDiscardingTaskGroup { group in
                    try await server!.executeThenClose { inbound in
                        for try await upgradeResult in inbound {
                            group.addTask {
                                let connection = try await upgradeResult.get()
                                switch connection {
                                case .notUpgraded:
                                    print("not upgraded")
                                    return
                                case .websocket(let wsChannel):
                                    guard let address = wsChannel.channel.remoteAddress else {
                                        print("no remote address?")
                                        return
                                    }
                                    print(address)
                                    try await wsChannel.executeThenClose { inbound, outbound in
                                        try await withThrowingTaskGroup(of: Void.self) { group in
                                            group.addTask {
                                                for try await frame in inbound {
                                                    switch frame.opcode {
                                                    case .ping:
                                                        print("Received ping")
                                                        var frameData = frame.data
                                                        let maskingKey = frame.maskKey

                                                        if let maskingKey = maskingKey {
                                                            frameData.webSocketUnmask(maskingKey)
                                                        }

                                                        let responseFrame = WebSocketFrame(
                                                            fin: true, opcode: .pong,
                                                            data: frameData)
                                                        try await outbound.write(responseFrame)
                                                    case .connectionClose:
                                                        print("Received close")
                                                        var data = frame.unmaskedData
                                                        let closeDataCode =
                                                            data.readSlice(length: 2)
                                                            ?? ByteBuffer()
                                                        let closeFrame = WebSocketFrame(
                                                            fin: true, opcode: .connectionClose,
                                                            data: closeDataCode)
                                                        try await outbound.write(closeFrame)
                                                        return
                                                    case .binary, .continuation, .pong:
                                                        break
                                                    default:
                                                        return
                                                    }
                                                }
                                            }

                                            group.addTask {
                                                while true {
                                                    let theTime = ContinuousClock().now
                                                    var buffer = wsChannel.channel.allocator.buffer(
                                                        capacity: 12)
                                                    buffer.writeString("\(theTime)")

                                                    let frame = WebSocketFrame(
                                                        fin: true, opcode: .text, data: buffer)

                                                    print("Sending time")
                                                    try await outbound.write(frame)
                                                    try await Task.sleep(for: .seconds(1))
                                                }
                                            }

                                            try await group.next()
                                            group.cancelAll()
                                        }
                                    }
                                }
                            }
                        }
                        print("Server shutting down")
                    }
                }
            }
        case .client:
            Task {
                let pingFrame = WebSocketFrame(
                    fin: true, opcode: .ping, data: ByteBuffer(string: "Hello!"))
                try await client!.executeThenClose { inbound, outbound in
                    try await outbound.write(pingFrame)
                    for try await frame in inbound {
                        switch frame.opcode {
                        case .pong:
                            print("Received pong: \(String(buffer: frame.data))")
                        case .text:
                            print("Received: \(String(buffer: frame.data))")
                        case .connectionClose:
                            // Handle a received close frame. We're just going to close by returning from this method.
                            print("Received Close instruction from server")
                            return
                        case .binary, .continuation, .ping:
                            // We ignore these frames.
                            break
                        default:
                            // Unknown frames are errors.
                            return
                        }
                    }
                }
            }
        }
    }

    func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
    where Act: DistributedActor, ActorID == Act.ID {
        logger.trace(#function)
        throw WebSocketSystemError.message(#function)
    }

    func assignID<Act>(_ actorType: Act.Type) -> ActorID
    where Act: DistributedActor, ActorID == Act.ID {
        logger.trace(#function)
        return WebSocketActorId(host: "localhost", port: 42069)
    }

    func actorReady<Act>(_ actor: Act) where Act: DistributedActor, ActorID == Act.ID {
        logger.trace(#function)
    }

    func resignID(_ id: ActorID) {
        logger.trace(#function)
    }

    func makeInvocationEncoder() -> InvocationEncoder {
        logger.trace(#function)
        return CallEncoder(actorSystem: self, logLevel: logger.logLevel)
    }

    func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type
    ) async throws where Act: DistributedActor, Err: Error, WebSocketActorId == Act.ID {
        logger.trace(#function)
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
        logger.trace(#function)
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
