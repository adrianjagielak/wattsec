//
//  PowerMonitor.swift
//  WattSec
//
//  Centralized power monitoring: reads SMC sensors and IOReport energy
//  counters, tracks battery state, maintains smoothed values and rolling
//  averages for display.
//
//  Uses IOReport for per-component breakdown (CPU, GPU, ANE, DRAM) with
//  accurate GPU power that includes SRAM (the commonly missed piece).
//  Without IOReport only the system total and screen are measurable; the
//  remainder is shown as a single "Other" row (no per-component fallback
//  exists via SMC on Apple Silicon).
//  Screen power always comes from SMC (PDBR) since IOReport doesn't track it.
//
//  USB power measurement strategy (exhaustively researched, April 2026):
//
//  1. PRIMARY: PowerOutDetails from AppleSmartBattery IORegistry
//     - Provides actual measured milliwatts per USB-C port (PDPowermW / Watts)
//     - Hardware-level measurement from the USB-C PD controller
//     - NOT available on all Apple Silicon MacBook Pro models/macOS versions
//     - When missing, macpow (k06a) and other tools silently return empty data
//     - No known workaround to force its presence; it appears firmware-dependent
//
//  2. FALLBACK: PSTR gap method (always available on Apple Silicon)
//     - PSTR (SMC) = total system power at the main power rail (hardware sensor)
//     - Subtract: IOReport Energy Model (CPU+GPU+ANE+DRAM+PCI+...) + PDBR (screen)
//     - Residual ≈ USB/Thunderbolt power delivery + ~3-5% VRM losses
//     - This IS a hardware measurement (difference of two hardware measurements)
//     - Shows ~0W idle, ~5W for a charging phone, ~11W for an iPad, etc.
//     - Limitation: total across all ports, not per-port
//
//  Ruled out (does not provide measured USB power delivery on Apple Silicon):
//  - SMC keys D0IR/D0VR: measure AC power IN (charger), not OUT to devices
//  - SMC key PUSB: intermittent/unreliable on many machines
//  - USB descriptor bMaxPower / UsbPowerSinkAllocation: max requested, not actual
//  - IOReport Energy Model "PCI" channel: controller's own power, not throughput
//  - powermetrics: no USB sampler exists
//  - IOPSCopyExternalPowerAdapterDetails: adapter info only (power IN)
//  - system_profiler SPUSBDataType: descriptor max values, not measured
//  - PowerTelemetryData, PowerLog DB: no per-port USB power data
//
//  This class is UI-independent and can be reused in any macOS app.
//

import Combine
import Foundation
import IOKit

class PowerMonitor: ObservableObject {

    static let shared = PowerMonitor()

    // MARK: - Published State

    /// Smoothed system power consumption (PSTR)
    @Published var wattage: Double = 0.0
    /// Smoothed DC input power (PDTR) — non-zero when charger connected
    @Published var dcInWattage: Double = 0.0
    /// Latest battery snapshot (updated every ~1 second)
    @Published var battery: BatterySnapshot?
    /// Smoothed power breakdown by component
    @Published var powerBreakdown: [PowerComponent] = []
    /// Per-port USB-C power delivery (from PowerOutDetails when available)
    @Published var usbPortPower: [UsbPortPower] = []
    /// Whether per-port USB power data is available (vs PSTR-gap fallback)
    var hasPerPortUsbPower: Bool { !usbPortPower.isEmpty }

    // MARK: - Computed Properties

    var isCharging: Bool { dcInWattage > Self.chargingThreshold }

    /// 5-minute rolling average of system power (for time estimates)
    var averageWattage: Double {
        guard !wattageHistory.isEmpty else { return wattage }
        return wattageHistory.reduce(0, +) / Double(wattageHistory.count)
    }

    /// 5-minute rolling average of measured battery drain (gas gauge, W).
    /// This is the correct divisor for battery-time estimates: it includes
    /// the regulator/conversion losses between battery and system rail
    /// that PSTR doesn't see. Nil until at least one sample exists.
    var averageDischargeWatts: Double? {
        guard !dischargePowerHistory.isEmpty else { return nil }
        return dischargePowerHistory.reduce(0, +) / Double(dischargePowerHistory.count)
    }

    // MARK: - Configuration

    private var smoothingAlpha: Double = 0.2

    /// Fixed sample interval (200ms = 5 updates/sec)
    static let sampleInterval: TimeInterval = 0.2
    /// Threshold for detecting charger connected
    private static let chargingThreshold: Double = 1.0
    /// Read battery info every N samples (~1 second at 200ms).
    /// Voltage/Amperage are instantaneous values (unlike IOReport's
    /// accumulating counters), so a finer cadence genuinely adds data —
    /// both for display and for the diagnostics log.
    private static let batteryReadInterval = 5
    /// Read IOReport every N samples (~1 second at 200ms).
    /// The energy counters are integrals: sampling slower loses no energy,
    /// only attribution granularity, so 1s is effectively lossless.
    private static let ioReportReadInterval = 5
    /// 5 minutes of samples at 200ms = 1500 entries
    private static let historySize = 1500
    /// ~5 minutes of battery gauge reads at ~1s
    private static let dischargeHistorySize = 300
    /// EMA for the PSTR↔IOReport gap, applied once per IOReport interval
    /// (~1s): time constant ≈ 5s
    private static let gapSmoothingAlpha = 0.2

    // MARK: - Private State

    private var timer: AnyCancellable?
    private var isFirstReading = true
    private var wasCharging = false
    private var batteryReadCounter = 0
    private var ioReportReadCounter = 0
    private var wattageHistory: [Double] = []
    /// Measured battery drain samples (gas gauge, positive W) — the true
    /// discharge rate including conversion losses that PSTR misses.
    private var dischargePowerHistory: [Double] = []

    /// Accumulators aligning raw PSTR/screen samples with the ~1s window
    /// each IOReport delta covers, so the unmetered gap compares averages
    /// over the SAME time span instead of an instantaneous PSTR reading
    /// against a 1-second energy average.
    private var windowSystemSum: Double = 0
    private var windowScreenSum: Double = 0
    private var windowSampleCount: Int = 0
    /// Smoothed, time-aligned unmetered gap (signed — negatives are kept
    /// so noise isn't rectified into an upward bias; clamped only at
    /// display time).
    private var smoothedGapW: Double?

    /// Serial queue for sensor reads. SMC and IOReport must not be called
    /// concurrently, but the timer can fire again while a slow read is
    /// still in flight — a concurrent global queue would overlap them.
    private let sampleQueue = DispatchQueue(label: "WattSec.PowerMonitor.sample", qos: .utility)
    /// Coalesce timer ticks while a sample is still being read.
    private var sampleInFlight = false

    /// IOReport reader (nil if unavailable on this system)
    private let ioReportReader = IOReportReader.shared

    /// Smoothed values for each component (keyed by label)
    private var componentSmoothed: [String: Double] = [:]

    /// IOReport "other" channel labels seen so far, in first-seen order.
    /// Kept so idle components (media engines etc.) decay to zero instead
    /// of vanishing from the menu the moment a sample omits them.
    private var knownOtherLabels: [String] = []

    /// Last IOReport breakdown (updated every ~1s, displayed every 200ms)
    private var lastIOReportBreakdown: IOReportPowerBreakdown?

    /// USB device notification port and iterators
    private var usbNotifyPort: IONotificationPortRef?
    private var usbAddedIterator: io_iterator_t = 0
    private var usbRemovedIterator: io_iterator_t = 0

    /// Interpolated battery capacity
    private var lastSnapSocPercent: Int = -1
    private var interpolatedWh: Double = 0
    private var lastInterpolationTime: Date?

    /// Fallback nominal pack voltage for mAh→Wh conversion when the cell
    /// configuration can't be read from the registry. Apple Silicon
    /// MacBooks use 3-cell LiPo (3 × 3.85V = 11.55V nominal), matching
    /// Apple's published Wh specs. The preferred source is the snapshot's
    /// nominalPackVoltageMV, derived from the physical CellVoltage count.
    private static let fallbackNominalVoltageMV: Double = 11_550.0

    // MARK: - Init

    private init() {
        if ioReportReader != nil {
            print("PowerMonitor: IOReport available — using per-component energy counters")
        } else {
            print("PowerMonitor: IOReport unavailable — using SMC-only breakdown")
        }
        setupTimer()
        setupUsbNotifications()
    }

    // MARK: - Public API

    func updatePace(_ smoothingAlpha: Double) {
        self.smoothingAlpha = smoothingAlpha
    }

    /// Take one sample. Must be called on the main thread (the timer does).
    func fetchWattage() {
        // Skip this tick if the previous sample is still being read —
        // queueing more work behind a stalled read only builds a backlog.
        guard !sampleInFlight else { return }
        sampleInFlight = true

        // Decide on the main thread which slow sources to read this tick;
        // the counters are main-thread state and must not be read off-main.
        let readBattery = batteryReadCounter == 0
        let readIOReport = ioReportReadCounter == 0
        batteryReadCounter = (batteryReadCounter + 1) % Self.batteryReadInterval
        ioReportReadCounter = (ioReportReadCounter + 1) % Self.ioReportReadInterval

        sampleQueue.async { [weak self] in
            guard let self = self else { return }

            // Read primary power values from SMC
            // PSTR = total system power (includes SoC + screen + everything)
            let rawSystem = max(0.0, SMC.shared.getValue("PSTR") ?? 0.0)
            let rawDcIn = max(0.0, SMC.shared.getValue("PDTR") ?? 0.0)

            // Screen power from SMC (included in PSTR, but useful for breakdown)
            let rawScreen = max(0.0, SMC.shared.getValue("PDBR") ?? 0.0)

            // Read battery less frequently (it changes slowly)
            let snap: BatterySnapshot? = readBattery ? BatteryInfo.shared.snapshot() : nil

            // Read IOReport less frequently (~1s intervals for meaningful deltas)
            var ioBreakdown: IOReportPowerBreakdown? = nil
            if readIOReport, let reader = self.ioReportReader {
                ioBreakdown = reader.sample()
            }

            DispatchQueue.main.async {
                self.sampleInFlight = false
                self.applyReadings(
                    rawSystem: rawSystem,
                    rawDcIn: rawDcIn,
                    rawScreen: rawScreen,
                    batterySnap: snap,
                    ioBreakdown: ioBreakdown
                )
            }
        }
    }

    // MARK: - Private: Processing

    private func applyReadings(
        rawSystem: Double,
        rawDcIn: Double,
        rawScreen: Double,
        batterySnap: BatterySnapshot?,
        ioBreakdown: IOReportPowerBreakdown?
    ) {
        let nowCharging = rawDcIn > Self.chargingThreshold

        // Reset smoothing on charger connect/disconnect
        if isFirstReading || nowCharging != wasCharging {
            wattage = rawSystem
            dcInWattage = rawDcIn
            isFirstReading = false
            wasCharging = nowCharging
            wattageHistory.removeAll()
            dischargePowerHistory.removeAll()
            componentSmoothed.removeAll()
            lastIOReportBreakdown = nil
            smoothedGapW = nil
            windowSystemSum = 0
            windowScreenSum = 0
            windowSampleCount = 0
        } else {
            wattage += smoothingAlpha * (rawSystem - wattage)
            dcInWattage += smoothingAlpha * (rawDcIn - dcInWattage)
        }

        // Track rolling 5-minute history for time estimates
        wattageHistory.append(rawSystem)
        if wattageHistory.count > Self.historySize {
            wattageHistory.removeFirst()
        }

        // Accumulate raw PSTR/screen between IOReport samples for the
        // time-aligned gap computation below.
        if ioReportReader != nil {
            windowSystemSum += rawSystem
            windowScreenSum += rawScreen
            windowSampleCount += 1
            // If IOReport stops delivering, don't let a stale window grow
            if windowSampleCount > 100 {
                windowSystemSum = 0
                windowScreenSum = 0
                windowSampleCount = 0
            }
        }

        if let io = ioBreakdown {
            if lastIOReportBreakdown == nil {
                // The gap was tracking (system − screen) with no SoC
                // metering; restart it now that IOReport data exists.
                smoothedGapW = nil
            }
            if windowSampleCount > 0 {
                let avgSystem = windowSystemSum / Double(windowSampleCount)
                let avgScreen = windowScreenSum / Double(windowSampleCount)
                // Signed gap over the same window the IOReport delta covers.
                let gap = avgSystem - avgScreen - io.totalMeteredWatts
                let prev = smoothedGapW ?? gap
                smoothedGapW = prev + Self.gapSmoothingAlpha * (gap - prev)
            }
            windowSystemSum = 0
            windowScreenSum = 0
            windowSampleCount = 0
            lastIOReportBreakdown = io
        } else if lastIOReportBreakdown == nil {
            // No SoC metering at all: the unmetered remainder is simply
            // system minus screen — trivially aligned, same tick.
            let gap = rawSystem - rawScreen
            let prev = smoothedGapW ?? gap
            smoothedGapW = prev + 0.05 * (gap - prev)
        }

        // Update battery snapshot and per-port USB power before building
        // the breakdown so it uses this tick's port data.
        if let snap = batterySnap {
            battery = snap
            usbPortPower = snap.usbPortPower
            if let batteryW = snap.batteryPowerW, batteryW < -0.05 {
                dischargePowerHistory.append(-batteryW)
                if dischargePowerHistory.count > Self.dischargeHistorySize {
                    dischargePowerHistory.removeFirst()
                }
            }
        }

        // Build component breakdown
        powerBreakdown = buildBreakdown(rawScreen: rawScreen)

        // Diagnostics: one record per tick (200ms). IOReport/battery
        // sub-objects are attached only on the tick where that source
        // produced fresh data — logging a source faster than it updates
        // adds bytes, not information.
        logDiagnostics(
            rawSystem: rawSystem,
            rawDcIn: rawDcIn,
            rawScreen: rawScreen,
            ioBreakdown: ioBreakdown,
            batterySnap: batterySnap
        )
    }

    /// Write one diagnostics record: raw SMC values every tick, fresh
    /// IOReport per-channel watts (~1s), the fresh full battery property
    /// table (~1s), and the app's derived values — everything needed to
    /// fit calibration offline.
    private func logDiagnostics(
        rawSystem: Double,
        rawDcIn: Double,
        rawScreen: Double,
        ioBreakdown: IOReportPowerBreakdown?,
        batterySnap: BatterySnapshot?
    ) {
        guard DiagnosticsLogger.shared.isEnabled else { return }

        var record: [String: Any] = [
            "uptime": ProcessInfo.processInfo.systemUptime,
            "smc": ["PSTR": rawSystem, "PDTR": rawDcIn, "PDBR": rawScreen],
        ]

        var derived: [String: Any] = [
            "wattageEMA": wattage,
            "dcInEMA": dcInWattage,
            "gapW": smoothedGapW ?? 0,
            "avgW5m": averageWattage,
        ]
        if let avgDischarge = averageDischargeWatts {
            derived["avgDischargeW5m"] = avgDischarge
        }
        if let cap = interpolatedCapacity() {
            derived["interpWh"] = cap.currentWh
            derived["interpMaxWh"] = cap.maxWh
        }
        record["derived"] = derived

        // Fresh IOReport delta this tick (already a ~1s average by nature)
        if let io = ioBreakdown {
            var ioDict: [String: Any] = [
                "cpu": io.cpuWatts,
                "gpu": io.gpuComputeWatts,
                "gpuSram": io.gpuSRAMWatts,
                "ane": io.aneWatts,
                "dram": io.dramWatts,
                "total": io.totalMeteredWatts,
            ]
            for comp in io.otherComponents {
                ioDict["o_" + comp.label] = comp.watts
            }
            record["ioreport"] = ioDict
        }

        // Fresh battery dump this tick: the complete AppleSmartBattery
        // property table — raw + user-facing capacities, PowerTelemetryData,
        // BatteryData, ChargerData, AdapterDetails, CellVoltage,
        // PowerOutDetails, ...
        if let snap = batterySnap {
            record["battery"] = snap.rawProperties
        }

        DiagnosticsLogger.shared.log(record)
    }

    private func buildBreakdown(rawScreen: Double) -> [PowerComponent] {
        var components: [PowerComponent] = []

        if let io = lastIOReportBreakdown {
            // IOReport values shown as-is (no scaling).
            // These are actual energy counter measurements from the SoC.
            components.append(smoothedComponent("CPU", raw: io.cpuWatts))
            components.append(smoothedComponent("GPU", raw: io.gpuTotalWatts))
            components.append(smoothedComponent("ANE", raw: io.aneWatts))
            components.append(smoothedComponent("DRAM", raw: io.dramWatts))

            // Additional IOReport components (media engines, PCI, etc.).
            // A channel that goes idle disappears from the sample; feed 0
            // into its EMA so the row decays smoothly and only hide it
            // once it's genuinely near zero — no flickering rows.
            var currentOther: [String: Double] = [:]
            for comp in io.otherComponents {
                currentOther[comp.label, default: 0] += comp.watts
            }
            for label in currentOther.keys.sorted() where !knownOtherLabels.contains(label) {
                knownOtherLabels.append(label)
            }
            for label in knownOtherLabels {
                let comp = smoothedComponent(label, raw: currentOther[label] ?? 0)
                if comp.watts >= 0.05 {
                    components.append(comp)
                }
            }
        }

        // Screen power from PDBR (included in PSTR)
        components.append(smoothedComponent("Screen", raw: rawScreen))

        // USB/External power: prefer per-port hardware measurement,
        // fall back to the time-aligned PSTR gap (maintained in
        // applyReadings — raw PSTR/screen averaged over the exact window
        // each IOReport delta covers, then EMA'd, sign preserved).
        //
        // PowerOutDetails (when available) gives actual measured milliwatts
        // per USB-C port from the PD controller hardware. When unavailable,
        // the gap (total system minus metered SoC minus screen) captures
        // the same power — it's a hardware measurement too, just aggregated.
        if !usbPortPower.isEmpty {
            // Per-port data available from PowerOutDetails
            for port in usbPortPower {
                components.append(smoothedComponent("USB Port \(port.portIndex)", raw: port.watts))
            }
            // Still show residual for anything not captured by PD (e.g. VRM losses)
            let pdTotal = usbPortPower.reduce(0.0) { $0 + $1.watts }
            let residual = (smoothedGapW ?? 0) - pdTotal
            if residual > 0.1 {
                components.append(PowerComponent(label: "Other", watts: residual))
            }
        } else {
            // Only call the gap "USB/Ext" when IOReport is metering the SoC;
            // without IOReport the gap is mostly the SoC itself, so labeling
            // it USB would be misleading — call it "Other".
            let residualLabel = lastIOReportBreakdown != nil ? "USB/Ext" : "Other"
            let gap = smoothedGapW ?? 0
            // Floor small values to zero to avoid jitter around 0
            components.append(PowerComponent(label: residualLabel, watts: gap < 0.5 ? 0.0 : gap))
        }

        return components
    }

    private func smoothedComponent(_ label: String, raw: Double) -> PowerComponent {
        let prev = componentSmoothed[label] ?? raw
        let smoothed = prev + smoothingAlpha * (raw - prev)
        componentSmoothed[label] = smoothed
        return PowerComponent(label: label, watts: smoothed)
    }

    // MARK: - Private: Timer

    private func setupTimer() {
        timer?.cancel()
        timer = Timer.publish(every: Self.sampleInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.fetchWattage()
            }
    }

    // MARK: - Private: USB Device Notifications

    private func setupUsbNotifications() {
        usbNotifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notifyPort = usbNotifyPort else { return }

        let runLoopSource = IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Device added
        if let matching = IOServiceMatching("IOUSBHostDevice") {
            IOServiceAddMatchingNotification(
                notifyPort,
                kIOFirstMatchNotification,
                matching,
                { refcon, iterator in
                    while IOIteratorNext(iterator) != 0 {}
                    guard let refcon = refcon else { return }
                    let monitor = Unmanaged<PowerMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    DispatchQueue.main.async { monitor.onUsbDeviceChanged() }
                },
                selfPtr,
                &usbAddedIterator
            )
            while IOIteratorNext(usbAddedIterator) != 0 {}
        }

        // Device removed (needs its own matching dict — IOKit consumes one per call)
        if let matching = IOServiceMatching("IOUSBHostDevice") {
            IOServiceAddMatchingNotification(
                notifyPort,
                kIOTerminatedNotification,
                matching,
                { refcon, iterator in
                    while IOIteratorNext(iterator) != 0 {}
                    guard let refcon = refcon else { return }
                    let monitor = Unmanaged<PowerMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    DispatchQueue.main.async { monitor.onUsbDeviceChanged() }
                },
                selfPtr,
                &usbRemovedIterator
            )
            while IOIteratorNext(usbRemovedIterator) != 0 {}
        }
    }

    private func onUsbDeviceChanged() {
        // Reset USB smoothing so it converges fast on the new value —
        // both the aggregate gap and any per-port rows.
        smoothedGapW = nil
        let portKeys = componentSmoothed.keys.filter { $0.hasPrefix("USB Port ") }
        for key in portKeys {
            componentSmoothed.removeValue(forKey: key)
        }
    }

    // MARK: - Private: Interpolated Battery

    /// Update interpolated battery Wh using measured battery power.
    /// Snaps to real IORegistry values when SoC% changes and interpolates
    /// between; never strays more than 1% (the SoC granularity) from the
    /// SoC-derived value, so rate errors can't accumulate into drift.
    func interpolatedCapacity() -> (currentWh: Double, maxWh: Double)? {
        guard let bat = battery, bat.maxCapacityMAh > 0 else { return nil }

        let nominalMV = bat.nominalPackVoltageMV ?? Self.fallbackNominalVoltageMV
        let maxWh = Double(bat.maxCapacityMAh) * nominalMV / 1_000_000.0
        // Derive currentWh from macOS SoC% so they're always consistent.
        // AppleRawCurrentCapacity/AppleRawMaxCapacity doesn't match CurrentCapacity%
        // because Apple uses non-linear curves, temp compensation, and calibration.
        let socCurrentWh = maxWh * Double(bat.socPercent) / 100.0
        let now = Date()

        // Snap when SoC% changes (new real data from IORegistry)
        if bat.socPercent != lastSnapSocPercent {
            lastSnapSocPercent = bat.socPercent
            interpolatedWh = socCurrentWh
            lastInterpolationTime = now
            return (socCurrentWh, maxWh)
        }

        // Between % changes: step interpolation forward
        guard let prevTime = lastInterpolationTime else {
            lastInterpolationTime = now
            return (socCurrentWh, maxWh)
        }

        let dt = now.timeIntervalSince(prevTime)
        lastInterpolationTime = now

        // A long gap (sleep) means the last power reading is stale —
        // integrating it across the gap would be wrong. Re-anchor.
        guard dt < 60 else {
            interpolatedWh = socCurrentWh
            return (socCurrentWh, maxWh)
        }
        let dtHours = dt / 3600.0

        if let batteryW = bat.instantBatteryPowerW ?? bat.batteryPowerW {
            // Gas gauge measurement (signed): the actual energy flow into
            // or out of the battery. Instantaneous amperage tracks rate
            // changes fastest; its noise integrates out and the SoC band
            // clamp below bounds any residual error. Correctly stays flat
            // when the charger holds the battery (full, or charge
            // limiting), and follows real drain when the system outdraws
            // the charger.
            interpolatedWh += batteryW * dtHours
        } else if isCharging {
            // Estimate fallback: net charge rate, only move up
            interpolatedWh += max(0, dcInWattage - wattage) * dtHours
        } else {
            // Estimate fallback: system drain, only move down
            interpolatedWh -= wattage * dtHours
        }

        // SoC% has 1% granularity, so the true charge can't be more than
        // one percent away from the SoC-derived value. Clamp to that band
        // so interpolation can't wander while the percentage holds still.
        let band = maxWh / 100.0
        interpolatedWh = min(max(interpolatedWh, socCurrentWh - band), socCurrentWh + band)
        interpolatedWh = min(max(interpolatedWh, 0), maxWh)

        return (interpolatedWh, maxWh)
    }
}

// MARK: - Supporting Types

struct PowerComponent {
    let label: String
    let watts: Double
}
