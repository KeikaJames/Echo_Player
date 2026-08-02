import Foundation

enum BoundedHTTPClient {
    enum RequestError: Error {
        case invalidResponse
        case responseTooLarge
    }

    static func data(for request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        try await Loader(maxBytes: maxBytes).load(request)
    }

    private final class Loader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let maxBytes: Int
        private let lock = NSLock()
        private var buffer = Data()
        private var response: HTTPURLResponse?
        private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var originalHost: String?
        private var finished = false

        init(maxBytes: Int) {
            self.maxBytes = max(1, maxBytes)
        }

        func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            guard request.url?.scheme?.lowercased() == "https",
                  let host = request.url?.host?.lowercased() else {
                throw RequestError.invalidResponse
            }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    guard !Task.isCancelled else {
                        lock.unlock()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.continuation = continuation
                    self.originalHost = host
                    let config = URLSessionConfiguration.ephemeral
                    config.timeoutIntervalForRequest = request.timeoutInterval
                    config.timeoutIntervalForResource = request.timeoutInterval
                    let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                    let task = session.dataTask(with: request)
                    self.session = session
                    self.task = task
                    lock.unlock()
                    task.resume()
                }
            } onCancel: {
                self.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            lock.lock()
            let originalHost = self.originalHost
            lock.unlock()
            guard request.url?.scheme?.lowercased() == "https",
                  request.url?.host?.lowercased() == originalHost else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else {
                completionHandler(.cancel)
                finish(.failure(RequestError.invalidResponse))
                return
            }
            if response.expectedContentLength > Int64(maxBytes) {
                completionHandler(.cancel)
                finish(.failure(RequestError.responseTooLarge))
                return
            }

            lock.lock()
            self.response = http
            if response.expectedContentLength > 0 {
                buffer.reserveCapacity(min(maxBytes, Int(response.expectedContentLength)))
            }
            lock.unlock()
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            let exceedsLimit = data.count > maxBytes - buffer.count
            if !exceedsLimit { buffer.append(data) }
            lock.unlock()

            if exceedsLimit {
                dataTask.cancel()
                finish(.failure(RequestError.responseTooLarge))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            if let error {
                finish(.failure(error))
                return
            }

            lock.lock()
            let data = buffer
            let response = self.response
            lock.unlock()
            guard let response else {
                finish(.failure(RequestError.invalidResponse))
                return
            }
            finish(.success((data, response)))
        }

        private func cancel() {
            lock.lock()
            let task = self.task
            lock.unlock()
            task?.cancel()
            finish(.failure(CancellationError()))
        }

        private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            let session = self.session
            self.session = nil
            self.task = nil
            self.originalHost = nil
            lock.unlock()

            session?.invalidateAndCancel()
            continuation?.resume(with: result)
        }
    }
}
