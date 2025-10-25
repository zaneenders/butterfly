import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

#if SSL
import NIOSSL
#endif

enum ClientUpgradeResult {
  case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
  case notUpgraded
}

enum WSClientError: Error {
  case notUpgraded
}

func connect(host: String, port: Int, uri: String) async throws -> ClientUpgradeResult {

  #if SSL
  print("Client using SSL")
  var tlsConfig = TLSConfiguration.makeClientConfiguration()
  let caCerts = try NIOSSLCertificate.fromPEMFile("cert.pem")
  tlsConfig.trustRoots = .certificates(caCerts)
  tlsConfig.certificateVerification = .fullVerification
  let sslContext = try NIOSSLContext(configuration: tlsConfig)
  #endif

  let upgradeResult: EventLoopFuture<ClientUpgradeResult> = try await ClientBootstrap(
    group: .singletonMultiThreadedEventLoopGroup
  )
  .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
  .connect(
    host: host,
    port: port
  ) { channel in
    channel.eventLoop.makeCompletedFuture {
      let upgrader = NIOTypedWebSocketClientUpgrader<ClientUpgradeResult>(
        upgradePipelineHandler: { (channel, _) in
          channel.eventLoop.makeCompletedFuture {
            let asyncChannel = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(
              wrappingChannelSynchronously: channel
            )
            return ClientUpgradeResult.websocket(asyncChannel)
          }
        }
      )

      var headers = HTTPHeaders()
      headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
      headers.add(name: "Content-Length", value: "0")

      let requestHead = HTTPRequestHead(
        version: .http1_1,
        method: .GET,
        uri: uri,
        headers: headers
      )

      #if SSL
      try channel.pipeline.syncOperations.addHandler(
        try NIOSSLClientHandler(context: sslContext, serverHostname: host)
      )
      #endif

      let clientUpgradeConfiguration = NIOTypedHTTPClientUpgradeConfiguration(
        upgradeRequestHead: requestHead,
        upgraders: [upgrader],
        notUpgradingCompletionHandler: { channel in
          channel.eventLoop.makeCompletedFuture {
            ClientUpgradeResult.notUpgraded
          }
        }
      )

      let negotiationResultFuture = try channel.pipeline.syncOperations
        .configureUpgradableHTTPClientPipeline(
          configuration: .init(upgradeConfiguration: clientUpgradeConfiguration)
        )

      return negotiationResultFuture
    }
  }
  return try await upgradeResult.get()
}
