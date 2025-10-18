import Distributed
import Foundation
import Logging
import NIOCore
import NIOWebSocket
import Synchronization

typealias MailboxPayload = CheckedContinuation<any Sendable & Codable, any Error>

public final class WebSocketSystem: DistributedActorSystem, Sendable {
    public typealias ActorID = WebSocketActorId
    public typealias InvocationEncoder = CallEncoder
    public typealias InvocationDecoder = CallDecoder
    public typealias ResultHandler = Handler
    public typealias SerializationRequirement = Codable & Sendable
    private let logger: Logger
    internal let encoder: JSONEncoder
    internal let decoder: JSONDecoder

    private let serverChannel: NIOAsyncChannel<EventLoopFuture<ServerUpgradeResult>, Never>?
    private let clientChannel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>?

    internal let messageQueue: WebSocketSystem.OutgoingMessageQueue = OutgoingMessageQueue()
    private let lockedActors: Mutex<[WebSocketActorId: any DistributedActor]> = Mutex([:])
    private let lockedMessagesInflight: Mutex<[WebSocketActorId: Set<UUID>]> = Mutex([:])
    private let lockedAwaitingInbound: Mutex<[UUID: MailboxPayload]> = Mutex([:])
    private let backgroundTask: Mutex<Task<(), Never>?> = Mutex(nil)

    public let mode: Mode
    public let host: String
    public let port: Int

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

        let channel: any Channel
        switch mode {
        case .server:
            guard let c = serverChannel?.channel else {
                throw WebSocketSystemError.message("Server has no channel")
            }
            channel = c
        case .client:
            guard let c = clientChannel?.channel else {
                throw WebSocketSystemError.message("Client has no channel")
            }
            channel = c
        }
        guard let h: String = channel.localAddress?.ipAddress else {
            throw WebSocketSystemError.message("\(mode)")
        }
        guard let p: Int = channel.localAddress?.port else {
            throw WebSocketSystemError.message("\(mode)")
        }
        self.host = h
        self.port = p
        self.decoder.userInfo[.actorSystemKey] = self
        self.encoder.userInfo[.actorSystemKey] = self
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
            await t?.value
        }
    }

    public func start() async {
        switch self.mode {
        case .server:
            await _runAsServer()
        case .client:
            await _runAsClient()
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

    private func _background(service: @escaping @Sendable () async -> Void) {
        let t = Task {
            await service()
        }
        backgroundTask.withLock { task in
            task = t
        }
    }

    private func _runAsServer() async {
        await withDiscardingTaskGroup { group in
            do {
                try await serverChannel!.executeThenClose { inbound in
                    do {
                        for try await upgradeResult in inbound {
                            group.addTask {
                                do {
                                    let connection = try await upgradeResult.get()
                                    switch connection {
                                    case .notUpgraded:
                                        self.logger.error("not upgraded")
                                        return
                                    case .websocket(let wsChannel):
                                        let remoteID = try wsChannel.channel.remoteAddress.getID(
                                            self.logger)
                                        try await wsChannel.executeThenClose { inbound, outbound in
                                            await withTaskGroup { group in
                                                group.addTask {
                                                    do {
                                                        connection: for try await frame in inbound {
                                                            switch frame.opcode {
                                                            case .text:
                                                                let json = String(
                                                                    buffer: frame.data)
                                                                self.logger.trace(
                                                                    "Received: \(json.count)")
                                                                let data = json.data(using: .utf8)!
                                                                if let callBack = try? self.decoder
                                                                    .decode(
                                                                        ResponseJSONMessage.self,
                                                                        from: data)
                                                                {
                                                                    let continuation = self
                                                                        .lockedAwaitingInbound
                                                                        .withLock {
                                                                            mailBox in
                                                                            self.logger.warning(
                                                                                "mailBox: \(mailBox)"
                                                                            )
                                                                            return
                                                                                mailBox.removeValue(
                                                                                    forKey: callBack
                                                                                        .id)
                                                                        }
                                                                    _ = self.lockedMessagesInflight
                                                                        .withLock {
                                                                            inFlight in
                                                                            inFlight[remoteID]?
                                                                                .remove(
                                                                                    callBack.id)
                                                                        }
                                                                    self.logger.trace(
                                                                        "\(callBack.id) sent: \(callBack.json) \(String(describing: continuation))"
                                                                    )
                                                                    continuation?.resume(
                                                                        returning: callBack.json)
                                                                    continue connection
                                                                }
                                                                guard
                                                                    let networkMessage =
                                                                        try? self.decoder
                                                                        .decode(
                                                                            WebSocketMessage.self,
                                                                            from: data)
                                                                else {
                                                                    self.logger.error(
                                                                        "Unable to decode: \(json)")
                                                                    continue connection
                                                                }
                                                                self.logger.trace(
                                                                    "\(networkMessage)")

                                                                let actor = self.lockedActors
                                                                    .withLock {
                                                                        actors in
                                                                        return actors[
                                                                            networkMessage.actorID]
                                                                    }
                                                                self.logger.trace(
                                                                    "\(String(describing: actor))")
                                                                guard let actor else {
                                                                    self.logger.error(
                                                                        "Missing \(type(of: actor))"
                                                                    )
                                                                    self.lockedActors.withLock {
                                                                        actors in
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
                                                                try await self
                                                                    .executeDistributedTarget(
                                                                        on: actor,
                                                                        target: RemoteCallTarget(
                                                                            networkMessage.target),
                                                                        invocationDecoder: &decoder,
                                                                        handler: handler)
                                                                self.logger.trace(
                                                                    "Message handled: \(networkMessage)"
                                                                )
                                                            case .ping:
                                                                self.logger.trace("Received ping")
                                                                var frameData = frame.data
                                                                let maskingKey = frame.maskKey

                                                                if let maskingKey = maskingKey {
                                                                    frameData.webSocketUnmask(
                                                                        maskingKey)
                                                                }

                                                                let responseFrame = WebSocketFrame(
                                                                    fin: true, opcode: .pong,
                                                                    data: frameData)
                                                                try await outbound.write(
                                                                    responseFrame)
                                                            case .connectionClose:
                                                                self.logger.trace("Received close")
                                                                var data = frame.unmaskedData
                                                                let closeDataCode =
                                                                    data.readSlice(length: 2)
                                                                    ?? ByteBuffer()
                                                                let closeFrame = WebSocketFrame(
                                                                    fin: true,
                                                                    opcode: .connectionClose,
                                                                    data: closeDataCode)
                                                                try await outbound.write(closeFrame)
                                                                return
                                                            case .binary, .continuation, .pong:
                                                                self.logger.trace(
                                                                    "opcode: \(frame.opcode)")
                                                                break
                                                            default:
                                                                self.logger.critical(
                                                                    "opcode: \(frame.opcode)")
                                                                return
                                                            }
                                                        }
                                                    } catch {
                                                        self.logger.error(
                                                            "Message loop closed for \(remoteID): \(error)"
                                                        )
                                                    }
                                                }

                                                group.addTask {
                                                    for await _ in self.messageQueue.stream {
                                                        if let outgoing = await self.messageQueue
                                                            .dequeueAll(for: remoteID)
                                                        {
                                                            for out in outgoing {
                                                                do {
                                                                    try await outbound.write(
                                                                        out.frame)
                                                                    self.logger.trace(
                                                                        "\(out.id) sent to \(remoteID)"
                                                                    )
                                                                    self.lockedAwaitingInbound
                                                                        .withLock {
                                                                            mailBox in
                                                                            mailBox[out.id] =
                                                                                out.continuation
                                                                        }
                                                                    _ = self.lockedMessagesInflight
                                                                        .withLock {
                                                                            inFlight in
                                                                            inFlight[remoteID]?
                                                                                .insert(
                                                                                    out.id)
                                                                        }
                                                                } catch {
                                                                    out.continuation.resume(
                                                                        throwing:
                                                                            WebSocketSystemError
                                                                            .message(
                                                                                "Send failed: \(error)"
                                                                            )
                                                                    )
                                                                }
                                                            }
                                                        }
                                                    }
                                                }

                                                group.addTask {
                                                    while true {
                                                        do {

                                                            let theTime = ContinuousClock().now
                                                            var buffer = wsChannel.channel.allocator
                                                                .buffer(
                                                                    capacity: 12)
                                                            buffer.writeString("\(theTime)")

                                                            let frame = WebSocketFrame(
                                                                fin: true, opcode: .ping,
                                                                data: buffer)

                                                            self.logger.trace(
                                                                "Sending time: \(theTime)")
                                                            try await outbound.write(frame)
                                                            try await Task.sleep(for: .seconds(1))
                                                        } catch {
                                                            self.logger.warning(
                                                                "failed ot send ping: \(error)")
                                                        }
                                                    }
                                                }
                                                self._serverCleanUP(remoteID)
                                                await group.next()
                                                group.cancelAll()
                                            }
                                        }
                                    }
                                } catch {
                                    self.logger.notice("Client disonncted: \(error)")
                                }
                            }
                        }
                    } catch {
                        self.logger.critical("Connection stream closed: \(error)")
                    }
                    self.logger.warning("Server shutting down")
                }
            } catch {
                self.logger.critical("Execute then close threw: \(error)")
            }
        }
    }

    private func _serverCleanUP(_ remoteID: WebSocketActorId) {
        self.logger.notice("Server connection to: \(remoteID) closed.")
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

    private func _runAsClient() async {
        let pingFrame = WebSocketFrame(
            fin: true, opcode: .ping, data: ByteBuffer(string: ""))
        do {
            try await clientChannel!.executeThenClose { inbound, outbound in
                let remoteID = try clientChannel!.channel.remoteAddress.getID(self.logger)
                await withTaskGroup { group in
                    group.addTask {
                        do {
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
                        } catch {
                            self.logger.error("Web socket message loop threw: \(error)")
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
                                        // Ok we are getting an i/o on closed stream here.
                                        out.continuation.resume(
                                            throwing: WebSocketSystemError.message(
                                                "Send failed: \(error)"))
                                    }
                                }
                            }
                        }
                    }
                    await group.next()
                    group.cancelAll()
                }

                self.logger.notice("Client connection to: \(remoteID) closed.")
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
        } catch {
            self.logger.critical("ExcuteThenClose threw: \(error)")
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

    private func _encodeAndSend<Act>(
        on actor: Act,
        message: WebSocketMessage
    ) async throws -> SerializationRequirement
    where Act: DistributedActor, WebSocketActorId == Act.ID {
        let payload = try encoder.encode(message)

        guard let json = String(data: payload, encoding: .utf8) else {
            throw WebSocketSystemError.message("Could not find json")
        }

        let frame = WebSocketFrame(
            fin: true, opcode: .text, data: ByteBuffer(string: json))

        let value = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<any SerializationRequirement, any Error>) in
            let m = OutGoingMessage(id: message.messageID, frame: frame, continuation: continuation)
            Task.immediate {
                await messageQueue.enqueue(m, for: actor.id)
            }
        }
        return value
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

        let value: any WebSocketSystem.SerializationRequirement = try await _encodeAndSend(
            on: actor, message: msg)

        guard let jsonRsp = value as? String else {
            throw WebSocketSystemError.message("Failed to view json string \(type(of: value))")
        }
        if jsonRsp == Handler.voidReturnMarker {
            return
        }
        let data: Data = jsonRsp.data(using: .utf8)!
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

        let value: any WebSocketSystem.SerializationRequirement = try await _encodeAndSend(
            on: actor, message: msg)

        // We are never getting to here.
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
}


