import NIOCore

struct Message: Sendable, Equatable {
    let version: UInt8
    let type: UInt8
    let length: UInt16
    let message: ByteBuffer?

    init(version: UInt8 = 0, type: UInt8, message: ByteBuffer? = nil) {
        self.version = version
        self.type = type
        var length: UInt16 = 4
        if let messagelength = message?.readableBytes {
            length += UInt16(messagelength)
        }
        self.length = length
        self.message = message
    }
}
