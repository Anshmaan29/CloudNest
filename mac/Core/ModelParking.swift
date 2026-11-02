import Foundation
import CryptoKit
import Darwin

public struct ModelParkingPreview: Sendable {
    public let source: URL
    public let approvedRoot: URL
    public let kind: String
    public let fileCount: Int
    public let logicalBytes: Int64
    public let metadataFingerprint: String
    public let isDirectory: Bool
}

/// Explicit, local-only inspection. Parking uses the ordinary verified archive
/// pipeline. No runtime is started, stopped, invoked or downloaded.
public enum ModelParking {
    private static let weights: Set<String> = ["gguf", "safetensors", "bin", "pt", "pth", "ckpt", "onnx", "model"]
    private static let metadata: Set<String> = ["json", "txt", "md", "tiktoken", "merges", "vocab"]

    public static func preview(source: URL, safety: FileSafety = FileSafety()) throws -> ModelParkingPreview {
        let source = source.standardizedFileURL
        try safety.validate(source, root: source)
        let components = source.pathComponents.map { $0.lowercased() }
        guard !components.contains(where: { [".ssh", ".aws", ".config", "tokens", "token", "credentials"].contains($0) }),
              source.lastPathComponent.lowercased() != ".ollama",
              !(components.contains("huggingface") && !components.contains("snapshots")) else {
            throw NestError.unsafePath("select portable model weights or an exported model folder, not credentials or a shared cache root")
        }
        var info = stat()
        guard lstat(source.path, &info) == 0 else { throw NestError.sourceChanged }
        let directory = info.st_mode & S_IFMT == S_IFDIR
        guard directory || info.st_mode & S_IFMT == S_IFREG else { throw NestError.unsafePath("not a regular model file or directory") }
        let ollama = directory && source.lastPathComponent == "models" && source.deletingLastPathComponent().lastPathComponent == ".ollama"
        var files: [URL] = [source]
        if directory {
            var failed = false
            guard let walk = FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in failed = true; return false }) else { throw NestError.invalidResponse }
            files = []
            for case let file as URL in walk {
                try Task.checkCancellation()
                guard files.count < 100_000 else { throw NestError.unsafePath("model folder exceeds the 100,000-entry inspection budget; select a smaller export") }
                files.append(file)
            }
            guard !failed else { throw NestError.unsafePath("model folder could not be completely inspected") }
        }
        var hash = SHA256(), bytes: Int64 = 0, count = 0, weightCount = 0
        hash.update(data: Data("root:\(info.st_dev):\(info.st_ino):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)\n".utf8))
        for file in files.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            try safety.validate(file, root: source)
            var value = stat()
            guard lstat(file.path, &value) == 0 else { throw NestError.sourceChanged }
            let relative = String(file.path.dropFirst(source.path.count))
            let name = file.lastPathComponent.lowercased()
            guard !name.hasPrefix("."), !["token", "tokens", "credentials", "id_ed25519", "id_rsa"].contains(name),
                  !name.contains("secret"), !name.contains("credential"),
                  !["token", "tokens", "auth", "api_key", "apikey", "id_ed25519", "id_rsa"].contains(file.deletingPathExtension().lastPathComponent.lowercased()), !name.hasSuffix(".lock"), !name.hasSuffix(".partial"), !name.hasSuffix(".tmp") else {
                throw NestError.unsafePath("model selection contains private, temporary or lock files; create a portable export")
            }
            if value.st_mode & S_IFMT == S_IFREG {
                let ext = file.pathExtension.lowercased()
                let blob = ollama && relative.hasPrefix("/blobs/") && name.range(of: "^sha256-[a-f0-9]{64}$", options: .regularExpression) != nil
                let manifest = ollama && relative.hasPrefix("/manifests/")
                guard weights.contains(ext) || metadata.contains(ext) || blob || manifest else { throw NestError.unsafePath("folder contains non-model content; select a portable model export") }
                guard value.st_size >= 0, bytes <= Int64.max - value.st_size else { throw NestError.invalidResponse }
                bytes += value.st_size; count += 1
                if weights.contains(ext) || blob { weightCount += 1 }
            } else if value.st_mode & S_IFMT != S_IFDIR { throw NestError.unsafePath("model folder contains a link or special file; export regular files first") }
            hash.update(data: Data("\(relative.utf8.count):\(relative):\(value.st_dev):\(value.st_ino):\(value.st_mode):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)\n".utf8))
        }
        guard weightCount > 0 else { throw NestError.unsafePath("no recognized model weights found") }
        try requireInactive(source: source, isDirectory: directory)
        return ModelParkingPreview(source: source, approvedRoot: directory ? source : source.deletingLastPathComponent(), kind: ollama ? "Ollama model store" : "Portable model", fileCount: count, logicalBytes: bytes, metadataFingerprint: hash.finalize().map { String(format: "%02x", $0) }.joined(), isDirectory: directory)
    }

    public static func revalidate(_ approved: ModelParkingPreview, safety: FileSafety = FileSafety()) throws {
        let current = try preview(source: approved.source, safety: safety)
        guard current.metadataFingerprint == approved.metadataFingerprint, current.isDirectory == approved.isDirectory,
              current.fileCount == approved.fileCount, current.logicalBytes == approved.logicalBytes else { throw NestError.sourceChanged }
    }

    public static func validateRestoreDestination(_ destination: URL, root: URL, isDirectory: Bool, safety: FileSafety = FileSafety()) throws {
        try safety.validateDestination(destination, root: root)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw NestError.unsafePath("restore destination already exists; choose a new location") }
        try requireInactive(source: destination, isDirectory: isDirectory)
    }

    /// Also works when the original has been reclaimed: known runtime processes
    /// still block a restore, and its existing parent is inspected for open use.
    public static func requireInactive(source: URL, isDirectory: Bool) throws {
        let processes = try output(executable: "/bin/ps", arguments: ["-axo", "comm="], accepted: [0])
        guard !processes.split(separator: "\n").contains(where: { line in
            let name = URL(fileURLWithPath: String(line).trimmingCharacters(in: .whitespaces)).lastPathComponent.lowercased()
            return ["ollama", "ollama_llama_server", "llama-server", "llama-cli", "llama.cpp", "lm studio", "lm-studio", "lms", "mlx_lm", "vllm"].contains(name) || name.hasPrefix("ollama ") || name.hasPrefix("lm studio")
        }) else { throw NestError.unsafePath("a local model runtime is running; quit it before parking or restoring models") }
        let existing = FileManager.default.fileExists(atPath: source.path)
        let inspected = existing ? source : source.deletingLastPathComponent()
        let args = (existing && !isDirectory) ? ["-Fpn", "--", inspected.path] : ["-Fpn", "+D", inspected.path]
        let uses = try output(executable: "/usr/sbin/lsof", arguments: args, accepted: [0, 1])
        let pids = uses.split(separator: "\n").filter { $0.hasPrefix("p") }.compactMap { Int32($0.dropFirst()) }
        guard !pids.contains(where: { $0 != getpid() }) else { throw NestError.unsafePath("model files or their restore parent are open in another process; close it and retry") }
    }

    private static func output(executable: String, arguments: [String], accepted: Set<Int32>) throws -> String {
        let process = Process(), pipe = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = errors
        let done = DispatchSemaphore(value: 0); process.terminationHandler = { _ in done.signal() }
        try process.run(); try? pipe.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        defer {
            if process.isRunning { process.terminate(); if done.wait(timeout: .now() + 1) == .timedOut { _ = kill(process.processIdentifier, SIGKILL) } }
            try? pipe.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
        }
        let handles = [pipe.fileHandleForReading, errors.fileHandleForReading]
        for handle in handles { let fd = handle.fileDescriptor; _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        var results = [Data(), Data()], eof = [false, false]
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while process.isRunning || !eof.allSatisfy({ $0 }) {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw NestError.unsafePath("model-use check timed out; status is uncertain") }
            for i in handles.indices where !eof[i] {
                var buffer = [UInt8](repeating: 0, count: 8192)
                let n = read(handles[i].fileDescriptor, &buffer, buffer.count)
                if n > 0 {
                    guard results[i].count + n <= 1_048_576 else { throw NestError.unsafePath("model-use check exceeded its output budget") }
                    results[i].append(contentsOf: buffer.prefix(n))
                } else if n == 0 { eof[i] = true }
                else if errno != EAGAIN && errno != EINTR { throw NestError.invalidResponse }
            }
            usleep(10_000)
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit, accepted.contains(process.terminationStatus), results[1].isEmpty,
              let text = String(data: results[0], encoding: .utf8) else { throw NestError.unsafePath("model-use status could not be established; no archive or restore was started") }
        return text
    }
}
