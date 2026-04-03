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
//  Falls back to SMC-only breakdown if IOReport is unavailable.
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

class PowerMonitor: ObservableObject {

    static let shared = PowerMonitor()

    // MARK: - Published State

    /// Smoothed system power consumption (PSTR)
    @Published var wattage: Double = 0.0
    /// Smoothed DC input power (PDTR) — non-zero when charger connected
    @Published var dcInWattage: Double = 0.0
    /// Latest battery snapshot (updated every ~2 seconds)
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

    // MARK: - Configuration

    private var smoothingAlpha: Double = 0.2

    /// Fixed sample interval (200ms = 5 updates/sec)
    static let sampleInterval: TimeInterval = 0.2
    /// Threshold for detecting charger connected
    private static let chargingThreshold: Double = 1.0
    /// Read battery info every N samples (~2 seconds at 200ms)
    private static let batteryReadInterval = 10
    /// Read IOReport every N samples (~1 second at 200ms)
    private static let ioReportReadInterval = 5
    /// 5 minutes of samples at 200ms = 1500 entries
    private static let historySize = 1500

    // MARK: - Private State

    private var timer: AnyCancellable?
    private var isFirstReading = true
    private var wasCharging = false
    private var batteryReadCounter = 0
    private var ioReportReadCounter = 0
    private var wattageHistory: [Double] = []

    /// IOReport reader (nil if unavailable on this system)
    private let ioReportReader = IOReportReader.shared

    /// Smoothed values for each component (keyed by label)
    private var componentSmoothed: [String: Double] = [:]

    /// Last IOReport breakdown (updated every ~1s, displayed every 200ms)
    private var lastIOReportBreakdown: IOReportPowerBreakdown?

    // MARK: - Init

    private init() {
        if ioReportReader != nil {
            print("PowerMonitor: IOReport available — using per-component energy counters")
        } else {
            print("PowerMonitor: IOReport unavailable — using SMC-only breakdown")
        }
        setupTimer()
    }

    // MARK: - Public API

    func updatePace(_ smoothingAlpha: Double) {
        self.smoothingAlpha = smoothingAlpha
    }

    func fetchWattage() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }

            // Read primary power values from SMC
            // PSTR = total system power (includes SoC + screen + everything)
            let rawSystem = max(0.0, SMC.shared.getValue("PSTR") ?? 0.0)
            let rawDcIn = max(0.0, SMC.shared.getValue("PDTR") ?? 0.0)

            // Screen power from SMC (included in PSTR, but useful for breakdown)
            let rawScreen = max(0.0, SMC.shared.getValue("PDBR") ?? 0.0)

            // Read battery less frequently (it changes slowly)
            var snap: BatterySnapshot? = nil
            if self.batteryReadCounter == 0 {
                snap = BatteryInfo.shared.snapshot()
            }

            // Read IOReport less frequently (~1s intervals for meaningful deltas)
            var ioBreakdown: IOReportPowerBreakdown? = nil
            if self.ioReportReadCounter == 0, let reader = self.ioReportReader {
                ioBreakdown = reader.sample()
            }

            DispatchQueue.main.async {
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
            componentSmoothed.removeAll()
            lastIOReportBreakdown = nil
        } else {
            wattage += smoothingAlpha * (rawSystem - wattage)
            dcInWattage += smoothingAlpha * (rawDcIn - dcInWattage)
        }

        // Track rolling 5-minute history for time estimates
        wattageHistory.append(rawSystem)
        if wattageHistory.count > Self.historySize {
            wattageHistory.removeFirst()
        }

        // Update IOReport breakdown when new data arrives
        if let io = ioBreakdown {
            lastIOReportBreakdown = io
        }

        // Build component breakdown
        powerBreakdown = buildBreakdown(rawScreen: rawScreen)

        // Update battery snapshot and per-port USB power
        if let snap = batterySnap {
            battery = snap
            usbPortPower = snap.usbPortPower
        }
        batteryReadCounter = (batteryReadCounter + 1) % Self.batteryReadInterval
        ioReportReadCounter = (ioReportReadCounter + 1) % Self.ioReportReadInterval
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

            // Additional IOReport components (media engines, PCI, etc.)
            for comp in io.otherComponents {
                components.append(smoothedComponent(comp.label, raw: comp.watts))
            }
        }

        // Screen power from PDBR (included in PSTR)
        components.append(smoothedComponent("Screen", raw: rawScreen))

        // USB/External power: prefer per-port hardware measurement,
        // fall back to PSTR-gap calculation.
        //
        // PowerOutDetails (when available) gives actual measured milliwatts
        // per USB-C port from the PD controller hardware. When unavailable,
        // the PSTR gap (total system minus metered SoC minus screen) captures
        // the same power — it's a hardware measurement too, just aggregated.
        let meteredTotal = components.reduce(0.0) { $0 + $1.watts }
        if !usbPortPower.isEmpty {
            // Per-port data available from PowerOutDetails
            for port in usbPortPower {
                components.append(smoothedComponent("USB Port \(port.portIndex)", raw: port.watts))
            }
            // Still show residual for anything not captured by PD (e.g. VRM losses)
            let pdTotal = usbPortPower.reduce(0.0) { $0 + $1.watts }
            let residual = max(0, wattage - meteredTotal - pdTotal)
            if residual > 0.1 {
                components.append(smoothedComponent("Other", raw: residual))
            }
        } else {
            // Fallback: PSTR gap method — all external power lumped together
            let unmetered = max(0, wattage - meteredTotal)
            components.append(smoothedComponent("USB/Ext", raw: unmetered))
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
}

// MARK: - Supporting Types

struct PowerComponent {
    let label: String
    let watts: Double
}
