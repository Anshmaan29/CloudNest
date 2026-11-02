import Testing
import Foundation
import Darwin
@testable import CloudNestCore

private struct ModelFixture {
    let base: URL
    init() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        base = repo.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("work/model-parking-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    func clean() { try? FileManager.default.removeItem(at: base) }
    func write(_ name: String, _ text: String = "disposable weights") throws -> URL {
        let url = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url); return url
    }
}

@Test func modelParkingReviewsPortableWeightsAndDetectsReplacement() throws {
    let f = try ModelFixture(); defer { f.clean() }
    let source = try f.write("export/model.gguf")
    let preview = try ModelParking.preview(source: source)
    #expect(!preview.isDirectory && preview.fileCount == 1 && preview.logicalBytes == 18)
    try ModelParking.revalidate(preview)
    try Data("changed weights".utf8).write(to: source)
    #expect(throws: (any Error).self) { try ModelParking.revalidate(preview) }
}

@Test func modelParkingRefusesCredentialsLinksAndActiveRepositories() throws {
    let f = try ModelFixture(); defer { f.clean() }
    _ = try f.write("export/model.safetensors")
    _ = try f.write("export/token")
    #expect(throws: (any Error).self) { try ModelParking.preview(source: f.base.appendingPathComponent("export")) }
    try FileManager.default.removeItem(at: f.base.appendingPathComponent("export/token"))
    try FileManager.default.createSymbolicLink(at: f.base.appendingPathComponent("export/linked.gguf"), withDestinationURL: f.base.appendingPathComponent("export/model.safetensors"))
    #expect(throws: (any Error).self) { try ModelParking.preview(source: f.base.appendingPathComponent("export")) }
    _ = try f.write("project/.git/HEAD", "ref: refs/heads/main")
    let project = try f.write("project/model.gguf")
    #expect(throws: (any Error).self) { try ModelParking.preview(source: project) }
    _ = try f.write(".ollama/id_ed25519", "private fixture")
    #expect(throws: (any Error).self) { try ModelParking.preview(source: f.base.appendingPathComponent(".ollama")) }
}

@Test func modelParkingPreservesCompleteOllamaBlobsAndLibraryManifests() throws {
    let f = try ModelFixture(); defer { f.clean() }
    _ = try f.write(".ollama/models/blobs/sha256-" + String(repeating: "a", count: 64))
    _ = try f.write(".ollama/models/manifests/registry.ollama.ai/library/example/latest", "{}")
    let preview = try ModelParking.preview(source: f.base.appendingPathComponent(".ollama/models"))
    #expect(preview.kind == "Ollama model store" && preview.fileCount == 2)
}

@Test func modelParkingRefusesOpenModelAndAllowsAbsentRestoreName() throws {
    let f = try ModelFixture(); defer { f.clean() }
    let source = try f.write("model.gguf")
    let reader = Process(); reader.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
    reader.arguments = ["-f", source.path]; reader.standardOutput = FileHandle.nullDevice; reader.standardError = FileHandle.nullDevice
    try reader.run(); defer { if reader.isRunning { reader.terminate(); reader.waitUntilExit() } }
    usleep(150_000)
    #expect(throws: (any Error).self) { try ModelParking.requireInactive(source: source, isDirectory: false) }
    reader.terminate(); reader.waitUntilExit()
    try ModelParking.validateRestoreDestination(f.base.appendingPathComponent("restored.gguf"), root: f.base, isDirectory: false)
    #expect(throws: (any Error).self) { try ModelParking.validateRestoreDestination(source, root: f.base, isDirectory: false) }
}

@Test func modelParkingLibraryPolicyProtectsRealRootsWithoutBlockingNestedManifests() throws {
    let safety = FileSafety(), f = try ModelFixture(); defer { f.clean() }
    let nested = try f.write("ordinary/library/model.gguf")
    try safety.validate(nested, root: f.base)
    #expect(throws: (any Error).self) { try safety.validatePolicy(URL(fileURLWithPath: "/Library/model.gguf"), root: URL(fileURLWithPath: "/Library")) }
    #expect(throws: (any Error).self) { try safety.validatePolicy(URL(fileURLWithPath: "/Users/fixture/Library/models/model.gguf"), root: URL(fileURLWithPath: "/Users/fixture")) }
    #expect(throws: (any Error).self) { try safety.validate(nested, root: f.base.deletingLastPathComponent().appendingPathComponent("different")) }
    #expect(throws: (any Error).self) { try ModelParking.preview(source: f.base.appendingPathComponent("ordinary"), safety: FileSafety(protectedRoots: [f.base])) }
}
