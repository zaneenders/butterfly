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

    print("Starting server system...")
    let serverSystem = try await WebSocketSystem(
      .server(host: host, port: port, uri: "/"), logLevel: .warning
    )
    serverSystem.background()

    let server = Backend(actorSystem: serverSystem, logLevel: .warning)

    print("Creating \(numClients) client systems...")
    var clientSystems: [WebSocketSystem] = []
    var serverConnections: [Backend] = []
    for i in 0..<numClients {
      if i % 50 == 0 { print("Created \(i) clients...") }
      let clientSystem = try await WebSocketSystem(
        .client(host: host, port: port, uri: "/"), logLevel: .warning
      )
      clientSystem.background()
      clientSystems.append(clientSystem)
      let serverConnection = try Backend.resolve(id: server.id, using: clientSystem)
      serverConnections.append(serverConnection)
      // Test initial call
      let response = try await serverConnection.doWork(i)
      #expect(response == i)
    }
    print("All clients created and initial calls completed.")
    let connections = serverConnections

    let messagesToSend = 100_000
    print("Sending \(messagesToSend) messages across \(numClients) clients...")
    let count = await withTaskGroup(of: Int.self) { group in
      let sendStart = ContinuousClock.now
      for c in 0..<messagesToSend {
        if c % 10000 == 0 { print("Sent \(c) messages...") }
        let clientIndex = c % numClients
        group.addTask {
          let id = try? await connections[clientIndex].doWork(c)
          if let id, id == c {
            return 1
          }
          return 0
        }
      }
      let sendStop = ContinuousClock.now
      print("send time: \(sendStop - sendStart)")
      var total = 0
      for await result in group {
        total += result
      }
      let end = ContinuousClock.now
      // Roughly 1.7 seconds in release mode
      print("recieve time: \(end - sendStop)")
      return total
    }
    print("All messages sent. Successful: \(count)/\(messagesToSend)")
    #expect(count == messagesToSend)

    serverSystem.lockedOutbounds.withLock { actors in
      #expect(actors.count == numClients)
    }

    print("Shutting down client systems...")
    for clientSystem in clientSystems {
      clientSystem.shutdown()
    }
    print("Shutting down server system...")
    serverSystem.shutdown()
  }
}
