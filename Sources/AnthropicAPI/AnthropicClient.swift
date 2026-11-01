import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import JeevesCore

public struct AnthropicConfiguration: Sendable {
    public var apiKey: String
    public var baseURL: URL
    public var apiVersion: String
    /// Seconds to wait for the response to start and between chunks.
    public var timeout: TimeInterval

    public init(apiKey: String,
                baseURL: URL = URL(string: "https://api.anthropic.com")!,
                apiVersion: String = "2026-10-21",
                timeout: TimeInterval = 30) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.apiVersion = apiVersion
        self.timeout = timeout
    }

    /// Reads `ANTHROPIC_API_KEY`. The app will read the Keychain instead.
    public static func fromEnvironment() -> AnthropicConfiguration? {
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else { return nil }
        return AnthropicConfiguration(apiKey: key)
    }
}

public enum AnthropicError: Error, Sendable, CustomStringConvertible {
    /// Non-200 HTTP status. `body` is the API's error object when it parsed.
    case http(status: Int, body: APIErrorBody?, requestID: String?)
    /// An `error` event arrived mid-stream (for example `overloaded_error`).
    case stream(APIErrorBody)
    case transport(String)
    case decoding(String)

    public var description: String {
        switch self {
        case .http(let status, let body, let requestID):
            let detail = body.map { "\($0.type): \($0.message)" } ?? "no error body"
            return "HTTP \(status) \(detail)" + (requestID.map { " (request-id \($0))" } ?? "")
        case .stream(let body): return "stream error \(body.type): \(body.message)"
        case .transport(let message): return "transport: \(message)"
        case .decoding(let message): return "decoding: \(message)"
        }
    }

    /// True for failures worth one quick retry on the live path (429, 5xx, overload, network).
    public var isRetryable: Bool {
        switch self {
        case .http(let status, _, _): return status == 429 || status >= 500
        case .stream(let body): return body.type == "overloaded_error" || body.type == "api_error"
        case .transport: return true
        case .decoding: return false
        }
    }
}

/// Minimal Messages API client. There is no official Anthropic SDK for Swift, so this
/// speaks the HTTP API directly: one streaming request per answer.
///
/// Streaming uses a `URLSessionDataDelegate` rather than `URLSession.bytes(for:)`,
/// which keeps SSE blank-line boundaries intact and also works on Linux.
public final class AnthropicClient: Sendable {
    public let configuration: AnthropicConfiguration

    public init(configuration: AnthropicConfiguration) {
        self.configuration = configuration
    }

    public func makeURLRequest(_ request: MessagesRequest, betas: [String]) throws -> URLRequest {
        var urlRequest = URLRequest(url: configuration.baseURL.appendingPathComponent("v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(configuration.apiVersion, forHTTPHeaderField: "anthropic-version")
        if request.stream { urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept") }
        var seen = Set<String>()
        let uniqueBetas = betas.filter { seen.insert($0).inserted }
        if !uniqueBetas.isEmpty {
            urlRequest.setValue(uniqueBetas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.httpBody = try request.jsonData()
        return urlRequest
    }

    /// Starts a streaming request. Cancelling the consuming task cancels the HTTP request.
    public func stream(_ request: MessagesRequest, betas: [String] = []) -> AsyncThrowingStream<TimedStreamEvent, Error> {
        var streamingRequest = request
        streamingRequest.stream = true
        let urlRequest: URLRequest
        do {
            urlRequest = try makeURLRequest(streamingRequest, betas: betas)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: AnthropicError.decoding("encode request: \(error)")) }
        }

        return AsyncThrowingStream { continuation in
            let delegate = SSEStreamDelegate(continuation: continuation)
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1  // serializes all delegate callbacks
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: queue)
            let task = TaskBox(session.dataTask(with: urlRequest))
            continuation.onTermination = { termination in
                if case .cancelled = termination { task.value.cancel() }
            }
            task.value.resume()
        }
    }
}

/// URLSessionTask is thread-safe for cancel(); the box only satisfies Sendable checking.
private final class TaskBox: @unchecked Sendable {
    let value: URLSessionDataTask
    init(_ value: URLSessionDataTask) { self.value = value }
}

/// All callbacks arrive on one serial OperationQueue, so mutable state needs no lock.
private final class SSEStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<TimedStreamEvent, Error>.Continuation
    private var parser = SSEParser()
    private var errorBody = Data()
    private var finished = false

    init(continuation: AsyncThrowingStream<TimedStreamEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    private func status(of task: URLSessionTask) -> Int {
        (task.response as? HTTPURLResponse)?.statusCode ?? 0
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished else { return }
        guard status(of: dataTask) == 200 else {
            errorBody.append(data)
            return
        }
        for sse in parser.feed(data) {
            let receivedAt = MonotonicClock.now()
            do {
                let event = try StreamEvent.decode(Data(sse.data.utf8))
                continuation.yield(TimedStreamEvent(event: event, receivedAt: receivedAt))
                if case .error(let body) = event {
                    finish(throwing: AnthropicError.stream(body))
                    dataTask.cancel()
                    return
                }
            } catch {
                finish(throwing: AnthropicError.decoding("\(error) in event: \(sse.data.prefix(200))"))
                dataTask.cancel()
                return
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }  // releases this delegate
        guard !finished else { return }
        let status = status(of: task)
        if let error {
            finish(throwing: AnthropicError.transport(error.localizedDescription))
        } else if status != 200 {
            let body = try? JSONDecoder().decode(ErrorResponse.self, from: errorBody).error
            let requestID = (task.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "request-id")
            finish(throwing: AnthropicError.http(status: status, body: body, requestID: requestID))
        } else {
            parser.finish()
            finish(throwing: nil)
        }
    }

    private func finish(throwing error: Error?) {
        guard !finished else { return }
        finished = true
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }

    private struct ErrorResponse: Decodable { let error: APIErrorBody }
}
