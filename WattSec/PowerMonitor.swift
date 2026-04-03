//
//  PowerMonitor.swift
//  WattSec
//
//  Centralized power monitoring: reads SMC sensors, tracks battery state,
//  maintains smoothed values and rolling averages for display.
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
    /// 5 minutes of samples at 200ms = 1500 entries
    private static let historySize = 1500

    // MARK: - Private State

    private var timer: AnyCancellable?
    private var isFirstReading = true
    private var wasCharging = false
    private var batteryReadCounter = 0
    private var wattageHistory: [Double] = []

    /// SMC keys to try for power breakdown.
    /// Keys that return nil on a given machine are auto-discovered and skipped.
    private static let smcBreakdownKeys: [(label: String, key: String)] = [
        ("CPU", "PCPT"),         // CPU Package Total
        ("CPU", "PCTR"),         // CPU Total Rail (fallback)
        ("GPU", "PGTR"),         // GPU Total Rail
        ("ANE", "PANT"),         // Apple Neural Engine
        ("DRAM", "PDMR"),        // DRAM power
        ("Screen", "PDBR"),      // Display Brightness
    ]

    /// Tracks which SMC keys actually exist on this machine (discovered on first read)
    private var availableSmcKeys: [(label: String, key: String)]?
    /// Smoothed values for each component (keyed by label)
    private var componentSmoothed: [String: Double] = [:]

    // MARK: - Init

    private init() {
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

            // Read battery less frequently (it changes slowly)
            var snap: BatterySnapshot? = nil
            if self.batteryReadCounter == 0 {
                snap = BatteryInfo.shared.snapshot()
            }

            // Read SMC breakdown keys
            let smcBreakdown = self.readSmcBreakdown()

            DispatchQueue.main.async {
                self.applyReadings(
                    rawSystem: rawSystem,
                    rawDcIn: rawDcIn,
                    batterySnap: snap,
                    smcBreakdown: smcBreakdown
                )
            }
        }
    }

    // MARK: - Private: Reading

    private func readSmcBreakdown() -> [(label: String, key: String, value: Double)] {
        let keysToRead = availableSmcKeys ?? Self.smcBreakdownKeys

        var results: [(label: String, key: String, value: Double)] = []
        var seenLabels = Set<String>()

        for (label, key) in keysToRead {
            // Skip duplicate labels (e.g., CPU has two fallback keys — use first that works)
            guard !seenLabels.contains(label) else { continue }
            if let val = SMC.shared.getValue(key) {
                results.append((label: label, key: key, value: max(0.0, val)))
                seenLabels.insert(label)
            }
        }

        return results
    }

    // MARK: - Private: Processing

    private func applyReadings(
        rawSystem: Double,
        rawDcIn: Double,
        batterySnap: BatterySnapshot?,
        smcBreakdown: [(label: String, key: String, value: Double)]
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
        } else {
            wattage += smoothingAlpha * (rawSystem - wattage)
            dcInWattage += smoothingAlpha * (rawDcIn - dcInWattage)
        }

        // Track rolling 5-minute history for time estimates
        wattageHistory.append(rawSystem)
        if wattageHistory.count > Self.historySize {
            wattageHistory.removeFirst()
        }

        // Lock in discovered SMC keys after first successful read
        if availableSmcKeys == nil && !smcBreakdown.isEmpty {
            availableSmcKeys = smcBreakdown.map { ($0.label, $0.key) }
        }

        // Smooth component breakdown
        var breakdown: [PowerComponent] = []
        for item in smcBreakdown {
            let prev = componentSmoothed[item.label] ?? item.value
            let smoothed = prev + smoothingAlpha * (item.value - prev)
            componentSmoothed[item.label] = smoothed
            breakdown.append(PowerComponent(label: item.label, watts: smoothed))
        }
        powerBreakdown = breakdown

        // Update battery snapshot
        if let snap = batterySnap {
            battery = snap
        }
        batteryReadCounter = (batteryReadCounter + 1) % Self.batteryReadInterval
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
