import Foundation

// #region agent log
/// Debug session logger. Writes NDJSON to workspace log file.
/// Call only from main thread (file I/O on audio thread causes glitches).
enum DebugLogger {
    private static let logPath = "/Users/leolambertini/RLTNAS/.cursor/debug-005899.log"
    private static let queue = DispatchQueue(label: "com.latentresonator.debuglog")

    static func log(location: String, message: String, data: [String: Any] = [:], hypothesisId: String = "") {
        queue.async {
            var payload: [String: Any] = [
                "sessionId": "005899",
                "timestamp": Int(Date().timeIntervalSince1970 * 1000),
                "location": location,
                "message": message,
                "data": data
            ]
            if !hypothesisId.isEmpty { payload["hypothesisId"] = hypothesisId }
            guard let json = try? JSONSerialization.data(withJSONObject: payload),
                  let line = String(data: json, encoding: .utf8) else { return }
            let entry = line + "\n"
            if FileManager.default.fileExists(atPath: logPath) {
                if let h = FileHandle(forWritingAtPath: logPath) {
                    h.seekToEndOfFile()
                    h.write(Data(entry.utf8))
                    h.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logPath, contents: Data(entry.utf8))
            }
        }
    }
}
// #endregion
