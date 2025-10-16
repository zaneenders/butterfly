import Distributed
import Foundation
import Logging
import NIOCore
import NIOWebSocket
import Synchronization

typealias MailboxMessage = CheckedContinuation<any Sendable & Codable, any Error>

struct WebSocketActorId: Sendable, Codable, Hashable {
    init(host: String, port: Int) {
        if host == "localhost" {
            // TODO: support ipv4 or don't encode localhost
            self.host = "::1"
        } else {
            self.host = host
        }
        self.port = port
    }
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
    let encoder: JSONEncoder
    let decoder: JSONDecoder

    let lockedActors: Mutex<[WebSocketActorId: any DistributedActor]> = Mutex([:])

    enum Mode {
        case server
        case client
    }
    let mode: Mode
    var host: String {
        switch mode {
        case .server:
            return server!.channel.localAddress!.ipAddress!
        case .client:
            return client!.channel.localAddress!.ipAddress!
        }
    }
    var port: Int {
        switch mode {
        case .server:
            return server!.channel.localAddress!.port!
        case .client:
            return client!.channel.localAddress!.port!
        }
    }
    let server: NIOAsyncChannel<EventLoopFuture<ServerUpgradeResult>, Never>?
    let client: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>?

    enum Config {
        case client(host: String, port: Int, uri: String)
        case server(host: String, port: Int, uri: String)
    }
    init(_ mode: Config) async throws {  // TODO: sync start up?
        let id: WebSocketActorId
        switch mode {
        case .server(let host, let port, _):
            id = WebSocketActorId(host: host, port: port)
            self.server = try await boot(host: host, port: port)
            self.client = nil
            self.mode = .server
        case .client(let host, let port, let uri):
            id = WebSocketActorId(host: host, port: port)
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
        self.logger = .create(label: "WebSocketSystem[\(self.mode):\(id)]", logLevel: .trace)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.decoder.userInfo[.actorSystemKey] = self
        self.encoder.userInfo[.actorSystemKey] = self
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
                                    let remoteId = WebSocketActorId(
                                        host: address.ipAddress!, port: address.port!)
                                    try await wsChannel.executeThenClose { inbound, outbound in
                                        try await withThrowingTaskGroup { group in
                                            group.addTask {
                                                connection: for try await frame in inbound {
                                                    switch frame.opcode {
                                                    case .text:
                                                        let json = String(buffer: frame.data)
                                                        print("Received: \(json.count)")
                                                        let data = json.data(using: .utf8)!
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

                                                        let continuation = self
                                                            .lockedAwaitingInbound.withLock {
                                                                mailBox in
                                                                self.logger.warning(
                                                                    "mailBox: \(mailBox)")
                                                                return mailBox[
                                                                    networkMessage.messageID]
                                                            }
                                                        print(
                                                            "IDK DO SOMETHING HERE \(continuation)")
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
                                                        self.logger.warning(
                                                            "Message handled: \(networkMessage)")
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
                                                    let hasMessages = self.outgoingMailbox
                                                        .withLock {
                                                            mailBox in
                                                            return mailBox[remoteId] != nil
                                                        }
                                                    if hasMessages {
                                                        self.logger.notice("SERVER Has messages!!!")
                                                        let (frames, awaiting) =
                                                            self.outgoingMailbox
                                                            .withLock {
                                                                mailBox in
                                                                let outgoing = mailBox[remoteId]!
                                                                mailBox.removeValue(
                                                                    forKey: remoteId)
                                                                var awaiting: [AwaitingInbound] = []
                                                                var frames: [WebSocketFrame] = []
                                                                for out in outgoing {
                                                                    frames.append(out.frame)
                                                                    awaiting.append(
                                                                        AwaitingInbound(
                                                                            id: out.id,
                                                                            continuation: out
                                                                                .continuation))
                                                                }
                                                                return (frames, awaiting)
                                                            }
                                                        for (frame, info) in zip(
                                                            frames, awaiting)
                                                        {
                                                            Task {
                                                                do {
                                                                    self.logger.trace(
                                                                        "sending message: \(remoteId) \(info.id)"
                                                                    )
                                                                    try await outbound.write(
                                                                        frame)
                                                                } catch {
                                                                    self.logger.critical(
                                                                        "Failed to send message: \(info.id) \(error)"
                                                                    )
                                                                    info.continuation.resume(
                                                                        throwing:
                                                                            WebSocketSystemError
                                                                            .message(
                                                                                "Failed to send message: \(frame) \(error)"
                                                                            ))
                                                                }
                                                            }
                                                        }
                                                        self.lockedAwaitingInbound.withLock {
                                                            mailBox in
                                                            for m in awaiting {
                                                                mailBox[m.id] =
                                                                    m.continuation
                                                            }
                                                        }
                                                    }
                                                    let theTime = ContinuousClock().now
                                                    var buffer = wsChannel.channel.allocator.buffer(
                                                        capacity: 12)
                                                    buffer.writeString("\(theTime)")

                                                    let frame = WebSocketFrame(
                                                        fin: true, opcode: .ping, data: buffer)

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
                    let retmoteId = WebSocketActorId(
                        host: client!.channel.remoteAddress!.ipAddress!,
                        port: client!.channel.remoteAddress!.port!)
                    try await withThrowingTaskGroup { group in
                        group.addTask {
                            try await outbound.write(pingFrame)
                            connection: for try await frame in inbound {
                                switch frame.opcode {
                                case .pong:
                                    print("Received pong: \(String(buffer: frame.data))")
                                case .ping:
                                    print("Received ping: \(String(buffer: frame.data))")
                                case .text:
                                    let json = String(buffer: frame.data)
                                    print("Received: \(json.count)")
                                    let data = json.data(using: .utf8)!
                                    if let callBack = try? self.decoder.decode(
                                        ResponseJSONMessage.self, from: data)
                                    {
                                        let continuation = self
                                            .lockedAwaitingInbound.withLock {
                                                mailBox in
                                                self.logger.warning("mailBox: \(mailBox)")
                                                return mailBox[
                                                    callBack.id]
                                            }
                                        self.logger.trace("\(callBack.id) sent: \(callBack.json)")
                                        continuation?.resume(returning: callBack.json)
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
                                    // Handle a received close frame. We're just going to close by returning from this method.
                                    print("Received Close instruction from server")
                                    return
                                case .binary, .continuation:
                                    // We ignore these frames.
                                    break
                                default:
                                    // Unknown frames are errors.
                                    return
                                }
                            }
                        }

                        group.addTask {
                            while true {
                                try? await Task.sleep(for: .seconds(1))
                                let hasMessages = self.outgoingMailbox
                                    .withLock {
                                        mailBox in
                                        return mailBox[retmoteId] != nil
                                    }
                                if hasMessages {
                                    self.logger.notice("CLIENT Has messages!!!")
                                    let (frames, awaiting) =
                                        self.outgoingMailbox
                                        .withLock {
                                            mailBox in
                                            let outgoing = mailBox[id]!
                                            mailBox.removeValue(forKey: id)
                                            var awaiting: [AwaitingInbound] = []
                                            var frames: [WebSocketFrame] = []
                                            for out in outgoing {
                                                frames.append(out.frame)
                                                awaiting.append(
                                                    AwaitingInbound(
                                                        id: out.id,
                                                        continuation: out
                                                            .continuation))
                                            }
                                            return (frames, awaiting)
                                        }
                                    for (frame, info) in zip(
                                        frames, awaiting)
                                    {
                                        Task {
                                            do {
                                                self.logger.trace("\(info.id) to \(retmoteId)")
                                                try await outbound.write(frame)
                                            } catch {
                                                self.logger.critical(
                                                    "Failed to send message: \(info.id) \(error)"
                                                )
                                                info.continuation.resume(
                                                    throwing:
                                                        WebSocketSystemError
                                                        .message(
                                                            "Failed to send message: \(frame) \(error)"
                                                        ))
                                            }
                                        }
                                    }
                                    self.lockedAwaitingInbound.withLock {
                                        mailBox in
                                        for m in awaiting {
                                            mailBox[m.id] = m.continuation
                                        }
                                    }
                                }
                            }
                        }
                        try await group.next()
                        group.cancelAll()
                    }
                }
            }
        }
    }

    struct AwaitingInbound {
        let id: UUID
        let continuation: MailboxMessage
    }

    func assignID<Act>(_ actorType: Act.Type) -> ActorID
    where Act: DistributedActor, ActorID == Act.ID {
        logger.trace("\(#function) \(host) \(port)")
        return WebSocketActorId(host: host, port: port)  // TODO: UUID or something for the actor?
    }

    func actorReady<Act>(_ actor: Act) where Act: DistributedActor, ActorID == Act.ID {
        lockedActors.withLock { actors in
            // TODO: upgrade to weak reference
            actors[actor.id] = actor
        }
        logger.trace(#function)
    }

    func resignID(_ id: ActorID) {
        let deadActor = lockedActors.withLock { actors in
            actors.removeValue(forKey: id)
        }
        guard deadActor != nil else {
            fatalError("Went to remove id: \(id), but no actor found by that id.")
            // NOTE: This is a programming error
        }
        logger.trace(#function)
    }

    func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
    where Act: DistributedActor, ActorID == Act.ID {
        let actor = lockedActors.withLock { actors in
            actors[id]
        }
        let r = actor as? Act
        // TODO: delete these last two lines of code.
        logger.trace("\(#function): \(String(describing: r))")
        return r
    }

    func makeInvocationEncoder() -> InvocationEncoder {
        logger.trace(#function)
        return CallEncoder(actorSystem: self, logLevel: logger.logLevel)
    }

    let lockedAwaitingInbound: Mutex<[UUID: MailboxMessage]> = Mutex([:])
    let outgoingMailbox: Mutex<[ActorID: [OutGoingMessage]]> = Mutex([:])

    struct OutGoingMessage {
        let id: UUID
        let frame: WebSocketFrame
        let continuation: MailboxMessage
    }

    func remoteCallVoid<Act, Err>(
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

        // TODO: get a continuation to await with.
        let value = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<any SerializationRequirement, any Error>) in
            // TODO: Add message to Q to be sent
            outgoingMailbox.withLock { mailBox in
                let m = OutGoingMessage(id: msg.messageID, frame: frame, continuation: continuation)
                if mailBox[actor.id] == nil {
                    self.logger.notice("[\(actor.id)]Creating [message]: \(msg.messageID)")
                    mailBox[actor.id] = [m]
                } else {
                    self.logger.notice("[\(actor.id)]Creating message: \(msg.messageID)")
                    mailBox[actor.id]!.append(m)
                }
            }
        }
        guard let jsonRsp = value as? String else {
            throw WebSocketSystemError.message("Failed to view json string \(type(of: value))")
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

        // TODO: get a continuation to await with.
        let value = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<any SerializationRequirement, any Error>) in
            // TODO: Add message to Q to be sent
            outgoingMailbox.withLock { mailBox in
                let m = OutGoingMessage(id: msg.messageID, frame: frame, continuation: continuation)
                if mailBox[actor.id] == nil {
                    self.logger.notice("[\(actor.id)]Creating [message]: \(msg.messageID)")
                    mailBox[actor.id] = [m]
                } else {
                    self.logger.notice("[\(actor.id)]Creating message: \(msg.messageID)")
                    mailBox[actor.id]!.append(m)
                }
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
            let frame = WebSocketFrame(
                fin: true, opcode: .text, data: ByteBuffer(string: "VOID"))
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
