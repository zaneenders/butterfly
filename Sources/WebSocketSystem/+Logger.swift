import Logging

extension Logger {
    package static func create(label: String, logLevel: Logger.Level) -> Logger {
        var logger = Logger(label: "\("\(GitInfo.commitHash)".prefix(7)): \(label)")
        logger.logLevel = logLevel
        return logger
    }
}
