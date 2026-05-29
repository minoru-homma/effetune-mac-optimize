import Foundation

/// Lightweight diagnostics logger. Writes to /tmp/effetune-native.log (readable
/// regardless of how the app was launched) and to stderr. Used to debug the
/// native engine / bridge without a Web Inspector.
public enum NLog {
    public static let path = "/tmp/effetune-native.log"
    private static let lock = NSLock()

    public static func log(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
        FileHandle.standardError.write(Data(line.utf8))
        lock.lock(); defer { lock.unlock() }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
        }
    }

    public static func reset(_ header: String) {
        try? "\(Date()) === \(header) ===\n".data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
    }
}

@inline(__always) public func nlog(_ msg: String) { NLog.log(msg) }
