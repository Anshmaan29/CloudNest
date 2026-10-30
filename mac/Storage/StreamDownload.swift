import Foundation

final class DownloadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func register(_ task: URLSessionTask) {
        lock.lock(); self.task = task; let cancel = cancelled; lock.unlock()
        if cancel { task.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let current = task; lock.unlock()
        current?.cancel()
    }
}

/// URLSession delivers bounded chunks on a serial delegate queue. The caller
/// owns the destination descriptor and only uses it again after completion.
final class StreamDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: FileHandle
    private let maximumBytes: Int64
    private let completion: @Sendable (Result<Void, any Error>) -> Void
    private var written: Int64 = 0
    private var failure: (any Error)?
    init(destination: FileHandle, maximumBytes: Int64, completion: @escaping @Sendable (Result<Void, any Error>) -> Void) {
        self.destination = destination; self.maximumBytes = maximumBytes; self.completion = completion
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            failure = NestError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            guard Int64(data.count) <= maximumBytes - written else { throw NestError.verificationFailed }
            try autoreleasepool { try destination.write(contentsOf: data) }
            written += Int64(data.count)
        } catch { failure = error; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        defer { session.finishTasksAndInvalidate() }
        if let failure = failure ?? error { completion(.failure(failure)) }
        else if written != maximumBytes { completion(.failure(NestError.verificationFailed)) }
        else { completion(.success(())) }
    }
}
