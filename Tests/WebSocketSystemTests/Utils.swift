import Distributed
import Logging
import WebSocketSystem

distributed actor Backend {
  typealias ActorSystem = WebSocketSystem
  let logLevel: Logger.Level
  init(actorSystem: WebSocketSystem, logLevel: Logger.Level) {
    self.actorSystem = actorSystem
    self.logLevel = logLevel
  }

  distributed func doWork(_ work: Int) -> Int {
    testLog("Backend \(actorSystem.host) \(actorSystem.port)Received Doing work...", logLevel)
    return work
  }

  distributed func getResult(_ id: Int) -> String {
    return "\(id)"
  }
}

distributed actor Client {
  typealias ActorSystem = WebSocketSystem
  let logLevel: Logger.Level
  init(actorSystem: WebSocketSystem, logLevel: Logger.Level) {
    self.actorSystem = actorSystem
    self.logLevel = logLevel
  }

  distributed func sendResult(_ msg: String) {
    testLog("Client \(actorSystem.host) \(actorSystem.port)Received result: \(msg)", logLevel)
  }

  deinit {
    testLog("Client \(actorSystem.host) \(actorSystem.port)DEINIT", logLevel)
  }
}

func testLog(_ message: String, _ logLevel: Logger.Level) {
  if logLevel <= .debug {
    print(message)
  }
}
