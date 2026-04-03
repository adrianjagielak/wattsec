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
            let rawSystem = max(0.0, SMC.shared.getValue("PSTR") ?? 0.0)
            let rawDcIn = max(0.0, SMC.shared.getValue("PDTR") ?? 0.0)

            // Screen power from SMC (IOReport doesn't track display)
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

        // Update battery snapshot
        if let snap = batterySnap {
            battery = snap
        }
        batteryReadCounter = (batteryReadCounter + 1) % Self.batteryReadInterval
        ioReportReadCounter = (ioReportReadCounter + 1) % Self.ioReportReadInterval
    }

    private func buildBreakdown(rawScreen: Double) -> [PowerComponent] {
        var components: [PowerComponent] = []

        if let io = lastIOReportBreakdown {
            // Primary IOReport components
            components.append(smoothedComponent("CPU", raw: io.cpuWatts))
            components.append(smoothedComponent("GPU", raw: io.gpuTotalWatts))
            components.append(smoothedComponent("ANE", raw: io.aneWatts))
            components.append(smoothedComponent("DRAM", raw: io.dramWatts))

            // Additional IOReport components (media engines, PCI, etc.)
            for comp in io.otherComponents {
                components.append(smoothedComponent(comp.label, raw: comp.watts))
            }
        }

        // Screen power shown as info but NOT added to sum.
        // PSTR already includes screen power, and IOReport channels
        // already cover nearly all of PSTR, so adding PDBR would double-count.
        // Show it as a separate informational item.
        components.append(PowerComponent(label: "Screen*", watts: rawScreen))

        // "Other" = PSTR total minus IOReport metered total
        // (does NOT include Screen since Screen is already in PSTR)
        let ioTotal = components.filter { $0.label != "Screen*" }
            .reduce(0.0) { $0 + $1.watts }
        let other = max(0, wattage - ioTotal)
        components.append(smoothedComponent("Other", raw: other))

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
