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
        let source: String
        let modules: Set<String>
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
    private let cacheURL: URL
    private let executable: ImportCache.ExecutableIdentity?
    private let previous: ImportCache?
    private var files: [String: ImportCache.Entry] = [:]

    init(cacheURL: URL) {
        self.cacheURL = cacheURL
        executable = ImportCache.ExecutableIdentity.current()
        if let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(ImportCache.self, from: data),
           cache.version == 1, cache.executable == executable {
            previous = cache
        } else {
            previous = nil
        }
    }

    mutating func importedModuleNames(in paths: [URL]) throws -> Set<String> {
        // Do not backtrack across whole runs of masked, otherwise blank comment lines.
        let expression = try NSRegularExpression(
            pattern: #"(?m)^[^\S\r\n]*(?:(?:@[A-Za-z_][A-Za-z0-9_]*)(?:\([^)\r\n]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private|open)\s+)?import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([A-Za-z_][A-Za-z0-9_]*)"#
        )
        var modules = Set<String>()
        for path in paths {
            let source = try String(contentsOf: path, encoding: .utf8)
            let entry: ImportCache.Entry
            // Compare contents, not timestamps: edits with preserved metadata must invalidate.
            if let cached = previous?.files[path.path], cached.source == source {
                entry = cached
            } else {
                let sourceCode = sourceCodeOnly(source)
                let range = NSRange(sourceCode.startIndex..., in: sourceCode)
                let imports = expression.matches(in: sourceCode, range: range).compactMap { match -> String? in
                    guard let moduleRange = Range(match.range(at: 1), in: sourceCode) else {
                        return nil
                    }
                    return String(sourceCode[moduleRange])
                }
                entry = ImportCache.Entry(source: source, modules: Set(imports))
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
        let cache = ImportCache(version: 1, executable: executable, files: files)
        guard cache != previous else {
            return
        }
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
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
