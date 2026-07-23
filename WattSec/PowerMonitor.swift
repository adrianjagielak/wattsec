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

    /// Smoothed system power consumption. Source: PowerTelemetryData
    /// SystemLoad when available (matches true battery drain to ~1% in
    /// logged data), falling back to SMC PSTR (which under-reads by ~5%
    /// on average on newer machines).
    @Published var wattage: Double = 0.0
    /// Smoothed DC input power — non-zero when charger connected.
    /// Source: telemetry SystemPowerIn when fresh (same snapshot as the
    /// system/battery values, so the rows add up), SMC PDTR fallback.
    @Published var dcInWattage: Double = 0.0
    /// Smoothed battery charge(+)/discharge(−) power. Same telemetry
    /// snapshot as wattage/dcInWattage when available, gauge V×A fallback.
    @Published var batteryFlowWattage: Double = 0.0
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
    /// Gauge coulomb counter (mAh) at the last interpolation step
    private var lastRemainingMAh: Int?

    /// Latest telemetry values (held between ~1s battery reads; ignored
    /// when stale). SystemPowerIn = SystemLoad + BatteryPower is an exact
    /// identity in this telemetry, so sourcing System / DC In / To Battery
    /// from the same snapshot makes the displayed rows add up exactly —
    /// mixing time bases (fast SMC vs windowed telemetry) does not.
    private var lastSystemLoadW: Double?
    private var lastDcInW: Double?
    private var lastBatteryFlowW: Double?
    private var lastTelemetryAt: Date?

    /// IOReport reliability watchdog. On some machines (observed on
    /// Mac16,6 / macOS 27) the Energy Model counters update erratically —
    /// minutes apart, with bogus multi-kW spikes — and cover only ~14% of
    /// SoC power even when windowed. Coverage vs (system − screen) decides
    /// a verdict that is persisted, so the breakdown is right from the
    /// first frame on later launches.
    private var ioCoverageIoSum: Double = 0
    private var ioCoverageTargetSum: Double = 0
    private var ioCoverageSamples: Int = 0
    /// nil = undetermined (warm-up: rows hidden, residual = whole SoC)
    private var ioVerdictUnreliable: Bool?
    /// Per-component IOReport rows are shown only once proven reliable
    var ioReportTrusted: Bool { ioVerdictUnreliable == false }
    /// Machine has ever exposed per-port PowerOutDetails (persisted) —
    /// USB power is measured there, so the gap must never be labeled USB.
    private var hasSeenPortPower = false

    private static let ioVerdictDefaultsKey = "ioEnergyModelUnreliable"
    private static let portPowerDefaultsKey = "hasSeenPowerOutDetails"

    /// Fallback nominal pack voltage for mAh→Wh conversion when the cell
    /// configuration can't be read from the registry. Apple Silicon
    /// MacBooks use 3-cell LiPo (3 × 3.85V = 11.55V nominal), matching
    /// Apple's published Wh specs. The preferred source is the snapshot's
    /// nominalPackVoltageMV, derived from the physical CellVoltage count.
    private static let fallbackNominalVoltageMV: Double = 11_550.0

    // Constants fitted from ~66h of logged telemetry (docs/CALIBRATION.md):

    /// displayed% per raw% while discharging (soc ≈ 1.062·raw% − 1.05)
    private static let socSlopeDischarge = 1.062
    /// displayed% per raw% while charging (soc ≈ raw% + 1.07)
    private static let socSlopeCharge = 1.0
    /// Current-weighted mean discharge voltage was 11.38V vs the 11.55V
    /// nominal display scale — energy actually deliverable is ~1.5% less
    /// than the nominal-scale Wh suggests. Applied to time estimates only.
    static let dischargeEnergyFactor = 0.985
    /// Telemetry values older than this fall back to SMC/gauge sources
    private static let systemLoadMaxAge: TimeInterval = 5.0
    /// Coverage watchdog: decide after ~1 minute of loaded samples;
    /// hysteresis so the verdict can flip only on clear evidence
    private static let ioCoverageMinSamples = 60
    private static let ioUnreliableBelow = 0.25
    private static let ioReliableAbove = 0.5

    // MARK: - Init

    private init() {
        if ioReportReader != nil {
            print("PowerMonitor: IOReport available — using per-component energy counters")
        } else {
            print("PowerMonitor: IOReport unavailable — using SMC-only breakdown")
        }
        // Restore per-machine verdicts so the first frame is already right
        ioVerdictUnreliable = UserDefaults.standard.object(forKey: Self.ioVerdictDefaultsKey) as? Bool
        hasSeenPortPower = UserDefaults.standard.bool(forKey: Self.portPowerDefaultsKey)
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
        // Hold the latest telemetry (SystemPowerIn = SystemLoad +
        // BatteryPower is exact within one snapshot — sourcing all three
        // displayed values from it makes the menu add up; SMC PDTR reacts
        // ~15s faster than the windowed telemetry during load swings,
        // which is exactly why mixing the two never balanced).
        if let snap = batterySnap, snap.telemetrySystemLoadW != nil {
            lastSystemLoadW = snap.telemetrySystemLoadW
            lastDcInW = snap.telemetrySystemPowerInW
            lastBatteryFlowW = snap.telemetryBatteryPowerW
            lastTelemetryAt = Date()
        }
        let telemetryFresh = lastTelemetryAt.map {
            Date().timeIntervalSince($0) < Self.systemLoadMaxAge
        } == true
        let rawSystemEff = (telemetryFresh ? lastSystemLoadW : nil) ?? rawSystem
        let rawDcInEff = (telemetryFresh ? lastDcInW : nil) ?? rawDcIn
        let rawFlowEff = (telemetryFresh ? lastBatteryFlowW : nil)
            ?? battery?.instantBatteryPowerW
            ?? battery?.batteryPowerW
            ?? 0

        let nowCharging = rawDcInEff > Self.chargingThreshold

        // Reset smoothing on charger connect/disconnect
        if isFirstReading || nowCharging != wasCharging {
            wattage = rawSystemEff
            dcInWattage = rawDcInEff
            batteryFlowWattage = rawFlowEff
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
            wattage += smoothingAlpha * (rawSystemEff - wattage)
            dcInWattage += smoothingAlpha * (rawDcInEff - dcInWattage)
            batteryFlowWattage += smoothingAlpha * (rawFlowEff - batteryFlowWattage)
        }

        // Track rolling 5-minute history for time estimates
        wattageHistory.append(rawSystemEff)
        if wattageHistory.count > Self.historySize {
            wattageHistory.removeFirst()
        }

        // Accumulate raw system/screen between IOReport samples for the
        // time-aligned gap computation below.
        if ioReportReader != nil {
            windowSystemSum += rawSystemEff
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
                // The Energy Model total is only subtracted once proven
                // reliable — otherwise the gap is the whole SoC.
                let metered = ioReportTrusted ? io.totalMeteredWatts : 0
                let gap = avgSystem - avgScreen - metered
                let prev = smoothedGapW ?? gap
                smoothedGapW = prev + Self.gapSmoothingAlpha * (gap - prev)

                // Reliability watchdog: cumulative energy coverage of the
                // Energy Model vs (system − screen). Broken counters
                // (macOS 27 beta / M4: erratic updates, ~14% coverage)
                // must never render as "CPU 0.0W" + a huge residual. The
                // verdict persists across launches and can flip back if a
                // later OS fixes the counters.
                if avgSystem - avgScreen > 3 {
                    ioCoverageIoSum += io.totalMeteredWatts
                    ioCoverageTargetSum += avgSystem - avgScreen
                    ioCoverageSamples += 1
                    if ioCoverageSamples >= Self.ioCoverageMinSamples, ioCoverageTargetSum > 0 {
                        let ratio = ioCoverageIoSum / ioCoverageTargetSum
                        var verdict = ioVerdictUnreliable
                        if ratio < Self.ioUnreliableBelow {
                            verdict = true
                        } else if ratio > Self.ioReliableAbove {
                            verdict = false
                        } else if verdict == nil {
                            // Mid-band with no prior verdict: decide at the
                            // midpoint rather than staying in limbo forever
                            verdict = ratio < (Self.ioUnreliableBelow + Self.ioReliableAbove) / 2
                        }
                        if verdict != ioVerdictUnreliable {
                            ioVerdictUnreliable = verdict
                            UserDefaults.standard.set(verdict, forKey: Self.ioVerdictDefaultsKey)
                            print("PowerMonitor: Energy Model coverage "
                                  + String(format: "%.0f%%", 100 * ratio)
                                  + " — breakdown \(verdict == true ? "degraded" : "enabled")")
                        }
                    }
                }
            }
            windowSystemSum = 0
            windowScreenSum = 0
            windowSampleCount = 0
            lastIOReportBreakdown = io
        } else if lastIOReportBreakdown == nil {
            // No SoC metering at all: the unmetered remainder is simply
            // system minus screen — trivially aligned, same tick.
            let gap = rawSystemEff - rawScreen
            let prev = smoothedGapW ?? gap
            smoothedGapW = prev + 0.05 * (gap - prev)
        }

        // Update battery snapshot and per-port USB power before building
        // the breakdown so it uses this tick's port data.
        if let snap = batterySnap {
            battery = snap
            usbPortPower = snap.usbPortPower
            if !snap.usbPortPower.isEmpty, !hasSeenPortPower {
                // This machine measures USB power per port — remember, so
                // the residual is never labeled "USB/Ext" here again.
                hasSeenPortPower = true
                UserDefaults.standard.set(true, forKey: Self.portPowerDefaultsKey)
            }
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
            "hlTelemetry": lastSystemLoadW != nil ? 1 : 0,
            "batteryFlowEMA": batteryFlowWattage,
            "ioVerdict": ioVerdictUnreliable.map { $0 ? 1 : 0 } ?? -1,
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

        if let io = lastIOReportBreakdown, ioReportTrusted {
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
                components.append(PowerComponent(
                    label: ioReportTrusted ? "Other" : "SoC/Other", watts: residual))
            }
        } else {
            // Label the gap by what it actually contains: with a trusted
            // Energy Model and no per-port USB measurement it's external
            // power ("USB/Ext"); with per-port measurement present on this
            // machine USB is accounted elsewhere ("Other"); without a
            // trusted Energy Model it's mostly the SoC itself.
            let residualLabel: String
            if ioReportTrusted {
                residualLabel = hasSeenPortPower ? "Other" : "USB/Ext"
            } else {
                residualLabel = "SoC/Other"
            }
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
            lastRemainingMAh = bat.currentCapacityMAh > 0 ? bat.currentCapacityMAh : nil
            return (socCurrentWh, maxWh)
        }

        // Between % changes: step interpolation forward
        guard let prevTime = lastInterpolationTime else {
            lastInterpolationTime = now
            return (socCurrentWh, maxWh)
        }

        let dt = now.timeIntervalSince(prevTime)
        lastInterpolationTime = now

        if bat.currentCapacityMAh > 0, let lastRem = lastRemainingMAh {
            // Coulomb-counter interpolation (preferred): move the
            // displayed-consistent Wh by the gauge's own mAh delta, scaled
            // by the fitted displayed%-per-raw% slope for the direction of
            // flow. No clock integration → immune to sleep gaps and rate
            // drift; the gauge already integrated the current for us.
            let deltaMAh = Double(bat.currentCapacityMAh - lastRem)
            if deltaMAh != 0 {
                let slope = deltaMAh >= 0 ? Self.socSlopeCharge : Self.socSlopeDischarge
                interpolatedWh += maxWh * slope * deltaMAh / Double(bat.maxCapacityMAh)
                lastRemainingMAh = bat.currentCapacityMAh
            }
        } else if bat.currentCapacityMAh > 0 {
            // Start coulomb tracking on the next call
            lastRemainingMAh = bat.currentCapacityMAh
        } else {
            // Power-integration fallback (no mAh from the gauge).
            // A long gap (sleep) means the last power reading is stale —
            // integrating it across the gap would be wrong. Re-anchor.
            guard dt < 60 else {
                interpolatedWh = socCurrentWh
                return (socCurrentWh, maxWh)
            }
            let dtHours = dt / 3600.0

            if let batteryW = bat.instantBatteryPowerW ?? bat.batteryPowerW {
                // Gas gauge power (signed): stays flat when the charger
                // holds the battery, follows real drain when the system
                // outdraws the charger.
                interpolatedWh += batteryW * dtHours
            } else if isCharging {
                interpolatedWh += max(0, dcInWattage - wattage) * dtHours
            } else {
                interpolatedWh -= wattage * dtHours
            }
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
