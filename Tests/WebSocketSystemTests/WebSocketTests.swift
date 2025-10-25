import Distributed
import Logging
import Testing

@testable import WebSocketSystem

@Suite
struct WebSocketSystemTests {
  let logLevel: Logger.Level = .error

  @Test(.timeLimit(.minutes(1))) func connectDisconnect() async throws {
    let host = "::1"
    let port = 7002
    let serverSystem = try await WebSocketSystem(
      .server(host: host, port: port, uri: "/"), logLevel: logLevel
    )
    serverSystem.background()
    // This isn't needed i don't think.
    let server = Backend(actorSystem: serverSystem, logLevel: logLevel)

    let clientSystem = try await WebSocketSystem(
      .client(host: host, port: port, uri: "/"), logLevel: logLevel
    )
    clientSystem.background()
    let serverConnection = try Backend.resolve(id: server.id, using: clientSystem)
    let id = try await serverConnection.doWork(69)
    #expect(id == 69)
    clientSystem.shutdown()

    // Client should have no actors left after shutdown.
    clientSystem.lockedActors.withLock { actors in
      #expect(actors.count == 0)
    }
    clientSystem.lockedAwaitingInbound.withLock { mailBox in
      #expect(mailBox.count == 0)
    }
    clientSystem.lockedMessagesInflight.withLock { inFlight in
      #expect(inFlight.count == 0)
    }

    let clientSystem2 = try await WebSocketSystem(
      .client(host: host, port: port, uri: "/"), logLevel: logLevel
    )
    clientSystem2.background()
    let serverConnection2 = try Backend.resolve(id: server.id, using: clientSystem2)
    let id2 = try await serverConnection2.doWork(69)
    #expect(id2 == id)
    clientSystem2.shutdown()

    // Client2 should have no actors left after shutdown.
    clientSystem2.lockedActors.withLock { actors in
      #expect(actors.count == 0)
    }
    clientSystem2.lockedAwaitingInbound.withLock { mailBox in
      #expect(mailBox.count == 0)
    }
    clientSystem2.lockedMessagesInflight.withLock { inFlight in
      #expect(inFlight.count == 0)
    }

    serverSystem.shutdown()

    // Server should have no actors left after shutdown.
    serverSystem.lockedActors.withLock { actors in
      #expect(actors.count == 0)
    }
    serverSystem.lockedAwaitingInbound.withLock { mailBox in
      #expect(mailBox.count == 0)
    }
    serverSystem.lockedMessagesInflight.withLock { inFlight in
      #expect(inFlight.count == 0)
    }
  }
}
