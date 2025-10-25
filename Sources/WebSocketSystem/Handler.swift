import Distributed
import Foundation
import Logging
import NIOCore
import NIOWebSocket

extension WebSocketSystem {
  public struct Handler: DistributedTargetInvocationResultHandler {
    public typealias SerializationRequirement = Sendable & Codable

    static let voidReturnMarker = "VOID"

    let id: UUID
    let logger: Logger
    let encoder: JSONEncoder
    let outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>

    init(
      id: UUID,
      outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>,
      encoder: JSONEncoder,
      logLevel: Logger.Level
    ) {
      self.id = id
      self.logger = Logger.create(label: "Handler", logLevel: logLevel)
      self.encoder = encoder
      self.outbound = outbound
    }

    public func onReturn<Success: SerializationRequirement>(value: Success) async throws {
      logger.trace("\(#function)")
      // Need to send the messageID or something
      let vdata = try encoder.encode(value)
      let vjson = String(data: vdata, encoding: .utf8)!
      let rsp = ResponseJSONMessage(id: id, json: vjson)
      let data = try encoder.encode(rsp)
      let json = String(data: data, encoding: .utf8)!
      let frame = WebSocketFrame(
        fin: true, opcode: .text, data: ByteBuffer(string: json))
      do {
        try await outbound.write(frame)
      } catch {
        logger.error("\(#function)\(error)")
        throw error
      }
    }

    public func onReturnVoid() async throws {
      logger.trace("\(#function)")
      let vdata = try encoder.encode(Handler.voidReturnMarker)
      let vjson = String(data: vdata, encoding: .utf8)!
      let rsp = ResponseJSONMessage(id: id, json: vjson)
      let data = try encoder.encode(rsp)
      let json = String(data: data, encoding: .utf8)!
      let frame = WebSocketFrame(
        fin: true, opcode: .text, data: ByteBuffer(string: json))
      do {
        try await outbound.write(frame)
        return
      } catch {
        logger.error("\(#function)\(error)")
        throw error
      }
    }

    public func onThrow<Err>(error: Err) async throws where Err: Error {
      logger.trace("\(#function)")
      // TODO: Return the actual error
      let re = RemoteWSErrorMessage(message: "\(error)")
      let data = try encoder.encode(re)
      let json = String(data: data, encoding: .utf8)!
      let frame = WebSocketFrame(
        fin: true, opcode: .text, data: ByteBuffer(string: json))
      do {
        try await outbound.write(frame)
        return
      } catch {
        logger.error("\(#function)\(error)")
        throw error
      }
    }
  }
}
