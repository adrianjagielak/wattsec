//
//  DiagnosticsLogger.swift
//  WattSec
//
//  Appends one JSON line per sampling tick (200ms) with every raw value the
//  app reads: SMC watts each tick, per-channel IOReport watts on the ticks
//  where a fresh ~1s delta arrived, and the complete AppleSmartBattery
//  property table on the ticks where a fresh ~1s gauge read arrived
//  (PowerTelemetryData / BatteryData / ChargerData / AdapterDetails /
//  CellVoltage / PowerOutDetails included), plus the app's derived values.
//
//  Sources are logged at the rate they actually update — SMC 5 Hz, IOReport
//  and battery ~1 Hz — because logging a source faster than it refreshes
//  duplicates bytes without adding information.
//
//  Purpose: collect days of real-world data on real hardware, then fit
//  calibration offline — charger efficiency, the user-facing % ↔ raw
//  capacity mapping (macOS pins % near full and reserves near empty),
//  telemetry sign/scale, PSTR↔IOReport residual behavior — and fold the
//  fitted constants back into the app.
//
//  Files:  ~/Library/Logs/WattSec/wattsec-YYYY-MM-DD.jsonl
//  Volume: roughly 300-400 MB/day. Rotation: one file per UTC day, hard cap
//  1 GB/day, pruned after 14 days (~5 GB worst case on disk).
//  Each file (and each app launch) starts with a {"type":"meta"} line
//  identifying the machine, OS, and app version.
//

import Foundation

final class DiagnosticsLogger {
    static let shared = DiagnosticsLogger()

    private static let enabledDefaultsKey = "diagnosticsLoggingEnabled"
    private static let dailyByteCap: UInt64 = 1 << 30 // 1 GB/day
    private static let flushByteThreshold = 64 * 1024
    private static let flushInterval: TimeInterval = 2.0

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
    private var buffer = Data()
    private var lastFlush = Date()
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
    /// Writes are buffered and flushed in ~2s batches so the 5 Hz record
    /// rate doesn't turn into 5 file writes per second.
    func log(_ record: [String: Any]) {
        guard isEnabled else { return }
        let now = Date()
        queue.async { [self] in
            guard var entry = sanitize(record, depth: 0) as? [String: Any] else { return }
            entry["ts"] = timestampFormatter.string(from: now)
            guard JSONSerialization.isValidJSONObject(entry),
                  let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            else { return }
            buffer.append(data)
            buffer.append(0x0A) // newline
            if buffer.count > Self.flushByteThreshold
                || now.timeIntervalSince(lastFlush) > Self.flushInterval {
                flush(day: dayFormatter.string(from: now))
            }
        }
    }

    // MARK: - Private

    private func flush(day: String) {
        openHandleIfNeeded(day: day)
        lastFlush = Date()
        guard let handle = handle else {
            buffer.removeAll(keepingCapacity: true)
            return
        }
        // Hard cap per day so a bug can never fill the disk
        if let offset = try? handle.offset(), offset > Self.dailyByteCap {
            buffer.removeAll(keepingCapacity: true)
            return
        }
        try? handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    private func openHandleIfNeeded(day: String) {
        guard handle == nil || handleDay != day else { return }
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
        writeMetaRecord()
    }

    /// Session/machine marker, written on every file open (app launch and
    /// day rollover) — needed to interpret the data per-machine offline.
    private func writeMetaRecord() {
        var meta: [String: Any] = [
            "type": "meta",
            "ts": timestampFormatter.string(from: Date()),
            "model": Self.hardwareModel(),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            meta["app"] = version
        }
        guard let data = try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]) else { return }
        var line = data
        line.append(0x0A)
        try? handle?.write(contentsOf: line)
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
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
