//
//  DiagnosticsLogger.swift
//  WattSec
//
//  Appends one JSON line every few seconds with every raw value the app can
//  read (SMC watts, per-channel IOReport watts, the complete
//  AppleSmartBattery property table including PowerTelemetryData /
//  BatteryData / ChargerData / AdapterDetails) plus the app's derived values.
//
//  Purpose: collect days of real-world data on real hardware, then fit
//  calibration offline — charger efficiency, the user-facing % ↔ raw
//  capacity mapping (macOS pins % near full and reserves near empty),
//  telemetry sign/scale, PSTR↔IOReport residual behavior — and fold the
//  fitted constants back into the app.
//
//  Files:  ~/Library/Logs/WattSec/wattsec-YYYY-MM-DD.jsonl
//  Volume: roughly 20-40 MB/day at a 5 s cadence (raw dump dominates).
//  Rotation: one file per UTC day, hard cap 64 MB/day, pruned after 14 days.
//

import Foundation

final class DiagnosticsLogger {
    static let shared = DiagnosticsLogger()

    private static let enabledDefaultsKey = "diagnosticsLoggingEnabled"

    /// Enabled by default — this build's whole point is data collection.
    var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledDefaultsKey) }
    }

    static var logDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("WattSec", isDirectory: true)
    }

    private let queue = DispatchQueue(label: "WattSec.DiagnosticsLogger", qos: .utility)
    private var handle: FileHandle?
    private var handleDay: String?
    private let dayFormatter: DateFormatter
    private let timestampFormatter: ISO8601DateFormatter

    private init() {
        dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone(identifier: "UTC")
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        queue.async { [weak self] in self?.pruneOldLogs() }
    }

    /// Append one record. Values that can't be represented in JSON
    /// (Data blobs, IOKit objects) are stripped, everything else is kept.
    func log(_ record: [String: Any]) {
        guard isEnabled else { return }
        let now = Date()
        queue.async { [self] in
            guard var entry = sanitize(record, depth: 0) as? [String: Any] else { return }
            entry["ts"] = timestampFormatter.string(from: now)
            guard JSONSerialization.isValidJSONObject(entry),
                  var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            else { return }
            data.append(0x0A) // newline
            write(data, day: dayFormatter.string(from: now))
        }
    }

    // MARK: - Private

    private func write(_ data: Data, day: String) {
        if handle == nil || handleDay != day {
            try? handle?.close()
            handle = nil
            let dir = Self.logDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("wattsec-\(day).jsonl")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
            handleDay = day
        }
        guard let handle = handle else { return }
        // Hard cap per day so a bug can never fill the disk
        if let offset = try? handle.offset(), offset > 64 * 1024 * 1024 { return }
        try? handle.write(contentsOf: data)
    }

    private func pruneOldLogs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.logDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-14 * 24 * 3600)
        for url in files where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Keep numbers/strings/bools, recurse into dicts/arrays, drop the rest
    /// (Data blobs like LifetimeData, IOKit references, dates).
    private func sanitize(_ value: Any, depth: Int) -> Any? {
        guard depth < 5 else { return nil }
        switch value {
        case let number as NSNumber:
            // NaN/Infinity would make JSONSerialization throw
            let d = number.doubleValue
            return d.isFinite ? number : nil
        case let string as String:
            return string
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (key, inner) in dict {
                if let sanitized = sanitize(inner, depth: depth + 1) {
                    out[key] = sanitized
                }
            }
            return out
        case let array as [Any]:
            return array.compactMap { sanitize($0, depth: depth + 1) }
        default:
            return nil
        }
    }
}
