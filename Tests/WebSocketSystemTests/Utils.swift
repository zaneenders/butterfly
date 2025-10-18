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
        switch logLevel {
        case .error:
            ()
        default:
            print("Backend", actorSystem.host, actorSystem.port, "Doing work...")
        }
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
        switch logLevel {
        case .error:
            ()
        default:
            print("Client", actorSystem.host, actorSystem.port, "Received result: \(msg)")
        }
    }
}
