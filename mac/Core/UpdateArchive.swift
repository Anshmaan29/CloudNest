import CryptoKit
import Darwin
import Foundation

/// The updater accepts only CloudNest's audited, uncompressed ZIP encoding.
/// It does not invoke an archive tool or accept arbitrary bundle members.
struct UpdateArchive {
  static let required: Set<String> = [
    "Contents/Info.plist", "Contents/MacOS/CloudNest", "Contents/Resources/CloudNest.icns",
    "Contents/_CodeSignature/CodeResources", "Contents/Helpers/CloudNestUpdateHelper",
  ]
  static let optional: Set<String> = [
    "Contents/Resources/CloudNestGoogleClient.json",
    "Contents/Resources/CloudNestReleasePublisher.json", "Contents/CodeResources",
  ]
  static let directories = [
    "Contents", "Contents/MacOS", "Contents/Resources", "Contents/_CodeSignature",
    "Contents/Helpers",
  ]
  static let executables: Set<String> = [
    "Contents/MacOS/CloudNest", "Contents/Helpers/CloudNestUpdateHelper",
  ]
  struct Member: Sendable {
    let name: String
    let offset: Int64
    let bytes: Int
    let crc: UInt32
    let mode: mode_t
  }
  static func read(_ file: FileHandle, at offset: Int64, count: Int) throws -> Data {
    guard offset >= 0, count >= 0, count <= 65536 else { throw ReleaseUpdateError.integrity }
    try file.seek(toOffset: UInt64(offset))
    let data = try file.read(upToCount: count) ?? Data()
    guard data.count == count else { throw ReleaseUpdateError.integrity }
    return data
  }
  static func members(_ file: FileHandle, size: Int64) throws -> [Member] {
    guard size >= 22, size <= 209_715_200 else { throw ReleaseUpdateError.integrity }
    let end = try read(file, at: size - 22, count: 22)
    let count = Int(end.u16(10))
    let start = Int64(end.u32(16))
    let length = Int64(end.u32(12))
    guard end.u32(0) == 0x0605_4b50, end.u16(4) == 0, end.u16(6) == 0, end.u16(8) == count,
      end.u16(20) == 0,
      (required.count...required.count + optional.count).contains(count),
      start + length == size - 22, length <= 65536
    else { throw ReleaseUpdateError.integrity }
    var cursor = start
    var localEnd: Int64 = 0
    var seen = Set<String>()
    var result: [Member] = []
    for _ in 0..<count {
      try Task.checkCancellation()
      let header = try read(file, at: cursor, count: 46)
      let nameLength = Int(header.u16(28))
      let bytes = Int(header.u32(24))
      let offset = Int64(header.u32(42))
      let mode = mode_t(header.u32(38) >> 16)
      let crc = header.u32(16)
      guard header.u32(0) == 0x0201_4b50, header.u16(8) == 0x800, header.u16(10) == 0,
        header.u32(20) == bytes,
        header.u16(30) == 0, header.u16(32) == 0, header.u16(34) == 0,
        (1...256).contains(nameLength),
        bytes <= 209_715_200, cursor + 46 + Int64(nameLength) <= size - 22, offset == localEnd
      else { throw ReleaseUpdateError.integrity }
      let nameBytes = try read(file, at: cursor + 46, count: nameLength)
      guard let full = String(data: nameBytes, encoding: .utf8), full.hasPrefix("CloudNest.app/")
      else { throw ReleaseUpdateError.integrity }
      let name = String(full.dropFirst("CloudNest.app/".count))
      guard required.contains(name) || optional.contains(name), seen.insert(name).inserted,
        mode == (executables.contains(name) ? 0o100755 : 0o100644)
      else { throw ReleaseUpdateError.integrity }
      let local = try read(file, at: offset, count: 30)
      guard local.u32(0) == 0x0403_4b50, local.u16(6) == 0x800, local.u16(8) == 0,
        local.u32(14) == crc,
        local.u32(18) == bytes, local.u32(22) == bytes, local.u16(26) == nameLength,
        local.u16(28) == 0,
        try read(file, at: offset + 30, count: nameLength) == nameBytes
      else { throw ReleaseUpdateError.integrity }
      let payload = offset + 30 + Int64(nameLength)
      localEnd = payload + Int64(bytes)
      guard localEnd <= start else { throw ReleaseUpdateError.integrity }
      result.append(Member(name: name, offset: payload, bytes: bytes, crc: crc, mode: mode & 0o777))
      cursor += 46 + Int64(nameLength)
    }
    guard localEnd == start, cursor == size - 22, required.isSubset(of: seen) else {
      throw ReleaseUpdateError.integrity
    }
    return result
  }
  static func extract(_ artifact: URL, size: Int64, sha256: String, into parent: URL) throws -> URL
  {
    let parentFD = try ReleaseUpdate.privateDirectory(parent)
    defer { close(parentFD) }
    let archiveParent = try FileSafety.openDirectory(artifact.deletingLastPathComponent())
    defer { close(archiveParent) }
    let fd = openat(archiveParent, artifact.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw ReleaseUpdateError.unsafeStage }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? file.close() }
    var before = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
      before.st_uid == getuid(), before.st_size == size
    else { throw ReleaseUpdateError.unsafeStage }
    let snapshot = try FileSafety.snapshot(file)
    guard snapshot.identity.size == size, snapshot.sha256 == sha256 else {
      throw ReleaseUpdateError.integrity
    }
    let entries = try members(file, size: size)
    guard mkdirat(parentFD, "CloudNest.app", 0o755) == 0 else {
      throw ReleaseUpdateError.unsafeStage
    }
    let root = openat(parentFD, "CloudNest.app", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard root >= 0 else { throw ReleaseUpdateError.unsafeStage }
    defer { close(root) }
    for name in directories {
      let parts = name.split(separator: "/").map(String.init)
      let base = try openDirectory(Array(parts.dropLast()), root: root)
      defer { close(base) }
      guard mkdirat(base, parts.last!, 0o755) == 0 else { throw ReleaseUpdateError.unsafeStage }
    }
    for entry in entries {
      let parts = entry.name.split(separator: "/").map(String.init)
      let base = try openDirectory(Array(parts.dropLast()), root: root)
      defer { close(base) }
      let output = openat(
        base, parts.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, entry.mode)
      guard output >= 0 else { throw ReleaseUpdateError.unsafeStage }
      let handle = FileHandle(fileDescriptor: output, closeOnDealloc: true)
      defer { try? handle.close() }
      try file.seek(toOffset: UInt64(entry.offset))
      var remaining = entry.bytes
      var crc = UInt32.max
      while remaining > 0 {
        try Task.checkCancellation()
        let data = try file.read(upToCount: min(1_048_576, remaining)) ?? Data()
        guard !data.isEmpty else { throw ReleaseUpdateError.integrity }
        try handle.write(contentsOf: data)
        crc = CRC32.update(crc, data)
        remaining -= data.count
      }
      guard ~crc == entry.crc, fchmod(output, entry.mode) == 0 else {
        throw ReleaseUpdateError.integrity
      }
      try handle.synchronize()
      try handle.close()
      guard fsync(base) == 0 else { throw ReleaseUpdateError.unsafeStage }
    }
    var after = stat()
    var named = stat()
    guard fstat(fd, &after) == 0, FileSafety.identity(before) == FileSafety.identity(after),
      fstatat(archiveParent, artifact.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
      FileSafety.identity(named) == FileSafety.identity(after), fsync(root) == 0,
      fsync(parentFD) == 0
    else { throw ReleaseUpdateError.integrity }
    return parent.appendingPathComponent("CloudNest.app")
  }
  static func openDirectory(_ parts: [String], root: Int32) throws -> Int32 {
    var current = dup(root)
    guard current >= 0 else { throw ReleaseUpdateError.unsafeStage }
    do {
      for part in parts {
        let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard next >= 0 else { throw ReleaseUpdateError.unsafeStage }
        close(current)
        current = next
      }
      return current
    } catch {
      close(current)
      throw error
    }
  }
  private static func ownedWithoutACL(_ fd: Int32) throws {
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0,
      let security = filesec_init()
    else { throw ReleaseUpdateError.unsafeStage }
    defer { filesec_free(security) }
    var secured = stat()
    var acl: Int32 = 0
    guard fstatx_np(fd, &secured, security) == 0, secured.st_ino == info.st_ino,
      secured.st_dev == info.st_dev,
      filesec_query_property(security, FILESEC_ACL, &acl) == 0, acl == 0
    else { throw ReleaseUpdateError.unsafeStage }
  }
  static func inventory(_ app: URL) throws -> String {
    let root = try FileSafety.openDirectory(app)
    defer { close(root) }
    var digest = SHA256()
    var seen = Set<String>()
    func walk(_ parts: [String]) throws {
      let fd = try openDirectory(parts, root: root)
      defer { close(fd) }
      try ownedWithoutACL(fd)
      let stream = fdopendir(dup(fd))
      guard let stream else { throw ReleaseUpdateError.unsafeStage }
      defer { closedir(stream) }
      var names: [String] = []
      while let row = readdir(stream) {
        var name = row.pointee.d_name
        let capacity = MemoryLayout.size(ofValue: name)
        let string = withUnsafePointer(to: &name) { p in
          p.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
        if string != "." && string != ".." { names.append(string) }
      }
      for name in names.sorted() {
        let path = (parts + [name]).joined(separator: "/")
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_uid == getuid(),
          info.st_mode & 0o022 == 0
        else { throw ReleaseUpdateError.unsafeStage }
        if info.st_mode & S_IFMT == S_IFDIR {
          guard directories.contains(path) else { throw ReleaseUpdateError.integrity }
          try walk(parts + [name])
        } else {
          guard required.contains(path) || optional.contains(path), seen.insert(path).inserted,
            info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size <= 209_715_200
          else { throw ReleaseUpdateError.integrity }
          let f = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
          guard f >= 0 else { throw ReleaseUpdateError.unsafeStage }
          let handle = FileHandle(fileDescriptor: f, closeOnDealloc: true)
          defer { try? handle.close() }
          try ownedWithoutACL(f)
          let snapshot = try FileSafety.snapshot(handle)
          digest.update(
            data: Data(
              "\(path)\n\(info.st_mode&0o777)\n\(snapshot.identity.size)\n\(snapshot.sha256)\n".utf8
            ))
          var named = stat()
          guard fstatat(fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
            FileSafety.identity(named) == snapshot.identity
          else { throw ReleaseUpdateError.unsafeStage }
        }
      }
    }
    try walk([])
    guard required.isSubset(of: seen) else { throw ReleaseUpdateError.integrity }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
extension Data {
  fileprivate func u16(_ i: Int) -> UInt16 { UInt16(self[i]) | UInt16(self[i + 1]) << 8 }
  fileprivate func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
}
private enum CRC32 {
  static let table: [UInt32] = (0..<256).map { value in
    var c = UInt32(value)
    for _ in 0..<8 { c = (c & 1) == 1 ? 0xedb8_8320 ^ (c >> 1) : c >> 1 }
    return c
  }
  static func update(_ value: UInt32, _ data: Data) -> UInt32 {
    var c = value
    for b in data { c = table[Int((c ^ UInt32(b)) & 255)] ^ (c >> 8) }
    return c
  }
}
