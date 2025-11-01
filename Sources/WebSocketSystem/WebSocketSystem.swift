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
  internal let logger: Logger
  internal let encoder: JSONEncoder
  internal let decoder: JSONDecoder

  private let serverChannel: NIOAsyncChannel<EventLoopFuture<ServerUpgradeResult>, Never>?
  private let clientChannel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>?

  final class WeakRef {
    weak var actor: (any DistributedActor)?

    init(_ actor: any DistributedActor) {
      self.actor = actor
    }
  }

  internal let lockedActors: Mutex<[Address: WeakRef]> = Mutex([:])
  internal let lockedMessagesInflight: Mutex<[WebSocketActorId: Set<UUID>]> = Mutex([:])
  internal let lockedAwaitingInbound: Mutex<[UUID: MailboxPayload]> = Mutex([:])
  internal let lockedOutbounds: Mutex<[Address: NIOAsyncChannelOutboundWriter<WebSocketFrame>]> = Mutex([:])
  private let backgroundTask: Mutex<Task<(), Never>?> = Mutex(nil)

  public let mode: Mode
  public let host: String
  public let port: Int

  public init(_ mode: Config, logLevel: Logger.Level) async throws {
    let setupLogger = Logger.create(label: "WebSocketSystemSetup \(mode)", logLevel: logLevel)
    let id: WebSocketActorId
    switch mode {
    case .server(let host, let port, _):
      id = WebSocketActorId(host: host, port: port)
      self.serverChannel = try await boot(host: host, port: port, logger: setupLogger)
      self.clientChannel = nil
      self.mode = .server
    case .client(let host, let port, let domain, let uri):
      id = WebSocketActorId(host: host, port: port)
      self.serverChannel = nil
      let r = try await connect(host: host, port: port, domain: domain, uri: uri)
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
    lockedOutbounds.withLock { outbounds in
      let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: ByteBuffer())
      for outbound in outbounds.values {
        Task.immediate {
          do {
            try await outbound.write(frame)
          } catch {
            self.logger.trace("Failed to send close frame: \(error)")
          }
        }
      }
    }
    lockedAwaitingInbound.withLock { messages in
      for message in messages {
        let value = messages.removeValue(forKey: message.key)
        value?.resume(throwing: WebSocketSystemError.message("Shutting down"))
      }
    }
    lockedActors.withLock { actors in
      actors.removeAll()
    }
    lockedMessagesInflight.withLock { inFlight in
      inFlight.removeAll()
    }
    let t = backgroundTask.withLock { task in
      task?.cancel()
      return task
    }
    self.logger.notice("\(#function)\(String(describing: t))")
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
                  await self._serverHandle(connection: connection)
                } catch {
                  self.logger.notice("Client disconnected: \(error)")
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

  private func _serverHandle(connection: ServerUpgradeResult) async {
    switch connection {
    case .notUpgraded:
      self.logger.error("not upgraded")
      return
    case .websocket(let wsChannel):
      do {
        let remoteId = try wsChannel.channel.remoteAddress.getID(
          self.logger)
        try await wsChannel.executeThenClose {
          inbound,
          outbound in
          lockedOutbounds.withLock { $0[remoteId.address] = outbound }
          await withTaskGroup { group in
            group.addTask {
              do {
                try await self._handleServerFrames(
                  remoteId: remoteId,
                  inbound: inbound,
                  outbound: outbound)
              } catch {
                self.logger.error(
                  "Message loop closed for \(remoteId): \(error)"
                )
              }
            }
            group.addTask {
              do {
                try await self._sendPings(outbound: outbound)
              } catch {
                try? await outbound.write(
                  WebSocketFrame(
                    fin: true, opcode: .connectionClose, data: ByteBuffer()))
                self.logger.warning(
                  "failed to send ping to \(remoteId), closing down.")
                return
              }
            }
            await group.next()
            group.cancelAll()
          }
        }
        _ = self.cleanUp(for: remoteId)
      } catch {
        self.logger.error("Error with Websocket connection: \(error)")
      }
    }
  }

  private func _runAsClient() async {
    do {
      try await clientChannel!.executeThenClose {
        inbound,
        outbound in
        let remoteID = try clientChannel!.channel.remoteAddress.getID(self.logger)
        lockedOutbounds.withLock { $0[remoteID.address] = outbound }
        await withTaskGroup { group in
          group.addTask {
            do {
              try await self._handleClientFrames(
                remoteId: remoteID, inbound: inbound, outbound: outbound)
            } catch {
              self.logger.error("Web socket message loop threw: \(error)")
              try? await outbound.write(
                WebSocketFrame(
                  fin: true, opcode: .connectionClose, data: ByteBuffer()))
              return
            }
          }
          await group.next()
          group.cancelAll()
        }
        _ = self.cleanUp(for: remoteID)
      }
    } catch {
      self.logger.critical("_runAsClient threw: \(error)")
    }
  }

  private func _sendPings(outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>) async throws {
    while true {
      let theTime = ContinuousClock().now
      var buffer = ByteBuffer()
      buffer.writeString("\(theTime)")

      let frame = WebSocketFrame(
        fin: true, opcode: .ping,
        data: buffer)

      self.logger.trace(
        "Sending time: \(theTime)")
      try await outbound.write(frame)
      try await Task.sleep(for: .seconds(1))
    }
  }

  private func _handleServerFrames(
    remoteId: WebSocketActorId,
    inbound: NIOAsyncChannelInboundStream<WebSocketFrame>,
    outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>
  ) async throws {
    // TODO: Do we need to save a ref to client here?
    connection: for try await frame in inbound {
      switch frame.opcode {
      case .text:
        try await handleTextFrame(remoteId: remoteId, frame: frame, outbound: outbound)
      case .ping:
        try await receivedPingSendPing(frame: frame, outbound: outbound)
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

  }

  private func receivedPingSendPing(
    frame: WebSocketFrame,
    outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>
  ) async throws {
    assert(frame.opcode == .ping)
    self.logger.trace("Received ping sending pong")
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
  }

  private func handleTextFrame(
    remoteId: WebSocketActorId,
    frame: WebSocketFrame,
    outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>
  ) async throws {
    assert(frame.opcode == .text)
    let json = String(buffer: frame.data)
    self.logger.trace("Received count: \(json.count)")
    guard let data = json.data(using: .utf8) else {
      throw WebSocketSystemError.invalidMessage
    }
    if let callBack = try? self.decoder.decode(
      ResponseJSONMessage.self, from: data)
    {
      let continuation = self
        .lockedAwaitingInbound.withLock {
          mailBox in
          self.logger.trace("continuation for \(callBack.id)")
          return mailBox.removeValue(forKey: callBack.id)
        }
      _ = self.lockedMessagesInflight.withLock {
        messages in
        messages[remoteId]?.remove(callBack.id)
      }
      self.logger.trace(
        "\(callBack.id) sent: \(callBack.json) \(String(describing: continuation))"
      )
      continuation?.resume(returning: callBack.json)
      return
    }
    guard
      let networkMessage = try? self.decoder.decode(
        WebSocketMessage.self, from: data)
    else {
      self.logger.error("Unable to decode: \(json)")
      return
    }
    self.logger.trace("\(networkMessage)")
    let actor = self.lockedActors.withLock { actors in
      return actors[networkMessage.actorID.address]?.actor
    }
    self.logger.trace("\(String(describing: actor))")
    guard let actor else {
      self.logger.error("Missing \(type(of: actor))")
      self.lockedActors.withLock { actors in
        self.logger.trace("actors: \(actors)")
      }
      return
    }
    self.logger.trace("Making call to :\(actor.id)")
    var decoder = CallDecoder(
      message: networkMessage, decoder: self.decoder,
      logLevel: self.logger.logLevel)
    let handler = Handler(
      id: networkMessage.messageID,
      outbound: outbound,
      encoder: self.encoder,
      logLevel: self.logger.logLevel)
    Task {
      try await self.executeDistributedTarget(
        on: actor,
        target: RemoteCallTarget(networkMessage.target),
        invocationDecoder: &decoder,
        handler: handler)
      self.logger.trace(
        "Message completed: \(networkMessage)"
      )
    }
  }

  private func _handleClientFrames(
    remoteId: WebSocketActorId,
    inbound: NIOAsyncChannelInboundStream<WebSocketFrame>,
    outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>
  ) async throws {
    let pingFrame = WebSocketFrame(
      fin: true, opcode: .ping, data: ByteBuffer(string: ""))
    try await outbound.write(pingFrame)
    // NOTE: Do we need to save ref to server here?
    connection: for try await frame in inbound {
      switch frame.opcode {
      case .pong, .ping:
        self.logger.trace(
          "Received \(frame.opcode): \(String(buffer: frame.data))")
      case .text:
        try await handleTextFrame(remoteId: remoteId, frame: frame, outbound: outbound)
      case .binary, .continuation:
        self.logger.trace("opcode: \(frame.opcode)")
        break
      case .connectionClose:
        self.logger.warning("Received Close instruction from server")
        return
      default:
        self.logger.critical("opcode: \(frame.opcode)")
        return
      }
    }
  }

  private func cleanUp(for remoteID: WebSocketActorId) -> (any DistributedActor)? {
    self.logger.notice("Cleaning up for: \(remoteID) connection closed.")
    let deadActors = lockedActors.withLock { actors in
      let keys = actors.keys.filter { $0 == remoteID.address }
      return keys.map { actors.removeValue(forKey: $0)?.actor }.compactMap { $0 }
    }
    let deadActor = deadActors.first
    self.logger.trace("Removed \(deadActors.count) actors for \(remoteID.address)")
    let deadMessages = lockedMessagesInflight.withLock { inFlight in
      let keys = inFlight.keys.filter { $0.address == remoteID.address }
      return keys.flatMap { inFlight.removeValue(forKey: $0) ?? [] }
    }
    _ = lockedOutbounds.withLock { $0.removeValue(forKey: remoteID.address) }
    if !deadMessages.isEmpty {
      self.lockedAwaitingInbound.withLock { messages in
        for d in deadMessages {
          let m = messages.removeValue(forKey: d)
          m?.resume(
            throwing: WebSocketSystemError.message(
              "Connection Closed"))
        }
      }
    }
    return deadActor
  }

  public func assignID<Act>(_ actorType: Act.Type) -> ActorID
  where Act: DistributedActor, ActorID == Act.ID {
    logger.trace("\(#function) \(host) \(port)")
    return WebSocketActorId(host: host, port: port)  // TODO: UUID or something for the actor?
  }

  public func actorReady<Act>(_ actor: Act) where Act: DistributedActor, ActorID == Act.ID {
    logger.trace("\(#function) \(actor.id)")
    lockedActors.withLock { actors in
      actors[actor.id.address] = WeakRef(actor)
    }
  }

  public func resignID(_ id: ActorID) {
    let deadActor = self.cleanUp(for: id)
    logger.trace("\(#function) removed: \(deadActor != nil)")
  }

  public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
  where Act: DistributedActor, ActorID == Act.ID {
    let actor = lockedActors.withLock { actors in
      actors[id.address]
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

    let value = try await sendAndWait(id: actor.id, message: msg)

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

    let value = try await sendAndWait(id: actor.id, message: msg)

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
        throw WebSocketSystemError.message("Invalid response")
      }
    }
  }

  private func sendAndWait(id: ActorID, message: WebSocketMessage) async throws
    -> WebSocketSystem.SerializationRequirement
  {
    let value: any WebSocketSystem.SerializationRequirement = try await withCheckedThrowingContinuation {
      continuation in
      lockedAwaitingInbound.withLock { $0[message.messageID] = continuation }
      _ = lockedMessagesInflight.withLock { $0[id, default: []].insert(message.messageID) }
      Task {
        do {
          let payload = try encoder.encode(message)
          guard let json = String(data: payload, encoding: .utf8) else {
            throw WebSocketSystemError.message("Could not find json")
          }
          let frame = WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(string: json))
          let outbound = lockedOutbounds.withLock { $0[id.address] }
          guard let outbound else {
            throw WebSocketSystemError.actorNotFound(id.address)
          }
          try await outbound.write(frame)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
    return value
  }
}
