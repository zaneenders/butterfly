import NIOCore

public enum ButterflyCommand: Sendable, Equatable {
    case json(String)
}

extension ButterflyCommand {
    func message(for version: UInt8) -> Message {
        switch self {
        case .json(let json):
            var buffer = ByteBuffer()
            buffer.writeString(json)
            return Message(version: version, type: 0, message: buffer)
        }
    }
}

extension Message {
    func command() -> ButterflyCommand? {
        switch self.version {
        case 0:
            return self.command0
        default:
            return nil
        }
    }

    // Version 0 commands
    private var command0: ButterflyCommand? {
        switch self.type {
        case 0:
            guard let contents = self.contents else {
                return nil
            }
            return .json(contents)
        default:
            return nil
        }
    }

    private var contents: String? {
        guard let buffer = self.message else {
            return nil
        }
        let msg = String(buffer: buffer)
        return msg
    }
}
