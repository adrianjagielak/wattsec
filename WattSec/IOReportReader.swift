//
//  IOReportReader.swift
//  WattSec
//
//  Reads per-component energy counters from Apple's private IOReport framework.
//  Uses dlopen/dlsym so no bridging header or linker flags are needed.
//
//  Supports all Apple Silicon variants (M1/M2/M3/M4 Base/Pro/Max/Ultra)
//  with robust channel name matching.
//
//  Key insight: Apple's reported "GPU power" only covers compute cores.
//  True GPU subsystem power = GPU compute + GPU SRAM. This reader tracks
//  both separately and provides a combined total.
//
//  No root access or special entitlements required.
//
//  This class is UI-independent and can be reused in any macOS app.
//

import Foundation

// MARK: - Power Breakdown Result

struct IOReportPowerBreakdown {
    /// E-cores + P-cores total
    var cpuWatts: Double = 0
    /// GPU compute cores only (Apple's reported number — understated)
    var gpuComputeWatts: Double = 0
    /// GPU SRAM (on-chip memory — often the biggest missing piece)
    var gpuSRAMWatts: Double = 0
    /// Apple Neural Engine
    var aneWatts: Double = 0
    /// DRAM (off-chip memory)
    var dramWatts: Double = 0
    /// Media engines, ISP, PCI, memory controllers, etc.
    /// Each entry: (human-readable label, watts)
    var otherComponents: [(label: String, watts: Double)] = []

    /// True GPU subsystem power: compute + SRAM
    var gpuTotalWatts: Double { gpuComputeWatts + gpuSRAMWatts }

    /// Sum of all metered components
    var totalMeteredWatts: Double {
        cpuWatts + gpuComputeWatts + gpuSRAMWatts + aneWatts + dramWatts
        + otherComponents.reduce(0) { $0 + $1.watts }
    }
}

// MARK: - IOReport Reader

final class IOReportReader {

    static let shared: IOReportReader? = IOReportReader()

    // MARK: - C function types

    private typealias CopyChannelsInGroupFn = @convention(c) (
        CFString, CFString?, UInt64, UInt64, UInt64
    ) -> Unmanaged<CFDictionary>?

    private typealias MergeChannelsFn = @convention(c) (
        CFDictionary, CFDictionary, CFTypeRef?
    ) -> Void

    private typealias CreateSubscriptionFn = @convention(c) (
        UnsafeMutableRawPointer?,
        CFMutableDictionary,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
        UInt64,
        CFTypeRef?
    ) -> UnsafeMutableRawPointer?

    private typealias CreateSamplesFn = @convention(c) (
        UnsafeMutableRawPointer,
        CFMutableDictionary,
        CFTypeRef?
    ) -> Unmanaged<CFDictionary>?

    private typealias CreateSamplesDeltaFn = @convention(c) (
        CFDictionary, CFDictionary, CFTypeRef?
    ) -> Unmanaged<CFDictionary>?

    private typealias GetChannelNameFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias GetGroupFn       = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias GetUnitLabelFn   = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias GetIntValueFn    = @convention(c) (CFDictionary, Int32) -> Int64

    // MARK: - Loaded symbols

    private let fnCopyChannelsInGroup: CopyChannelsInGroupFn
    private let fnCreateSubscription: CreateSubscriptionFn
    private let fnCreateSamples: CreateSamplesFn
    private let fnCreateSamplesDelta: CreateSamplesDeltaFn
    private let fnGetChannelName: GetChannelNameFn
    private let fnGetGroup: GetGroupFn
    private let fnGetUnitLabel: GetUnitLabelFn
    private let fnGetIntValue: GetIntValueFn

    // MARK: - Subscription state

    private var subscription: UnsafeMutableRawPointer?
    private var subscribedChannels: CFMutableDictionary?
    private var previousSample: CFDictionary?
    private var previousUptime: TimeInterval?
    private var previousWallClock: Date?

    /// One accepted delta: per-category energy in joules over `elapsed`.
    private struct EnergySample {
        var cpuJ = 0.0, gpuComputeJ = 0.0, gpuSramJ = 0.0, aneJ = 0.0, dramJ = 0.0
        var otherJ: [String: Double] = [:]
        var elapsed: TimeInterval = 0
        var maxChannelJ: Double = 0
    }

    /// Rolling window of accepted deltas. Rates are reported as
    /// (Σ energy / Σ elapsed) over up to `windowSeconds`. Needed because
    /// some OS/chip combinations publish the Energy Model counters in
    /// erratic batches (observed on macOS 27 beta / M4: most 1s deltas are
    /// zero, the energy arriving in lumps minutes apart) — instantaneous
    /// rates are then meaningless while windowed rates stay correct.
    private var window: [EnergySample] = []
    private static let windowSeconds: TimeInterval = 60
    /// A single delta implying more than this per channel is a counter
    /// anomaly (resets/jumps produce apparent kW..MW); the delta is
    /// dropped. No Mac component draws 500 W.
    private static let maxChannelWatts = 500.0

    /// Whether IOReport was successfully loaded and subscribed
    var isAvailable: Bool { subscription != nil }

    // MARK: - Init

    private init?() {
        guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else {
            print("IOReportReader: failed to load libIOReport.dylib")
            return nil
        }

        func sym<T>(_ name: String) -> T? {
            guard let ptr = dlsym(lib, name) else { return nil }
            return unsafeBitCast(ptr, to: T.self)
        }

        guard let f1: CopyChannelsInGroupFn = sym("IOReportCopyChannelsInGroup"),
              let f3: CreateSubscriptionFn   = sym("IOReportCreateSubscription"),
              let f4: CreateSamplesFn        = sym("IOReportCreateSamples"),
              let f5: CreateSamplesDeltaFn   = sym("IOReportCreateSamplesDelta"),
              let f6: GetChannelNameFn       = sym("IOReportChannelGetChannelName"),
              let f7: GetGroupFn             = sym("IOReportChannelGetGroup"),
              let f8: GetUnitLabelFn         = sym("IOReportChannelGetUnitLabel"),
              let f9: GetIntValueFn          = sym("IOReportSimpleGetIntegerValue")
        else {
            print("IOReportReader: failed to resolve IOReport symbols")
            return nil
        }

        self.fnCopyChannelsInGroup = f1
        self.fnCreateSubscription  = f3
        self.fnCreateSamples       = f4
        self.fnCreateSamplesDelta  = f5
        self.fnGetChannelName      = f6
        self.fnGetGroup            = f7
        self.fnGetUnitLabel        = f8
        self.fnGetIntValue         = f9

        setupSubscription()

        if subscription == nil {
            print("IOReportReader: failed to create subscription")
            return nil
        }
    }

    // MARK: - Setup

    private func setupSubscription() {
        guard let channelsRef = fnCopyChannelsInGroup(
            "Energy Model" as CFString, nil, 0, 0, 0
        ) else { return }

        let channels = channelsRef.takeRetainedValue()

        guard let mutable = CFDictionaryCreateMutableCopy(
            kCFAllocatorDefault, 0, channels
        ) else { return }

        var subbedRef: Unmanaged<CFMutableDictionary>?
        let sub = fnCreateSubscription(nil, mutable, &subbedRef, 0, nil)

        self.subscription = sub
        self.subscribedChannels = subbedRef?.takeRetainedValue()
    }

    // MARK: - Sampling

    /// Take a power sample. Returns nil on the first call (needs a baseline).
    /// Call periodically (e.g. every 0.5-2 seconds) for smooth readings.
    /// Thread-safe: call from any thread, but not concurrently.
    func sample() -> IOReportPowerBreakdown? {
        guard let sub = subscription,
              let channels = subscribedChannels else { return nil }

        guard let sampleRef = fnCreateSamples(sub, channels, nil) else { return nil }
        let currentSample = sampleRef.takeRetainedValue()
        // Awake-time is the correct denominator for energy/time: the energy
        // counters only accumulate while the SoC is awake, and unlike
        // Date() a monotonic clock can't jump with NTP/clock adjustments.
        let nowUptime = ProcessInfo.processInfo.systemUptime
        let nowWall = Date()

        defer {
            previousSample = currentSample
            previousUptime = nowUptime
            previousWallClock = nowWall
        }

        guard let prev = previousSample,
              let prevUptime = previousUptime,
              let prevWall = previousWallClock else {
            return nil // First call — establishing baseline
        }

        let elapsed = nowUptime - prevUptime
        guard elapsed > 0.01 else { return nil } // Too short for meaningful delta
        // Across a sleep the counters may reset, and dark-wake energy piles
        // into a small awake window — drop the sample and re-baseline
        // (the defer above already advanced the baseline).
        guard nowWall.timeIntervalSince(prevWall) < 30 else { return nil }

        guard let deltaRef = fnCreateSamplesDelta(prev, currentSample, nil) else {
            return nil
        }
        let delta = deltaRef.takeRetainedValue()

        let deltaSample = parseEnergySample(delta, elapsed: elapsed)

        // Counter anomaly (reset/jump): a single delta implying an
        // impossible rate would poison the whole window — drop it.
        if deltaSample.maxChannelJ / elapsed > Self.maxChannelWatts {
            return windowedBreakdown()
        }

        window.append(deltaSample)
        var total = window.reduce(0.0) { $0 + $1.elapsed }
        while window.count > 1, total - window[0].elapsed >= Self.windowSeconds {
            total -= window.removeFirst().elapsed
        }
        return windowedBreakdown()
    }

    /// Rates over the current window: Σ energy / Σ elapsed per category.
    private func windowedBreakdown() -> IOReportPowerBreakdown? {
        let elapsed = window.reduce(0.0) { $0 + $1.elapsed }
        guard elapsed > 0.5 else { return nil }
        var cpuJ = 0.0, gpuJ = 0.0, sramJ = 0.0, aneJ = 0.0, dramJ = 0.0
        var otherJ: [String: Double] = [:]
        for s in window {
            cpuJ += s.cpuJ
            gpuJ += s.gpuComputeJ
            sramJ += s.gpuSramJ
            aneJ += s.aneJ
            dramJ += s.dramJ
            for (label, joules) in s.otherJ {
                otherJ[label, default: 0] += joules
            }
        }
        var result = IOReportPowerBreakdown()
        result.cpuWatts = cpuJ / elapsed
        result.gpuComputeWatts = gpuJ / elapsed
        result.gpuSRAMWatts = sramJ / elapsed
        result.aneWatts = aneJ / elapsed
        result.dramWatts = dramJ / elapsed
        result.otherComponents = otherJ
            .filter { $0.value / elapsed > 0.001 }
            .map { (label: $0.key, watts: $0.value / elapsed) }
            .sorted { $0.label < $1.label }
        return result
    }

    // MARK: - Parsing

    private func parseEnergySample(_ delta: CFDictionary, elapsed: TimeInterval) -> EnergySample {
        var sample = EnergySample()
        sample.elapsed = elapsed

        guard let dict = delta as? [String: Any],
              let items = dict["IOReportChannels"] as? [Any] else {
            return sample
        }

        for case let item as NSDictionary in items {
            let cfItem = item as CFDictionary

            guard let groupStr = fnGetGroup(cfItem)?.takeUnretainedValue() as String?,
                  groupStr == "Energy Model",
                  let name = fnGetChannelName(cfItem)?.takeUnretainedValue() as String?
            else { continue }

            let unitStr = (fnGetUnitLabel(cfItem)?.takeUnretainedValue() as String?)?
                .trimmingCharacters(in: .whitespaces) ?? "nJ"

            let rawValue = fnGetIntValue(cfItem, 0)
            // Counters can reset (e.g. across sleep/wake) producing a
            // negative delta — never accumulate negative energy.
            let joules = max(0, energyToJoules(rawValue, unit: unitStr))
            sample.maxChannelJ = max(sample.maxChannelJ, joules)

            // Robust matching handles all chip variants:
            //   Base: ECPU, PCPU, GPU0, GPU SRAM0, ANE0, DRAM0
            //   Pro/Max: EACC_CPU, PACC0_CPU, GPU0, GPU SRAM0, ANE0, DRAM0
            //   Ultra: DIE_0_EACC_CPU, DIE_0_PACC0_CPU, GPU0_0, ANE0_0, DRAM0_0
            categorize(name: name, joules: joules, into: &sample)
        }

        return sample
    }

    private func categorize(name: String, joules: Double, into sample: inout EnergySample) {
        let n = name.uppercased()

        // CPU: ECPU, PCPU, *_CPU, *CPU Energy, EACC*, PACC*, *CPUDTL*
        if n.hasPrefix("ECPU") || n.hasPrefix("PCPU")
            || n.hasPrefix("EACC") || n.hasPrefix("PACC")
            || n.hasSuffix("_CPU") || n.hasSuffix("CPU ENERGY")
            || n.contains("CPUDTL") {
            sample.cpuJ += joules
        }
        // GPU SRAM (must check before GPU to avoid false match)
        else if n.hasPrefix("GPU SRAM") || n.hasPrefix("GPU_SRAM") {
            sample.gpuSramJ += joules
        }
        // GPU compute: GPU0, GPU Energy, GPU0_0
        else if n == "GPU ENERGY" || n.hasPrefix("GPU0") || n == "GPU" {
            sample.gpuComputeJ += joules
        }
        // ANE
        else if n.hasPrefix("ANE") {
            sample.aneJ += joules
        }
        // DRAM
        else if n.hasPrefix("DRAM") {
            sample.dramJ += joules
        }
        // Everything else — merge by human label (e.g. multiple DCS channels)
        else if joules > 0 {
            sample.otherJ[humanLabel(for: name), default: 0] += joules
        }
    }

    /// Convert raw IOReport channel names to human-readable labels.
    private func humanLabel(for channelName: String) -> String {
        // Strip die prefixes (Ultra chips): "DIE_0_" / "DIE_1_"
        var name = channelName
        if let range = name.range(of: #"^DIE_\d+_"#, options: .regularExpression) {
            name = String(name[range.upperBound...])
        }
        // Strip trailing digits: "DCS0" -> "DCS", "AMCC0" -> "AMCC"
        let stripped = name.replacingOccurrences(of: #"\d+$"#, with: "", options: .regularExpression)

        switch stripped {
        case "DCS", "AMCC":  return "Memory Ctrl"
        case "ISP":          return "ISP"
        case "AVE":          return "Video Enc"
        case "MSR":          return "Scaler"
        case "PCI":          return "PCI"
        default:             return stripped.isEmpty ? name : stripped
        }
    }

    /// Convert a raw energy delta to joules.
    private func energyToJoules(_ energy: Int64, unit: String) -> Double {
        switch unit {
        case "mJ": return Double(energy) / 1e3
        case "uJ": return Double(energy) / 1e6
        case "nJ": return Double(energy) / 1e9
        default:   return Double(energy) / 1e9 // Fallback: assume nJ (matches missing-label default)
        }
    }
}
