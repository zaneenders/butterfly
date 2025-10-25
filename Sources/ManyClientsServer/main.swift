import Distributed
import Foundation
import Logging
import ProfileRecorderServer
import TestWorker
import WebSocketSystem

@main
struct ManyClientsServer {
  static func main() async {
    let logLevel: Logger.Level = .warning
    let logger = Logger(label: "ManyClientsServer")
    let host = "::1"
    let port = 8002

    // Run ProfileRecorderServer in the background if enabled via environment variable. Ignore failures.
    async let _ = ProfileRecorderServer(configuration: .parseFromEnvironment()).runIgnoringFailures(logger: logger)

    print("Starting server system...")
    do {
      let serverSystem = try await WebSocketSystem(
        .server(host: host, port: port, uri: "/"), logLevel: logLevel
      )
      let server = TestWorker(actorSystem: serverSystem, logLevel: logLevel)

      print("Server starting on \(host):\(port)")
      print("Press Ctrl+C to stop")
      await serverSystem.start()
    } catch {
      print("Error: \(error)")
    }
  }
}
