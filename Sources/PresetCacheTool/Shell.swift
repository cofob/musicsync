import Foundation

/// Running other tools: the Metal compiler and rclone.
enum Shell {
    /// Runs `tool` and returns its exit code, standard output and error output (from a file, so neither pipe fills).
    @discardableResult
    static func run(_ tool: String, _ arguments: [String], environment: [String: String]? = nil) -> (code: Int32, output: Data, errors: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let environment { process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        let errors = FileManager.default.temporaryDirectory.appendingPathComponent("preset-cache-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errors) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = try? FileHandle(forWritingTo: errors)
        do { try process.run() } catch { return (-1, Data(), "\(error)") }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output, (try? String(contentsOf: errors, encoding: .utf8)) ?? "")
    }

    /// Compiles MSL to a `.metallib` for "macos" or "ios"; false when the compiler rejects it.
    static func metallib(_ source: String, platform: String, to url: URL) -> Bool {
        let file = url.deletingPathExtension().appendingPathExtension("metal")
        guard (try? source.write(to: file, atomically: true, encoding: .utf8)) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: file) }
        let (sdk, version) = platform == "ios" ? ("iphoneos", "-mios-version-min=18.0") : ("macosx", "-mmacosx-version-min=15.0")
        let result = run("/usr/bin/xcrun", ["-sdk", sdk, "metal", version, "-o", url.path, file.path])
        if result.code != 0 { print("  \(platform) shader does not compile: \(result.errors.split(separator: "\n").prefix(2).joined(separator: " / "))") }
        return result.code == 0
    }
}

/// R2 through rclone's S3 backend, set up by `scripts/preset-cache.sh` in the environment (`RCLONE_S3_*`, with the
/// keys of `.env`). Nothing secret is printed: rclone hides the auth headers, and its messages lose the keys and
/// the endpoint.
struct Storage {
    let remote: String
    private(set) var requests = 0
    static let rclone = "/opt/homebrew/bin/rclone"

    init?(prefix: String) {
        guard let bucket = ProcessInfo.processInfo.environment["S3_BUCKET"], !bucket.isEmpty else { return nil }
        remote = ":s3:\(bucket)/\(prefix)"
    }

    /// Every key under the prefix.
    mutating func list() throws -> Set<String> {
        let result = try rclone(["lsf", "-R", "--files-only", remote], allow: [3])
        return Set(String(decoding: result, as: UTF8.self).split(separator: "\n").map(String.init))
    }

    mutating func read(_ key: String) throws -> Data { try rclone(["cat", "\(remote)/\(key)"]) }

    /// Uploads `files` of `folder` to `key/`, or one file to `key` when `files` is nil.
    mutating func upload(_ folder: URL, files: [String]? = nil, to key: String, type: String, cache: String) throws {
        var arguments = ["--no-check-dest", "--s3-no-head", "--header-upload", "Content-Type: \(type)", "--header-upload", "Cache-Control: \(cache)"]
        if let files {
            let list = FileManager.default.temporaryDirectory.appendingPathComponent("preset-cache-files-\(UUID().uuidString).txt")
            try files.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: list) }
            arguments = ["copy", folder.path, "\(remote)/\(key)", "--files-from", list.path, "--transfers", "8"] + arguments
            try rclone(arguments)
        } else {
            try rclone(["copyto", folder.path, "\(remote)/\(key)"] + arguments)
        }
    }

    /// Counts the HTTP requests rclone makes (from its header dump, which is not shown).
    @discardableResult
    private mutating func rclone(_ arguments: [String], allow: Set<Int32> = []) throws -> Data {
        let result = Shell.run(Self.rclone, arguments + ["--dump", "headers"])
        requests += result.errors.components(separatedBy: "HTTP REQUEST").count - 1
        guard result.code == 0 || allow.contains(result.code) else {
            let lines = result.errors.split(separator: "\n").filter { $0.contains("ERROR") || $0.contains("Failed") || $0.contains("NOTICE") }
            throw ToolError("rclone \(arguments[0]) failed (\(result.code)):\n" + Self.redact(lines.suffix(5).joined(separator: "\n")))
        }
        return result.output
    }

    private static func redact(_ text: String) -> String {
        let env = ProcessInfo.processInfo.environment
        let secrets = ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_ENDPOINT_URL", "RCLONE_S3_ENDPOINT"].compactMap { env[$0] }.filter { !$0.isEmpty }
        let hosts = secrets.compactMap { URL(string: $0)?.host }
        return (secrets + hosts).reduce(text) { $0.replacingOccurrences(of: $1, with: "***") }
    }
}

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
