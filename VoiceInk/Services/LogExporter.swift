import Foundation
import OSLog

struct LogExportRetentionPolicy: Equatable, Sendable {
    static let voiceInkDefault = LogExportRetentionPolicy(
        maximumAge: 7 * 24 * 60 * 60,
        maximumBytes: 50 * 1_024 * 1_024
    )

    let maximumAge: TimeInterval
    let maximumBytes: Int

    func cutoffDate(relativeTo date: Date) -> Date {
        date.addingTimeInterval(-maximumAge)
    }
}

struct BoundedDiagnosticLogBuffer {
    private let maximumBytes: Int
    private var storage: [(line: String, bytes: Int)] = []
    private var headIndex = 0
    private(set) var byteCount = 0
    private(set) var droppedLineCount = 0

    init(maximumBytes: Int) {
        self.maximumBytes = max(0, maximumBytes)
    }

    mutating func append(_ line: String) {
        guard maximumBytes > 1 else {
            droppedLineCount += 1
            return
        }

        var retainedLine = line
        var retainedBytes = line.lengthOfBytes(using: .utf8) + 1
        if retainedBytes > maximumBytes {
            let prefix = Data(line.utf8).prefix(maximumBytes - 1)
            retainedLine = String(decoding: prefix, as: UTF8.self)
            retainedBytes = retainedLine.lengthOfBytes(using: .utf8) + 1
        }

        storage.append((retainedLine, retainedBytes))
        byteCount += retainedBytes

        while byteCount > maximumBytes, headIndex < storage.count {
            byteCount -= storage[headIndex].bytes
            headIndex += 1
            droppedLineCount += 1
        }

        if headIndex > 1_024, headIndex * 2 > storage.count {
            storage.removeFirst(headIndex)
            headIndex = 0
        }
    }

    var lines: [String] {
        guard headIndex < storage.count else { return [] }
        return storage[headIndex...].map { $0.line }
    }
}

final class LogExporter {
    static let shared = LogExporter()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "LogExporter")
    private let subsystem = "com.prakashjoshipax.voiceink"
    private let maxSessionsToKeep = 100
    private let sessionsKey = "logExporter.sessionStartDates.v1"
    private let retentionPolicy = LogExportRetentionPolicy.voiceInkDefault

    private(set) var sessionStartDates: [Date] = []

    private init() {
        var loadedDates: [Date] = []
        if let data = UserDefaults.standard.data(forKey: sessionsKey),
            let dates = try? JSONDecoder().decode([Date].self, from: data)
        {
            loadedDates = dates
        }

        let now = Date()
        let cutoffDate = retentionPolicy.cutoffDate(relativeTo: now)
        sessionStartDates = [now] + loadedDates.filter { $0 >= cutoffDate && $0 <= now }
        sessionStartDates = Array(sessionStartDates.prefix(maxSessionsToKeep))
        saveSessions()

        logger.notice("🎙️ LogExporter initialized, \(self.sessionStartDates.count, privacy: .public) session(s) tracked")
    }

    private func saveSessions() {
        if let data = try? JSONEncoder().encode(sessionStartDates) {
            UserDefaults.standard.set(data, forKey: sessionsKey)
        }
    }

    func exportLogs() async throws -> URL {
        logger.notice("🎙️ Starting log export")

        let logs = try await fetchLogs()
        let fileURL = try saveLogsToFile(logs)

        logger.notice("🎙️ Log export completed: \(fileURL.path, privacy: .public)")
        return fileURL
    }

    private func fetchLogs() async throws -> [String] {
        let systemInfo = await MainActor.run {
            SystemInfoService.shared.getSystemInfoString()
        }

        let store = try OSLogStore(scope: .system)
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)

        let now = Date()
        let cutoffDate = retentionPolicy.cutoffDate(relativeTo: now)
        var headerLines: [String] = []
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        headerLines.append("=== VoiceInk Diagnostic Logs ===")
        headerLines.append("Export Date: \(dateFormatter.string(from: now))")
        headerLines.append("Subsystem: \(subsystem)")
        headerLines.append("Retention: newest logs from at most 7 days, export capped at 50 MiB")
        headerLines.append("Oldest Included Date: \(dateFormatter.string(from: cutoffDate))")
        headerLines.append("Total Sessions: \(sessionStartDates.count)")
        headerLines.append("================================")
        headerLines.append("")
        headerLines.append(systemInfo)
        headerLines.append("")

        let headerBytes = headerLines.joined(separator: "\n").lengthOfBytes(using: .utf8) + 1
        let truncationNoticeReserve = 512
        var boundedLogs = BoundedDiagnosticLogBuffer(
            maximumBytes: max(0, retentionPolicy.maximumBytes - headerBytes - truncationNoticeReserve)
        )

        // Build session ranges with labels
        let totalSessions = sessionStartDates.count
        var sessionRanges: [(label: String, start: Date, end: Date?)] = []

        for i in 0..<totalSessions {
            let start = max(sessionStartDates[i], cutoffDate)
            let end: Date? = (i == 0) ? nil : sessionStartDates[i - 1]
            if let end, end <= cutoffDate { continue }
            let sessionNumber = totalSessions - i

            let label: String
            if totalSessions == 1 {
                label = "Session 1 (Current)"
            } else if i == 0 {
                label = "Session \(sessionNumber) (Current)"
            } else if i == totalSessions - 1 {
                label = "Session 1 (Oldest)"
            } else {
                label = "Session \(sessionNumber)"
            }

            sessionRanges.append((label, start, end))
        }

        // Fetch logs for each session (oldest first for chronological order)
        for (label, startDate, endDate) in sessionRanges.reversed() {
            boundedLogs.append("--- \(label) ---")
            boundedLogs.append("")

            let position = store.position(date: startDate)
            let entries = try store.getEntries(at: position, matching: predicate)

            var sessionLogCount = 0
            for entry in entries {
                guard let logEntry = entry as? OSLogEntryLog else { continue }

                if let endDate, logEntry.date >= endDate { break }

                let timestamp = dateFormatter.string(from: logEntry.date)
                let level = logLevelString(logEntry.level)
                let category = logEntry.category
                let message = logEntry.composedMessage

                boundedLogs.append("[\(timestamp)] [\(level)] [\(category)] \(message)")
                sessionLogCount += 1
            }

            if sessionLogCount == 0 {
                boundedLogs.append("No logs found for this session.")
            }

            boundedLogs.append("")
        }

        if boundedLogs.droppedLineCount > 0 {
            headerLines.append(
                "NOTICE: \(boundedLogs.droppedLineCount) older log line(s) were omitted to keep this export under 50 MiB."
            )
            headerLines.append("")
        }
        return headerLines + boundedLogs.lines
    }

    private func logLevelString(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .undefined: return "UNDEFINED"
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        @unknown default: return "UNKNOWN"
        }
    }

    private func saveLogsToFile(_ logs: [String]) throws -> URL {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = dateFormatter.string(from: Date())
        let fileName = "VoiceInk_Logs_\(timestamp).log"

        guard let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw NSError(
                domain: "LogExporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Downloads directory unavailable"]
            )
        }

        let fileURL = downloadsURL.appendingPathComponent(fileName)
        let content = logs.joined(separator: "\n")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        return fileURL
    }
}
