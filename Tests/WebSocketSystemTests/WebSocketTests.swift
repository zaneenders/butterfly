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
    clientSystem.lockedLocalActors.withLock { actors in
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
    clientSystem2.lockedLocalActors.withLock { actors in
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
    serverSystem.lockedLocalActors.withLock { actors in
      #expect(actors.count == 0)
    }
    serverSystem.lockedAwaitingInbound.withLock { mailBox in
      #expect(mailBox.count == 0)
    }
    serverSystem.lockedMessagesInflight.withLock { inFlight in
      #expect(inFlight.count == 0)
    }
  }

  @Test(.timeLimit(.minutes(1))) func manyClients() async throws {
    let host = "::1"
    let port = 7002
    let numClients = 200

    let serverSystem = try await WebSocketSystem(
      .server(host: host, port: port, uri: "/"), logLevel: logLevel
    )
    serverSystem.background()

    // Create actor instances and assign them to an actorsystem.
    let server = Backend(actorSystem: serverSystem, logLevel: logLevel)

    var clientSystems: [WebSocketSystem] = []
    var serverConnections: [Backend] = []
    for i in 0..<numClients {
      let clientSystem = try await WebSocketSystem(
        .client(host: host, port: port, uri: "/"), logLevel: logLevel
      )
      clientSystem.background()
      clientSystems.append(clientSystem)
      let serverConnection = try Backend.resolve(id: server.id, using: clientSystem)
      serverConnections.append(serverConnection)
      // Test initial call
      let response = try await serverConnection.doWork(i)
      #expect(response == i)
    }
    let connections = serverConnections

    let messagesToSend = 40000
    let count = await withTaskGroup(of: Int.self) { group in
      for c in 0..<messagesToSend {
        let clientIndex = c % numClients
        group.addTask {
          let id = try? await connections[clientIndex].doWork(c)
          if let id, id == c {
            return 1
          }
          return 0
        }
      }
      var total = 0
      for await result in group {
        total += result
      }
      return total
    }
    #expect(count == messagesToSend)

    serverSystem.lockedOutbounds.withLock { actors in
      #expect(actors.count == numClients)
      for actor in actors {
        print(actor.key)
      }
    }

    for clientSystem in clientSystems {
      clientSystem.shutdown()
    }
    serverSystem.shutdown()
  }
}
