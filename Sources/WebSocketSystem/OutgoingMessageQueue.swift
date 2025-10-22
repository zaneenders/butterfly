import NIOCore
import NIOWebSocket

extension WebSocketSystem {
    actor OutgoingMessageQueue {
        private var continuation: AsyncStream<Void>.Continuation
        private var mailbox: [ActorID: [OutgoingMessage]] = [:]

        let stream: AsyncStream<Void>

        init() {
            (stream, continuation) = AsyncStream.makeStream()
        }

        func enqueue(_ message: OutgoingMessage, for actor: ActorID) {
            mailbox[actor, default: []].append(message)
            continuation.yield()
        }

        func dequeueAll(for actor: ActorID) -> [OutgoingMessage]? {
            defer { continuation.yield() }
            return mailbox.removeValue(forKey: actor)
        }
    }
}

extension WebSocketSystem {
    func drainMessages(
        remoteID: WebSocketActorId,
        with outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>
    ) async {
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
}
