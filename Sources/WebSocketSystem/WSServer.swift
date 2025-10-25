import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

enum ServerUpgradeResult {
  case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
  case notUpgraded(WebSocketSystemError)
}

func boot(host: String, port: Int) async throws -> NIOAsyncChannel<
  EventLoopFuture<ServerUpgradeResult>, Never
> {
  // TODO: can i remove the EventLoopFuture for an NIOAsyncChannel
  let channel: NIOAsyncChannel<EventLoopFuture<ServerUpgradeResult>, Never> =
    try await ServerBootstrap(
      group: .singletonMultiThreadedEventLoopGroup
    )
    .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
    .bind(
      host: host,
      port: port
    ) { channel in
      channel.eventLoop.makeCompletedFuture {
        let upgrader = NIOTypedWebSocketServerUpgrader<ServerUpgradeResult>(
          shouldUpgrade: { (channel, head) in
            channel.eventLoop.makeSucceededFuture(HTTPHeaders())
          },
          upgradePipelineHandler: { (channel, _) in
            channel.eventLoop.makeCompletedFuture {
              let asyncChannel = try NIOAsyncChannel<
                WebSocketFrame, WebSocketFrame
              >(
                wrappingChannelSynchronously: channel
              )
              return ServerUpgradeResult.websocket(asyncChannel)
            }
          }
        )

        let serverUpgradeConfiguration = NIOTypedHTTPServerUpgradeConfiguration(
          upgraders: [upgrader],
          notUpgradingCompletionHandler: { channel in
            channel.eventLoop.makeCompletedFuture {
              ServerUpgradeResult.notUpgraded(
                WebSocketSystemError.message("Unable to upgrade")
              )
            }
          }
        )

        let negotiationResultFuture = try channel.pipeline.syncOperations
          .configureUpgradableHTTPServerPipeline(
            configuration: .init(upgradeConfiguration: serverUpgradeConfiguration)
          )
        return negotiationResultFuture
      }
    }
  return channel
}
