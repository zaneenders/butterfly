import Distributed
import Logging
import Testing

@testable import Butterfly

// NOTE: I don't like how the ports are setup in this file.

private func startup(server: Int, laptop: Int) async throws -> (Butterfly, Butterfly) {
    let logLevel: Logger.Level = .error
    let server = try await Butterfly(host: "localhost", port: server, logLevel: logLevel)
    server.background()
    let laptop = try await Butterfly(host: "localhost", port: laptop, logLevel: logLevel)
    laptop.background()
    return (server, laptop)
}

@Suite
struct ButterflyActorSystemInitTests {

    @Test func connectTwoDaemons() async {
        do {
            let (server, laptop) = try await startup(server: 48802, laptop: 48803)

            let serverS = TestScribe(actorSystem: server.system)
            let serverR = try TestScribe.resolve(id: serverS.id, using: laptop.system)
            #expect(serverS.id == serverR.id)

            let laptopS = TestScribe(actorSystem: laptop.system)
            let laptopR = try TestScribe.resolve(id: laptopS.id, using: server.system)
            #expect(laptopS.id == laptopR.id)
        } catch {
            Issue.record("\(error)")
        }
    }
}

private func getRemotes(server: Int, laptop: Int) async throws -> (TestScribe, TestScribe) {
    let (server, laptop) = try await startup(server: server, laptop: laptop)

    let serverS = TestScribe(actorSystem: server.system)
    let serverR = try TestScribe.resolve(id: serverS.id, using: laptop.system)

    let laptopS = TestScribe(actorSystem: laptop.system)
    let laptopR = try TestScribe.resolve(id: laptopS.id, using: server.system)
    return (serverR, laptopR)
}

@Suite
struct ButterflyActorSystemMessageTests {

    @Test func argumentsNotThrowing() async {
        do {
            let (serverR, laptopR) = try await getRemotes(server: 48900, laptop: 48901)
            let l = try await laptopR.six()
            let s = try await serverR.six()
            #expect(l == s)

            let addL = try await laptopR.add(a: 60, b: 9)
            let addS = try await serverR.add(a: 60, b: 9)
            #expect(addL == addS)
        } catch {
            Issue.record("\(error)")
        }
    }

    @Test func noArgumentsNotThrowing() async {
        do {
            let (serverR, laptopR) = try await getRemotes(server: 48902, laptop: 48903)
            await #expect(throws: Never.self) {
                try await laptopR.speak()
            }
            await #expect(throws: Never.self) {
                try await serverR.speak()
            }
        } catch {
            Issue.record("\(error)")
        }
    }

    @Test func sendOneHunderedMessages() async {
        do {
            let (serverR, laptopR) = try await getRemotes(server: 48904, laptop: 48905)
            await withTaskGroup { group in
                for _ in 0..<100 {
                    group.addTask {
                        await #expect(throws: Never.self) {
                            _ = try await laptopR.command()
                        }
                    }
                    group.addTask {
                        await #expect(throws: Never.self) {
                            _ = try await serverR.command()
                        }
                    }
                }
            }
        } catch {
            Issue.record("\(error)")
        }
    }

    @Test func checkErrorsAreThrow() async {
        do {
            let (serverR, laptopR) = try await getRemotes(server: 48906, laptop: 48907)
            let expected = ButterflyMessageError.idk("idk(\"TEST ERROR\")")
            await #expect(throws: expected) {
                try await serverR.error()
            }
            await #expect(throws: expected) {
                try await laptopR.error()
            }
            await #expect(throws: expected) {
                _ = try await serverR.errorWithValue()
            }
            await #expect(throws: expected) {
                _ = try await laptopR.errorWithValue()
            }
        } catch {
            Issue.record("\(error)")
        }
    }
}

distributed actor TestScribe {
    typealias ActorSystem = ButterflyActorSystem

    distributed func speak() {}

    distributed func six() -> Int {
        6
    }

    distributed func add(a: Int, b: Int) -> Int {
        return a + b
    }

    distributed func command() -> Bool {
        return true
    }

    distributed func error() throws {
        throw TestScribeError.idk("TEST ERROR")
    }

    distributed func errorWithValue() throws -> Int {
        throw TestScribeError.idk("TEST ERROR")
    }
}

enum TestScribeError: Equatable, Codable, Sendable, Error {
    case idk(String)
}
