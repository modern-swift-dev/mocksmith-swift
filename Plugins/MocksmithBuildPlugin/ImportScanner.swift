#if canImport(CryptoKit)
    import CryptoKit
#endif
import Foundation

private enum SourceRegion {
    case code
    case lineComment
    case blockComment(depth: Int)
    case string(hashes: Int, multiline: Bool)
}

/// Keep this cache private to plugin planning; it is not a generated target resource.
private struct ImportCache: Codable, Equatable {
    struct Entry: Codable, Equatable {
        /// SHA-256 of the file's bytes; compared instead of the text itself.
        let digest: String
        /// Observed before reading; `nil` when too recent to rule out a later edit in the same timestamp tick.
        let metadata: FileMetadata?
        let modules: Set<String>
    }

    /// Any write changes the change time, and `utime` cannot restore it, so edits
    /// that preserve size and modification time still invalidate.
    struct FileMetadata: Codable, Equatable {
        let size: Int64
        let inode: UInt64
        let modificationTime: Int64
        let changeTime: Int64

        init?(path: URL) {
            var info = stat()
            guard stat(path.path, &info) == 0 else {
                return nil
            }
            #if canImport(Darwin)
                let (modification, change) = (info.st_mtimespec, info.st_ctimespec)
            #else
                let (modification, change) = (info.st_mtim, info.st_ctim)
            #endif
            size = Int64(info.st_size)
            inode = UInt64(info.st_ino)
            modificationTime = Int64(modification.tv_sec) * 1_000_000_000 + Int64(modification.tv_nsec)
            changeTime = Int64(change.tv_sec) * 1_000_000_000 + Int64(change.tv_nsec)
        }
    }

    struct ExecutableIdentity: Codable, Equatable {
        let path: String
        let modificationDate: Date
        let size: UInt64
        let inode: UInt64

        static func current() -> Self? {
            guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath(),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path),
                  let modificationDate = attributes[.modificationDate] as? Date,
                  let size = attributes[.size] as? UInt64,
                  let inode = attributes[.systemFileNumber] as? UInt64 else {
                return nil
            }
            return Self(path: executable.path, modificationDate: modificationDate, size: size, inode: inode)
        }
    }

    let version: Int
    let executable: ExecutableIdentity
    let files: [String: Entry]
}

struct ImportScanner {
    /// Do not backtrack across whole runs of masked, otherwise blank comment lines.
    /// Statements start a line or follow a semicolon, as in `import A; import B`.
    private static let importExpression: NSRegularExpression = {
        do {
            return try NSRegularExpression(
                pattern: #"(?m)(?:^|;)[^\S\r\n]*(?:(?:@[A-Za-z_][A-Za-z0-9_]*)(?:\([^)\r\n]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private|open)\s+)?import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([A-Za-z_][A-Za-z0-9_]*)"#
            )
        } catch {
            preconditionFailure("invalid import pattern: \(error)")
        }
    }()

    private let cacheURL: URL
    private let executable: ImportCache.ExecutableIdentity?
    private let previous: ImportCache?
    private var files: [String: ImportCache.Entry] = [:]
    /// Files changed after this instant may still be edited within their current
    /// timestamp tick (up to 1 s on HFS+), so their metadata is not trusted.
    private let trustedChangeTime: Int64

    init(cacheURL: URL) {
        self.cacheURL = cacheURL
        trustedChangeTime = Int64((Date().timeIntervalSince1970 - 1) * 1_000_000_000)
        executable = ImportCache.ExecutableIdentity.current()
        if let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(ImportCache.self, from: data),
           cache.version == 3, cache.executable == executable {
            previous = cache
        } else {
            previous = nil
        }
    }

    mutating func importedModuleNames(in paths: [URL]) throws -> Set<String> {
        let expression = Self.importExpression
        var modules = Set<String>()
        for path in paths {
            let cached = previous?.files[path.path]
            let metadata = ImportCache.FileMetadata(path: path)
            let entry: ImportCache.Entry
            if let cached, let metadata, cached.metadata == metadata {
                entry = cached
            } else {
                let data = try Data(contentsOf: path)
                let digest = try Self.hexDigest(of: data, at: path)
                let trustedMetadata = metadata.flatMap { $0.changeTime < trustedChangeTime ? $0 : nil }
                // A touched file with unchanged contents keeps its imports without rescanning.
                if let cached, cached.digest == digest {
                    entry = ImportCache.Entry(digest: digest, metadata: trustedMetadata, modules: cached.modules)
                } else {
                    let sourceCode = try sourceCodeOnly(Self.utf8Source(data, at: path))
                    let range = NSRange(sourceCode.startIndex..., in: sourceCode)
                    let imports = expression.matches(in: sourceCode, range: range).compactMap { match -> String? in
                        guard let moduleRange = Range(match.range(at: 1), in: sourceCode) else {
                            return nil
                        }
                        return String(sourceCode[moduleRange])
                    }
                    entry = ImportCache.Entry(digest: digest, metadata: trustedMetadata, modules: Set(imports))
                }
            }
            files[path.path] = entry
            modules.formUnion(entry.modules)
        }
        return modules
    }

    func save() throws {
        guard let executable else {
            return
        }
        let cache = ImportCache(version: 3, executable: executable, files: files)
        guard cache != previous else {
            return
        }
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
    }

    /// SwiftPM builds plugins without optimization, where the portable SHA-256
    /// is several hundred times slower than CryptoKit.
    private static func hexDigest(of data: Data, at path: URL) throws -> String {
        #if canImport(CryptoKit)
            CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
            try SHA256.hexDigest(of: utf8Source(data, at: path))
        #endif
    }

    private static func utf8Source(_ data: Data, at path: URL) throws -> String {
        guard let source = String(bytes: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSFilePathErrorKey: path.path])
        }
        return source
    }

    private func sourceCodeOnly(_ source: String) -> String {
        let bytes = Array(source.utf8)
        var result = bytes
        var region = SourceRegion.code
        var index = 0

        func matches(_ pattern: [UInt8], at index: Int) -> Bool {
            index + pattern.count <= bytes.count
                && bytes[index ..< index + pattern.count].elementsEqual(pattern)
        }

        func mask(_ range: Range<Int>) {
            for offset in range where result[offset] != 10 && result[offset] != 13 {
                result[offset] = 32
            }
        }

        while index < bytes.count {
            switch region {
                case .code:
                    if bytes[index] != 47, bytes[index] != 35, bytes[index] != 34 {
                        index += 1
                        continue
                    }
                    if matches([47, 47], at: index) {
                        mask(index ..< index + 2)
                        index += 2
                        region = .lineComment
                    } else if bytes[index] == 47, matches([47, 42], at: index) {
                        mask(index ..< index + 2)
                        index += 2
                        region = .blockComment(depth: 1)
                    } else {
                        var quoteIndex = index
                        while quoteIndex < bytes.count, bytes[quoteIndex] == 35 {
                            quoteIndex += 1
                        }
                        guard quoteIndex < bytes.count, bytes[quoteIndex] == 34 else {
                            index += 1
                            continue
                        }
                        let hashes = quoteIndex - index
                        let multiline = matches([34, 34, 34], at: quoteIndex)
                        let openingLength = hashes + (multiline ? 3 : 1)
                        mask(index ..< index + openingLength)
                        index += openingLength
                        region = .string(hashes: hashes, multiline: multiline)
                    }

                case .lineComment:
                    if bytes[index] == 10 || bytes[index] == 13 {
                        index += 1
                        region = .code
                    } else {
                        result[index] = 32
                        index += 1
                    }

                case let .blockComment(depth):
                    if bytes[index] == 47, matches([47, 42], at: index) {
                        mask(index ..< index + 2)
                        index += 2
                        region = .blockComment(depth: depth + 1)
                    } else if bytes[index] == 42, matches([42, 47], at: index) {
                        mask(index ..< index + 2)
                        index += 2
                        region = depth == 1 ? .code : .blockComment(depth: depth - 1)
                    } else {
                        mask(index ..< index + 1)
                        index += 1
                    }

                case let .string(hashes, multiline):
                    if bytes[index] != 34, bytes[index] != 92 {
                        mask(index ..< index + 1)
                        index += 1
                        continue
                    }
                    let quotes = multiline ? [UInt8](repeating: 34, count: 3) : [34]
                    let closing = quotes + [UInt8](repeating: 35, count: hashes)
                    if matches(closing, at: index) {
                        mask(index ..< index + closing.count)
                        index += closing.count
                        region = .code
                    } else if hashes == 0, bytes[index] == 92, index + 1 < bytes.count {
                        mask(index ..< index + 2)
                        index += 2
                    } else {
                        mask(index ..< index + 1)
                        index += 1
                    }
            }
        }

        return String(bytes: result, encoding: .utf8) ?? ""
    }
}
