import Distributed
import Foundation
import Logging
import NIOCore
import NIOWebSocket
import Synchronization

typealias MailboxMessage = CheckedContinuation<any Sendable & Codable, any Error>

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

public final class WebSocketSystem: DistributedActorSystem, Sendable {
    public typealias ActorID = WebSocketActorId
    public typealias InvocationEncoder = CallEncoder
    public typealias InvocationDecoder = CallDecoder
    public typealias ResultHandler = Handler
    public typealias SerializationRequirement = Codable & Sendable
    private let logger: Logger
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private let lockedActors: Mutex<[WebSocketActorId: any DistributedActor]> = Mutex([:])
    private let lockedMessagesInflight: Mutex<[WebSocketActorId: Set<UUID>]> = Mutex([:])
    private let lockedAwaitingInbound: Mutex<[UUID: MailboxMessage]> = Mutex([:])
    private let backgroundTask: Mutex<Task<(), Error>?> = Mutex(nil)

    struct OutGoingMessage {
        let id: UUID
        let frame: WebSocketFrame
        let continuation: MailboxMessage
    }

    struct AwaitingInbound {
        let id: UUID
        let continuation: MailboxMessage
    }

    public enum Mode: Sendable {
        case server
        case client
    }
    public let mode: Mode

    public var host: String {
        switch mode {
        case .server:
            return serverChannel!.channel.localAddress!.ipAddress!
        case .client:
            return clientChannel!.channel.localAddress!.ipAddress!
        }
    }
    public var port: Int {
        switch mode {
        case .server:
            return serverChannel!.channel.localAddress!.port!
        case .client:
            return clientChannel!.channel.localAddress!.port!
        }
    }

    private let serverChannel: NIOAsyncChannel<EventLoopFuture<ServerUpgradeResult>, Never>?
    private let clientChannel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>?

    public enum Config {
        case client(host: String, port: Int, uri: String)
        case server(host: String, port: Int, uri: String)
    }

    public init(_ mode: Config, logLevel: Logger.Level) async throws {
        let id: WebSocketActorId
        switch mode {
        case .server(let host, let port, _):
            id = WebSocketActorId(host: host, port: port)
            self.serverChannel = try await boot(host: host, port: port)
            self.clientChannel = nil
            self.mode = .server
        case .client(let host, let port, let uri):
            id = WebSocketActorId(host: host, port: port)
            self.serverChannel = nil
            let r = try await connect(host: host, port: port, uri: uri)
            switch r {
            case .notUpgraded:
                throw WSClientError.notUpgraded
            case .websocket(let channel):
                self.clientChannel = channel
            }
            self.mode = .client
        }
        self.logger = .create(label: "WebSocketSystem[\(self.mode):\(id)]", logLevel: logLevel)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.decoder.userInfo[.actorSystemKey] = self
        self.encoder.userInfo[.actorSystemKey] = self
        switch self.mode {
        case .client:
            guard clientChannel?.channel.localAddress?.ipAddress != nil else {
                self.logger.critical("Failed to start \(self.mode)")
                throw WebSocketSystemError.message("Failed to start \(self.mode)")
            }
        case .server:
            guard serverChannel?.channel.localAddress?.ipAddress != nil else {
                self.logger.critical("Failed to start \(self.mode)")
                throw WebSocketSystemError.message("Failed to start \(self.mode)")
            }
        }
    }

    deinit {
        shutdown()
    }

    public func shutdown() {
        lockedAwaitingInbound.withLock { messages in
            for message in messages {
                let value = messages.removeValue(forKey: message.key)
                value?.resume(throwing: WebSocketSystemError.message("Shutting down"))
            }
        }
        let t = backgroundTask.withLock { task in
            task?.cancel()
            return task
        }
        self.logger.notice("\(String(describing: t))")
        Task.immediate {
            do {
                try await t?.value
            } catch is CancellationError {
                // Expected
            } catch {
                self.logger.notice("task value error: \(error)")
            }
        }
    }

    public func start() async throws {
        switch self.mode {
        case .server:
            try await _runAsServer()
        case .client:
            try await _runAsClient()
        }
    }

    public func background() {
        switch self.mode {
        case .server:
            _background(service: _runAsServer)
        case .client:
            _background(service: _runAsClient)
        }
    }

    private func _background(service: @escaping @Sendable () async throws -> Void) {
        let t = Task {
            do {
                try await service()
            } catch is CancellationError {
                // Expected
            } catch {
                self.logger.critical("BACKGROUND ERROR: \(error)")
                throw error
            }
        }
        backgroundTask.withLock { task in
            task = t
        }
    }

    private func _runAsServer() async throws {
        try await withThrowingDiscardingTaskGroup { group in
            try await serverChannel!.executeThenClose { inbound in
                for try await upgradeResult in inbound {
                    group.addTask {
                        let connection = try await upgradeResult.get()
                        switch connection {
                        case .notUpgraded:
                            self.logger.error("not upgraded")
                            return
                        case .websocket(let wsChannel):
                            guard let address = wsChannel.channel.remoteAddress else {
                                self.logger.error("no remote address?")
                                return
                            }
                            let remoteID = WebSocketActorId(
                                host: address.ipAddress!, port: address.port!)
                            try await wsChannel.executeThenClose { inbound, outbound in
                                try await withThrowingTaskGroup { group in
                                    group.addTask {
                                        connection: for try await frame in inbound {
                                            switch frame.opcode {
                                            case .text:
                                                let json = String(buffer: frame.data)
                                                self.logger.trace("Received: \(json.count)")
                                                let data = json.data(using: .utf8)!
                                                if let callBack = try? self.decoder.decode(
                                                    ResponseJSONMessage.self, from: data)
                                                {
                                                    let continuation = self
                                                        .lockedAwaitingInbound.withLock {
                                                            mailBox in
                                                            self.logger.warning(
                                                                "mailBox: \(mailBox)")
                                                            return mailBox.removeValue(
                                                                forKey: callBack.id)
                                                        }
                                                    _ = self.lockedMessagesInflight.withLock {
                                                        inFlight in
                                                        inFlight[remoteID]?.remove(callBack.id)
                                                    }
                                                    self.logger.trace(
                                                        "\(callBack.id) sent: \(callBack.json) \(String(describing: continuation))"
                                                    )
                                                    continuation?.resume(
                                                        returning: callBack.json)
                                                    continue connection
                                                }
                                                guard
                                                    let networkMessage = try? self.decoder
                                                        .decode(
                                                            WebSocketMessage.self,
                                                            from: data)
                                                else {
                                                    self.logger.error(
                                                        "Unable to decode: \(json)")
                                                    continue connection
                                                }
                                                self.logger.trace("\(networkMessage)")

                                                let actor = self.lockedActors.withLock {
                                                    actors in
                                                    return actors[networkMessage.actorID]
                                                }
                                                self.logger.trace(
                                                    "\(String(describing: actor))")
                                                guard let actor else {
                                                    self.logger.error(
                                                        "Missing \(type(of: actor))")
                                                    self.lockedActors.withLock { actors in
                                                        self.logger.trace(
                                                            "actors: \(actors)")
                                                    }
                                                    break connection  // TODO: send close connection signal
                                                }
                                                var decoder = CallDecoder(
                                                    message: networkMessage,
                                                    decoder: self.decoder,
                                                    logLevel: self.logger.logLevel)
                                                let handler = Handler(
                                                    id: networkMessage.messageID,
                                                    outbound: outbound,
                                                    encoder: self.encoder,
                                                    logLevel: self.logger.logLevel)
                                                try await self.executeDistributedTarget(
                                                    on: actor,
                                                    target: RemoteCallTarget(
                                                        networkMessage.target),
                                                    invocationDecoder: &decoder,
                                                    handler: handler)
                                                self.logger.trace(
                                                    "Message handled: \(networkMessage)")
                                            case .ping:
                                                self.logger.trace("Received ping")
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
                                                self.logger.trace("Received close")
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
                                                self.logger.trace("opcode: \(frame.opcode)")
                                                break
                                            default:
                                                self.logger.critical(
                                                    "opcode: \(frame.opcode)")
                                                return
                                            }
                                        }
                                    }

                                    group.addTask {
                                        for await _ in self.messageQueue.stream {
                                            if let outgoing = await self.messageQueue
                                                .dequeueAll(for: remoteID)
                                            {
                                                for out in outgoing {
                                                    do {
                                                        try await outbound.write(out.frame)
                                                        self.logger.trace(
                                                            "\(out.id) sent to \(remoteID)")
                                                        self.lockedAwaitingInbound.withLock {
                                                            mailBox in
                                                            mailBox[out.id] =
                                                                out.continuation
                                                        }
                                                        _ = self.lockedMessagesInflight.withLock {
                                                            inFlight in
                                                            inFlight[remoteID]?.insert(out.id)
                                                        }
                                                    } catch {
                                                        out.continuation.resume(
                                                            throwing:
                                                                WebSocketSystemError.message(
                                                                    "Send failed: \(error)")
                                                        )
                                                    }
                                                }
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
                                                fin: true, opcode: .ping, data: buffer)

                                            self.logger.trace("Sending time: \(theTime)")
                                            try await outbound.write(frame)
                                            try await Task.sleep(for: .seconds(1))
                                        }
                                    }

                                    try await group.next()
                                    group.cancelAll()
                                }
                            }
                            self.logger.notice("Connection to: \(remoteID) closed.")
                            let dead = self.lockedMessagesInflight.withLock {
                                inFlight in
                                inFlight.removeValue(forKey: remoteID)
                            }
                            if let dead {
                                self.lockedAwaitingInbound.withLock { messages in
                                    for d in dead {
                                        let m = messages.removeValue(forKey: d)
                                        m?.resume(
                                            throwing: WebSocketSystemError.message(
                                                "Connection Closed"))
                                    }
                                }
                            }
                        }
                    }
                }
                self.logger.warning("Server shutting down")
            }
        }
    }

    private func _runAsClient() async throws {
        let pingFrame = WebSocketFrame(
            fin: true, opcode: .ping, data: ByteBuffer(string: ""))
        try await clientChannel!.executeThenClose { inbound, outbound in
            let remoteID = WebSocketActorId(
                host: clientChannel!.channel.remoteAddress!.ipAddress!,
                port: clientChannel!.channel.remoteAddress!.port!)
            try await withThrowingTaskGroup { group in
                group.addTask {
                    try await outbound.write(pingFrame)
                    connection: for try await frame in inbound {
                        switch frame.opcode {
                        case .pong:
                            self.logger.trace(
                                "Received pong: \(String(buffer: frame.data))")
                        case .ping:
                            self.logger.trace(
                                "Received ping: \(String(buffer: frame.data))")
                        case .text:
                            let json = String(buffer: frame.data)
                            self.logger.trace("Received count: \(json.count)")
                            let data = json.data(using: .utf8)!
                            if let callBack = try? self.decoder.decode(
                                ResponseJSONMessage.self, from: data)
                            {
                                let continuation = self
                                    .lockedAwaitingInbound.withLock {
                                        mailBox in
                                        self.logger.warning("mailBox: \(mailBox)")
                                        return mailBox.removeValue(forKey: callBack.id)
                                    }
                                _ = self.lockedMessagesInflight.withLock {
                                    messages in
                                    messages[remoteID]?.remove(callBack.id)
                                }
                                self.logger.trace(
                                    "\(callBack.id) sent: \(callBack.json) \(String(describing: continuation))"
                                )
                                continuation?.resume(returning: callBack.json)
                                continue connection
                            }
                            guard
                                let networkMessage = try? self.decoder.decode(
                                    WebSocketMessage.self, from: data)
                            else {
                                self.logger.error("Unable to decode: \(json)")
                                continue connection
                            }
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
                                break connection  // TODO: send close connection signal
                            }
                            var decoder = CallDecoder(
                                message: networkMessage, decoder: self.decoder,
                                logLevel: self.logger.logLevel)
                            let handler = Handler(
                                id: networkMessage.messageID,
                                outbound: outbound,
                                encoder: self.encoder,
                                logLevel: self.logger.logLevel)
                            try await self.executeDistributedTarget(
                                on: actor,
                                target: RemoteCallTarget(networkMessage.target),
                                invocationDecoder: &decoder,
                                handler: handler)
                        case .connectionClose:
                            self.logger.warning("Received Close instruction from server")
                            return
                        case .binary, .continuation:
                            self.logger.trace("opcode: \(frame.opcode)")
                            break
                        default:
                            self.logger.critical("opcode: \(frame.opcode)")
                            return
                        }
                    }
                }

                group.addTask {
                    for await _ in self.messageQueue.stream {
                        if let outgoing = await self.messageQueue.dequeueAll(for: remoteID) {
                            for out in outgoing {
                                do {
                                    try await outbound.write(out.frame)
                                    self.logger.trace("\(out.id) sent to \(remoteID)")
                                    self.lockedAwaitingInbound.withLock { mailBox in
                                        mailBox[out.id] = out.continuation
                                    }
                                    _ = self.lockedMessagesInflight.withLock { inFlight in
                                        inFlight[remoteID]?.insert(out.id)
                                    }
                                } catch {
                                    out.continuation.resume(
                                        throwing: WebSocketSystemError.message(
                                            "Send failed: \(error)"))
                                }
                            }
                        }
                    }
                }
                try await group.next()
                group.cancelAll()
            }

            self.logger.notice("Connection to: \(remoteID) closed.")
            let dead = self.lockedMessagesInflight.withLock {
                inFlight in
                inFlight.removeValue(forKey: remoteID)
            }
            if let dead {
                self.lockedAwaitingInbound.withLock { messages in
                    for d in dead {
                        let m = messages.removeValue(forKey: d)
                        m?.resume(
                            throwing: WebSocketSystemError.message(
                                "Connection Closed"))
                    }
                }
            }
        }
    }

    public func assignID<Act>(_ actorType: Act.Type) -> ActorID
    where Act: DistributedActor, ActorID == Act.ID {
        logger.trace("\(#function) \(host) \(port)")
        return WebSocketActorId(host: host, port: port)  // TODO: UUID or something for the actor?
    }

    public func actorReady<Act>(_ actor: Act) where Act: DistributedActor, ActorID == Act.ID {
        lockedActors.withLock { actors in
            // TODO: upgrade to weak reference
            actors[actor.id] = actor
        }
        logger.trace(#function)
    }

    public func resignID(_ id: ActorID) {
        let deadActor = lockedActors.withLock { actors in
            actors.removeValue(forKey: id)
        }
        guard deadActor != nil else {
            fatalError("Went to remove id: \(id), but no actor found by that id.")
            // NOTE: This is a programming error
        }
        logger.trace(#function)
    }

    public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
    where Act: DistributedActor, ActorID == Act.ID {
        let actor = lockedActors.withLock { actors in
            actors[id]
        }
        let r = actor as? Act
        // TODO: delete these last two lines of code.
        logger.trace("\(#function): \(String(describing: r))")
        return r
    }

    public func makeInvocationEncoder() -> InvocationEncoder {
        logger.trace(#function)
        return CallEncoder(actorSystem: self, logLevel: logger.logLevel)
    }

    public func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type
    ) async throws where Act: DistributedActor, Err: Error, WebSocketActorId == Act.ID {
        logger.trace("\(#function): on \(actor.id) , from: \(mode)")
        guard let errorName = _mangledTypeName(Err.self) else {
            throw WebSocketSystemError.message("returnNameManglingError")
        }
        let msg = WebSocketMessage(
            messageID: UUID(),
            actorID: actor.id,
            target: target.identifier,
            genericSubstitutions: invocation.genericSubs,
            arguments: invocation.argumentData,
            returnTypeName: nil,
            throwingTypeName: errorName)

        let payload = try encoder.encode(msg)

        guard let json = String(data: payload, encoding: .utf8) else {
            throw WebSocketSystemError.message("Could not find json")
        }

        let frame = WebSocketFrame(
            fin: true, opcode: .text, data: ByteBuffer(string: json))

        let value = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<any SerializationRequirement, any Error>) in
            let m = OutGoingMessage(id: msg.messageID, frame: frame, continuation: continuation)
            Task.immediate {
                await messageQueue.enqueue(m, for: actor.id)
            }
        }
        guard let jsonRsp = value as? String else {
            throw WebSocketSystemError.message("Failed to view json string \(type(of: value))")
        }
        if jsonRsp == voidReturnMarker {
            return
        }
        let data = jsonRsp.data(using: .utf8)!
        do {
            let rsp: RemoteWSErrorMessage = try self.decoder.decode(
                RemoteWSErrorMessage.self, from: data)
            logger.trace("throwing error: \(type(of: rsp)) \(rsp)")
            // TODO: throw the actual error
            throw WebSocketSystemError.message(rsp.message)
        } catch let expected as WebSocketSystemError {
            throw expected
        } catch {
            return
        }
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
        logger.trace("\(#function): on \(actor.id) , from: \(mode)")
        guard let respName = _mangledTypeName(Res.self) else {
            throw WebSocketSystemError.message("returnNameManglingError")
        }
        guard let errorName = _mangledTypeName(Err.self) else {
            throw WebSocketSystemError.message("returnNameManglingError")
        }

        let msg = WebSocketMessage(
            messageID: UUID(),
            actorID: actor.id,
            target: target.identifier,
            genericSubstitutions: invocation.genericSubs,
            arguments: invocation.argumentData,
            returnTypeName: respName,
            throwingTypeName: errorName)

        let payload = try self.encoder.encode(msg)

        guard let json = String(data: payload, encoding: .utf8) else {
            throw WebSocketSystemError.message("Cloud not decdoe json")
        }
        let frame = WebSocketFrame(
            fin: true, opcode: .text, data: ByteBuffer(string: json))

        let value = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<any SerializationRequirement, any Error>) in
            let m = OutGoingMessage(id: msg.messageID, frame: frame, continuation: continuation)
            Task.immediate {
                await messageQueue.enqueue(m, for: actor.id)
            }
        }

        guard let jsonRsp = value as? String else {
            throw WebSocketSystemError.message("Failed to view json string \(type(of: value))")
        }
        let data = jsonRsp.data(using: .utf8)!
        do {
            let rsp: Res = try self.decoder.decode(Res.self, from: data)
            logger.trace("returning: \(type(of: rsp)) \(rsp)")
            return rsp
        } catch {
            do {
                let rsp: RemoteWSErrorMessage = try self.decoder.decode(
                    RemoteWSErrorMessage.self, from: data)
                logger.trace("throwing error: \(type(of: rsp)) \(rsp)")
                // TODO: throw the actual error
                throw WebSocketSystemError.message(rsp.message)
            } catch let expected as WebSocketSystemError {
                throw expected
            } catch {
                throw WebSocketSystemError.message("Invalid reponse")
            }
        }
    }

    let messageQueue = OutgoingMessageQueue()

    actor OutgoingMessageQueue {
        private var continuation: AsyncStream<Void>.Continuation
        private var mailbox: [ActorID: [OutGoingMessage]] = [:]

        let stream: AsyncStream<Void>

        init() {
            (stream, continuation) = AsyncStream.makeStream()
        }

        func enqueue(_ message: OutGoingMessage, for actor: ActorID) {
            mailbox[actor, default: []].append(message)
            continuation.yield()
        }

        func dequeueAll(for actor: ActorID) -> [OutGoingMessage]? {
            defer { continuation.yield() }
            return mailbox.removeValue(forKey: actor)
        }
    }
}

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

    public struct Handler: DistributedTargetInvocationResultHandler {
        public typealias SerializationRequirement = Sendable & Codable

        let id: UUID
        let logger: Logger
        let encoder: JSONEncoder
        let outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>

        init(
            id: UUID,
            outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>,
            encoder: JSONEncoder,
            logLevel: Logger.Level
        ) {
            self.id = id
            self.logger = Logger.create(label: "Handler", logLevel: logLevel)
            self.encoder = encoder
            self.outbound = outbound
        }

        public func onReturn<Success: SerializationRequirement>(value: Success) async throws {
            logger.trace("\(#function)")
            // Need to send the messageID or something
            let vdata = try encoder.encode(value)
            let vjson = String(data: vdata, encoding: .utf8)!
            let rsp = ResponseJSONMessage(id: id, json: vjson)
            let data = try encoder.encode(rsp)
            let json = String(data: data, encoding: .utf8)!
            let frame = WebSocketFrame(
                fin: true, opcode: .text, data: ByteBuffer(string: json))
            do {
                try await outbound.write(frame)
            } catch {
                logger.error("\(#function)\(error)")
                throw error
            }
        }

        public func onReturnVoid() async throws {
            logger.trace("\(#function)")
            let vdata = try encoder.encode(voidReturnMarker)
            let vjson = String(data: vdata, encoding: .utf8)!
            let rsp = ResponseJSONMessage(id: id, json: vjson)
            let data = try encoder.encode(rsp)
            let json = String(data: data, encoding: .utf8)!
            let frame = WebSocketFrame(
                fin: true, opcode: .text, data: ByteBuffer(string: json))
            do {
                try await outbound.write(frame)
                return
            } catch {
                logger.error("\(#function)\(error)")
                throw error
            }
        }

        public func onThrow<Err>(error: Err) async throws where Err: Error {
            logger.trace("\(#function)")
            // TODO: Return the actual arror
            let re = RemoteWSErrorMessage(message: "\(error)")
            let data = try encoder.encode(re)
            let json = String(data: data, encoding: .utf8)!
            let frame = WebSocketFrame(
                fin: true, opcode: .text, data: ByteBuffer(string: json))
            do {
                try await outbound.write(frame)
                return
            } catch {
                logger.error("\(#function)\(error)")
                throw error
            }
        }
    }
}

let voidReturnMarker = "VOID"

struct ResponseJSONMessage: Codable, Sendable {
    let id: UUID
    let json: String
}

struct WebSocketMessage: Codable, Sendable {
    let messageID: UUID
    let actorID: WebSocketActorId
    let target: String
    let genericSubstitutions: [String]
    let arguments: [Data]
    let returnTypeName: String?
    let throwingTypeName: String?
}

struct RemoteWSErrorMessage: Error, Equatable, Sendable, Codable {
    let message: String
}

enum WebSocketSystemError: Error {
    case message(String)
}
