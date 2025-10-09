import Distributed
import FoundationEssentials
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import Synchronization

public typealias ButterflyMessage = Sendable & Codable

public final class ButterflyActorSystem: DistributedActorSystem, Sendable {

    public typealias ActorID = ButterflyId
    public typealias InvocationEncoder = CallEncoder
    public typealias InvocationDecoder = CallDecoder
    public typealias ResultHandler = Handler
    public typealias SerializationRequirement = ButterflyMessage

    public let host: String
    public let port: Int
    private let server: NIOAsyncChannel<NIOAsyncChannel<ButterflyCommand, ButterflyCommand>, Never>

    private let logger: Logger

    private let lockedActors: Mutex<[ButterflyId: any DistributedActor]> = Mutex([:])

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(host: String, port: Int, logLevel: Logger.Level = .error) async throws {
        self.host = host
        self.port = port
        self.logger = Logger.create(
            label: "ButterflyActorSystem[\(host):\(port)]", logLevel: logLevel)
        self.logger.trace("\(GitInfo.commitHash)")
        self.server = try await Self.bootstrap(host: host, port: port, logger)

        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()

        self.decoder.userInfo[.actorSystemKey] = self
        self.encoder.userInfo[.actorSystemKey] = self
    }

    func shutdown() {
        logger.trace(#function)
        self.server.channel.close(promise: nil)
    }

    private static func bootstrap(
        host: String,
        port: Int,
        _ logger: Logger
    ) async throws
        -> NIOAsyncChannel<
            NIOAsyncChannel<ButterflyCommand, ButterflyCommand>, Never
        >
    {

        let certPath = "cert.pem"
        let keyPath = "key.pem"

        let key = try NIOSSLPrivateKey(file: keyPath, format: .pem)

        let tlsConfiguration = TLSConfiguration.makeServerConfiguration(
            certificateChain: try NIOSSLCertificate.fromPEMFile(certPath).map { .certificate($0) },
            privateKey: .privateKey(key)
        )

        let sslContext = try NIOSSLContext(configuration: tlsConfiguration)

        logger.trace(#function)
        let group: MultiThreadedEventLoopGroup = .singleton
        let bootstrap =
            try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSLServerHandler(context: sslContext))

                    try channel.pipeline.syncOperations.addHandler(
                        ByteToMessageHandler(BufferCoder(logger: logger)))
                    try channel.pipeline.syncOperations.addHandler(
                        MessageToByteHandler(BufferCoder(logger: logger)))

                    return try NIOAsyncChannel(
                        wrappingChannelSynchronously: channel,
                        configuration: NIOAsyncChannel.Configuration(
                            inboundType: ButterflyCommand.self,
                            outboundType: ButterflyCommand.self
                        )
                    )
                }
            }
        logger.trace("Bootstrap complete")
        return bootstrap
    }

    func background() {
        Task {
            try await boot()
        }
    }

    func boot() async throws {
        logger.trace(#function)
        try await withThrowingDiscardingTaskGroup { group in
            try await self.server.executeThenClose { inbound in
                for try await connectionChannel in inbound {
                    group.addTask {
                        self.logger.trace("Client connected")
                        do {
                            try await connectionChannel.executeThenClose {
                                inboundChannel, outboundChannel in
                                connection: for try await message in inboundChannel {
                                    // NOTE: We really only recieve one message for each connection right now.
                                    switch message {
                                    case .json(let json):
                                        do {
                                            let data = json.data(using: .utf8)!
                                            let networkMessage = try self.decoder.decode(
                                                NetworkMessage.self, from: data)
                                            self.logger.trace("\(networkMessage)")
                                            let actor = self.lockedActors.withLock { actors in
                                                return actors[networkMessage.actorID]
                                            }
                                            self.logger.trace("\(String(describing: actor))")
                                            guard let actor else {
                                                self.logger.error("Missing \(type(of: actor))")
                                                self.lockedActors.withLock { actors in
                                                    self.logger.trace("actors: \(actors)")
                                                }
                                                break connection
                                            }
                                            var decoder = CallDecoder(
                                                message: networkMessage, decoder: self.decoder,
                                                logLevel: self.logger.logLevel)
                                            let handler = Handler(
                                                outbound: outboundChannel,
                                                encoder: self.encoder,
                                                logLevel: self.logger.logLevel)
                                            try await self.executeDistributedTarget(
                                                on: actor,
                                                target: RemoteCallTarget(networkMessage.target),
                                                invocationDecoder: &decoder,
                                                handler: handler)
                                        } catch {
                                            self.logger.error("json: \(error)")
                                        }
                                        break connection
                                    }
                                }
                            }
                        } catch {
                            self.logger.error("Client threw an error")
                        }
                    }
                }
            }
        }
    }

    public func remoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws -> Res
    where Act: DistributedActor, Act.ID == ButterflyId, Err: Error, Res: SerializationRequirement {
        logger.trace(#function)
        guard let respName = _mangledTypeName(Res.self) else {
            throw ButterflyMessageError.returnNameManglingError
        }
        guard let errorName = _mangledTypeName(Err.self) else {
            throw ButterflyMessageError.returnNameManglingError
        }

        let msg = NetworkMessage(
            actorID: actor.id,
            target: target.identifier,
            genericSubstitutions: invocation.genericSubs,
            arguments: invocation.argumentData,
            returnTypeName: respName,
            throwingTypeName: errorName)

        let payload = try encoder.encode(msg)

        guard let json = String(data: payload, encoding: .utf8) else {
            throw ButterflyMessageError.idk("Could not decode json")
        }

        let client = Client(
            host: actor.id.host, port: actor.id.port,
            logger: logger)

        logger.trace("Sending message to :\(actor.id)")
        guard let value = try await client.send(command: .json(json)) else {
            throw ButterflyMessageError.idk("No value to return")
        }
        switch value {
        case .json(let json):
            let data = json.data(using: .utf8)!
            do {
                let rsp: Res = try self.decoder.decode(Res.self, from: data)
                logger.trace("returning: \(type(of: rsp)) \(rsp)")
                return rsp
            } catch {
                do {
                    let rsp: RemoteErrorMessage = try self.decoder.decode(
                        RemoteErrorMessage.self, from: data)
                    logger.trace("throwing error: \(type(of: rsp)) \(rsp)")
                    // TODO: throw the actual error
                    throw ButterflyMessageError.idk(rsp.message)
                } catch let expected as ButterflyMessageError {
                    throw expected
                } catch {
                    throw ButterflyMessageError.idk("Invalid reponse")
                }
            }
        }
    }

    public func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout CallEncoder,
        throwing: Err.Type
    ) async throws where Act: DistributedActor, Err: Error, ButterflyId == Act.ID {
        logger.trace(#function)
        guard let errorName = _mangledTypeName(Err.self) else {
            throw ButterflyMessageError.returnNameManglingError
        }
        let msg = NetworkMessage(
            actorID: actor.id,
            target: target.identifier,
            genericSubstitutions: invocation.genericSubs,
            arguments: invocation.argumentData,
            returnTypeName: nil,
            throwingTypeName: errorName)

        let payload = try encoder.encode(msg)

        guard let json = String(data: payload, encoding: .utf8) else {
            throw ButterflyMessageError.idk("Could not find json")
        }

        let client = Client(
            host: actor.id.host, port: actor.id.port,
            logger: logger)

        // Void client returns nil
        // What happens when it should be void?
        logger.trace("Sending message to :\(actor.id)")
        guard let value = try await client.send(command: .json(json)) else {
            throw ButterflyMessageError.idk("No value to return")
        }
        switch value {
        case .json(let json):
            let data = json.data(using: .utf8)!
            do {
                let rsp: RemoteErrorMessage = try self.decoder.decode(
                    RemoteErrorMessage.self, from: data)
                logger.trace("throwing error: \(type(of: rsp)) \(rsp)")
                // TODO: throw the actual error
                throw ButterflyMessageError.idk(rsp.message)
            } catch let expected as ButterflyMessageError {
                throw expected
            } catch {
                return
            }
        }
    }

    public func resolve<Act>(id: ButterflyId, as actorType: Act.Type) throws -> Act?
    where Act: DistributedActor, ButterflyId == Act.ID {
        logger.trace("\(#function) \(id) \(actorType)")
        return nil  // nil forces remote calls. When can I save id's?
    }

    public func assignID<Act>(_ actorType: Act.Type) -> ButterflyId
    where Act: DistributedActor, ButterflyId == Act.ID {
        let id = ButterflyId(host: host, port: port)
        logger.trace("\(#function):\(host), \(port), \(actorType)")
        return id
    }

    public func actorReady<Act>(_ actor: Act) where Act: DistributedActor, ButterflyId == Act.ID {
        return lockedActors.withLock { actors in
            logger.trace(#function)
            actors[actor.id] = actor
        }
    }

    public func resignID(_ id: ButterflyId) {
        logger.trace("\(#function) \(id)")
        lockedActors.withLock { actors in
            guard actors.removeValue(forKey: id) != nil else {
                logger.critical("\(#function) \(id)")
                assert(false)
                return
            }
        }
    }

    public func makeInvocationEncoder() -> CallEncoder {
        logger.trace(#function)
        return CallEncoder(actorSystem: self, logLevel: self.logger.logLevel)
    }
}

extension ButterflyActorSystem {

    public struct CallEncoder: DistributedTargetInvocationEncoder {

        public typealias SerializationRequirement = ButterflyMessage

        private let logger: Logger
        private let actorSystem: ButterflyActorSystem
        private(set) var genericSubs: [String] = []
        private(set) var argumentData: [Data] = []
        private(set) var returnType: String?
        private(set) var throwType: String?

        init(actorSystem: ButterflyActorSystem, logLevel: Logger.Level) {
            self.logger = Logger.create(label: "CallEncoder", logLevel: logLevel)
            self.actorSystem = actorSystem
        }

        public mutating func recordArgument<Value: SerializationRequirement>(
            _ argument: RemoteCallArgument<Value>
        )
            throws
        {
            logger.trace(#function)
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

    public struct CallDecoder: DistributedTargetInvocationDecoder {
        public typealias SerializationRequirement = ButterflyMessage

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
                throw ButterflyMessageError.idk("out of arguments")
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
        public typealias SerializationRequirement = ButterflyMessage

        let logger: Logger
        let encoder: JSONEncoder
        let outbound: NIOAsyncChannelOutboundWriter<ButterflyCommand>

        init(
            outbound: NIOAsyncChannelOutboundWriter<ButterflyCommand>, encoder: JSONEncoder,
            logLevel: Logger.Level
        ) {
            self.logger = Logger.create(label: "Handler", logLevel: logLevel)
            self.outbound = outbound
            self.encoder = encoder
        }

        public func onReturn<Success: SerializationRequirement>(value: Success) async throws {
            logger.trace("\(#function)")
            let data = try encoder.encode(value)
            let json = String(data: data, encoding: .utf8)!
            try await outbound.write(.json(json))
        }

        public func onReturnVoid() async throws {
            logger.trace("\(#function)")
            try await outbound.write(.json(#function))
            return
        }

        public func onThrow<Err>(error: Err) async throws where Err: Error {
            logger.trace("\(#function)")
            // TODO: Return the actual arror
            let re = RemoteErrorMessage(message: "\(error)")
            let data = try encoder.encode(re)
            let json = String(data: data, encoding: .utf8)!
            try await outbound.write(.json(json))
        }
    }
}

struct RemoteErrorMessage: Error, Equatable, ButterflyActorSystem.SerializationRequirement {
    let message: String
}

struct NetworkMessage: ButterflyMessage {
    let actorID: ButterflyActorSystem.ActorID
    let target: String
    let genericSubstitutions: [String]
    let arguments: [Data]
    let returnTypeName: String?
    let throwingTypeName: String?
}
