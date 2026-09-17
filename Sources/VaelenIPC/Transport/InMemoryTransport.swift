import Foundation

public final class InMemoryTransport: CoreTransport, @unchecked Sendable {
    private let input: AsyncStream<Data>
    private let inputContinuation: AsyncStream<Data>.Continuation
    private let peerContinuation: AsyncStream<Data>.Continuation

    private init(input: AsyncStream<Data>, inputContinuation: AsyncStream<Data>.Continuation, peerContinuation: AsyncStream<Data>.Continuation) {
        self.input = input
        self.inputContinuation = inputContinuation
        self.peerContinuation = peerContinuation
    }

    public static func pair() -> (client: InMemoryTransport, server: InMemoryTransport) {
        let (clientInput, clientInputContinuation) = AsyncStream<Data>.makeStream()
        let (serverInput, serverInputContinuation) = AsyncStream<Data>.makeStream()
        let client = InMemoryTransport(input: clientInput, inputContinuation: clientInputContinuation, peerContinuation: serverInputContinuation)
        let server = InMemoryTransport(input: serverInput, inputContinuation: serverInputContinuation, peerContinuation: clientInputContinuation)
        return (client, server)
    }

    public func connect() async throws {}

    public func write(_ data: Data) async throws {
        peerContinuation.yield(data)
    }

    public func read() async throws -> Data {
        for await data in input {
            return data
        }
        throw CoreTransportError.unavailable
    }

    public func disconnect() async {
        inputContinuation.finish()
    }
}
