import Testing
import Foundation
@testable import CloudNestCore

@Test func streamedDownloadWritesChunksAndRejectsUnexpectedLength() async throws {
    let f = try Fixture(); defer { f.clean() }
    let destination = f.base.appendingPathComponent("stream.bin")
    FileManager.default.createFile(atPath: destination.path, contents: nil)
    let file = try FileHandle(forWritingTo: destination); defer { try? file.close() }
    let (results, completion) = AsyncStream<Result<Void, any Error>>.makeStream()
    let sink = StreamDownload(destination: file, maximumBytes: 6) { completion.yield($0); completion.finish() }
    let session = URLSession(configuration: .ephemeral), url = URL(string: "https://www.googleapis.com/test-not-requested")!
    let task = session.dataTask(with: url); defer { task.cancel(); session.invalidateAndCancel() }
    sink.urlSession(session, dataTask: task, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!) { #expect($0 == .allow) }
    sink.urlSession(session, dataTask: task, didReceive: Data("abc".utf8))
    sink.urlSession(session, dataTask: task, didReceive: Data("def".utf8))
    sink.urlSession(session, task: task, didCompleteWithError: nil)
    for await result in results { try result.get() }
    #expect(try Data(contentsOf: destination) == Data("abcdef".utf8))
}

@Test func streamedDownloadNeverWritesBeyondManifestSize() async throws {
    let f = try Fixture(); defer { f.clean() }
    let destination = f.base.appendingPathComponent("bounded.bin")
    FileManager.default.createFile(atPath: destination.path, contents: nil)
    let file = try FileHandle(forWritingTo: destination); defer { try? file.close() }
    let (results, completion) = AsyncStream<Result<Void, any Error>>.makeStream()
    let sink = StreamDownload(destination: file, maximumBytes: 3) { completion.yield($0); completion.finish() }
    let session = URLSession(configuration: .ephemeral), task = session.dataTask(with: URL(string: "https://www.googleapis.com/not-requested")!)
    defer { task.cancel(); session.invalidateAndCancel() }
    sink.urlSession(session, dataTask: task, didReceive: Data("toolong".utf8))
    sink.urlSession(session, task: task, didCompleteWithError: nil)
    for await result in results { #expect(throws: (any Error).self) { try result.get() } }
    #expect(try Data(contentsOf: destination).isEmpty)
}

@Test func streamedDownloadRejectsHttpErrorsAndRedirects() async throws {
    let f = try Fixture(); defer { f.clean() }
    let file = try FileHandle(forWritingTo: f.source); defer { try? file.close() }
    let (results, completion) = AsyncStream<Result<Void, any Error>>.makeStream()
    let sink = StreamDownload(destination: file, maximumBytes: 3) { completion.yield($0); completion.finish() }
    let session = URLSession(configuration: .ephemeral), url = URL(string: "https://www.googleapis.com/not-requested")!
    let task = session.dataTask(with: url); defer { task.cancel(); session.invalidateAndCancel() }
    let redirect = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://attacker.example"])!
    sink.urlSession(session, task: task, willPerformHTTPRedirection: redirect, newRequest: URLRequest(url: URL(string: "https://attacker.example")!)) { #expect($0 == nil) }
    sink.urlSession(session, dataTask: task, didReceive: HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!) { #expect($0 == .cancel) }
    sink.urlSession(session, task: task, didCompleteWithError: nil)
    for await result in results { #expect(throws: (any Error).self) { try result.get() } }
}
