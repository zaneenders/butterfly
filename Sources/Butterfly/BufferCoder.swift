import Logging
import NIOCore

final class BufferCoder: ByteToMessageDecoder, MessageToByteEncoder, Sendable {
    typealias InboundOut = ButterflyCommand
    typealias OutboundIn = ButterflyCommand
    private let logger: Logger
    private let version: UInt8
    init(logger: Logger) {
        self.logger = logger
        self.version = 0
    }

    func decode(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer
    ) throws -> DecodingState {
        let header_size: UInt16 = 4
        guard buffer.readableBytes >= header_size else {
            return .needMoreData
        }
        let version = buffer.readInteger(as: UInt8.self)!
        let type = buffer.readInteger(as: UInt8.self)!
        let length = buffer.readInteger(as: UInt16.self)!
        let message_size = Int(length - header_size)
        guard buffer.readableBytes >= message_size else {
            buffer.moveReaderIndex(to: buffer.readerIndex - Int(header_size))
            return .needMoreData
        }
        var message: ByteBuffer? = nil
        if message_size > 0 {
            message = buffer.readSlice(length: message_size)
        }
        if let message {
            let msg = Message(version: version, type: type, message: message)
            if let event: ButterflyCommand = msg.command() {
                context.fireChannelRead(Self.wrapInboundOut(event))
            } else {
                logger.critical("Error encoding msg: \(msg) as command.")
                throw ButterflyMessageError.decoding("Error encoding msg: \(msg) as command.")
            }
        } else {
            let msg = Message(version: version, type: type)
            if let event: ButterflyCommand = msg.command() {
                context.fireChannelRead(Self.wrapInboundOut(event))
            } else {
                logger.critical("Error encoding msg: \(msg) as command.")
                throw ButterflyMessageError.decoding("Error encoding msg: \(msg) as command.")
            }
        }
        return .continue
    }

    func encode(data: ButterflyCommand, out: inout ByteBuffer) throws {
        let command = data.message(for: version)
        out.writeInteger(command.version, as: UInt8.self)
        out.writeInteger(command.type, as: UInt8.self)
        out.writeInteger(command.length, as: UInt16.self)
        if var message = command.message {
            out.writeBuffer(&message)
        }
        assert(out.readableBytes == command.length)
    }
}
