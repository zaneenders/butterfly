extension WebSocketSystem {
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
