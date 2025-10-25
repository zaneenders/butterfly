import Distributed
import Logging
import WebSocketSystem

public distributed actor TestWorker {
  public typealias ActorSystem = WebSocketSystem
  let logLevel: Logger.Level
  public init(actorSystem: WebSocketSystem, logLevel: Logger.Level) {
    self.actorSystem = actorSystem
    self.logLevel = logLevel
  }

  public distributed func doWork(_ work: Int) -> Int {
    return work
  }
}
