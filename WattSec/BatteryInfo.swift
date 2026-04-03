//
//  BatteryInfo.swift
//  WattSec
//
//  Created by Claude on 4/3/26.
//

import Foundation
import IOKit

/// Per-port USB-C power delivery measurement from PD controller hardware.
struct UsbPortPower {
    let portIndex: Int       // 1-indexed port number
    let watts: Double        // Actual measured power delivery in watts
}

struct BatterySnapshot {
    let currentCapacityMAh: Int    // AppleRawCurrentCapacity
    let maxCapacityMAh: Int        // AppleRawMaxCapacity
    let designCapacityMAh: Int     // DesignCapacity
    let socPercent: Int            // CurrentCapacity (macOS's own 0-100%)
    let voltageMV: Int             // Voltage in mV
    let cycleCount: Int
    let isCharging: Bool
    let isPluggedIn: Bool
    let temperatureC: Double       // Temperature / 100
    let timeToEmpty: Int           // minutes, -1 if unknown
    let timeToFull: Int            // minutes, -1 if unknown
    let usbPortPower: [UsbPortPower]  // Per-port USB-C power delivery

    /// Total USB power delivery across all ports
    var totalUsbPowerWatts: Double {
        usbPortPower.reduce(0) { $0 + $1.watts }
    }

    /// Current charge in Wh
    var currentCapacityWh: Double {
        Double(currentCapacityMAh) * Double(voltageMV) / 1_000_000.0
    }

    /// Max (usable) capacity in Wh
    var maxCapacityWh: Double {
        Double(maxCapacityMAh) * Double(voltageMV) / 1_000_000.0
    }

    /// Battery health percentage
    var healthPercent: Int {
        guard designCapacityMAh > 0 else { return 100 }
        return (maxCapacityMAh * 100) / designCapacityMAh
    }
}

class BatteryInfo {
    static let shared = BatteryInfo()

    func snapshot() -> BatterySnapshot? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        func prop<T>(_ key: String) -> T? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? T
        }

        let currentCap: Int = prop("AppleRawCurrentCapacity") ?? 0
        let maxCap: Int = prop("AppleRawMaxCapacity") ?? prop("MaxCapacity") ?? 0
        let designCap: Int = prop("DesignCapacity") ?? maxCap
        let socPct: Int = prop("CurrentCapacity") ?? 0
        let voltage: Int = prop("Voltage") ?? 0
        let cycles: Int = prop("CycleCount") ?? 0
        let charging: Bool = prop("IsCharging") ?? false
        let pluggedIn: Bool = prop("ExternalConnected") ?? false
        let tempRaw: Int = prop("Temperature") ?? 0
        let tte: Int = prop("AvgTimeToEmpty") ?? -1
        let ttf: Int = prop("AvgTimeToFull") ?? -1

        // Per-port USB-C power delivery (actual measured milliwatts from PD controller)
        var usbPorts: [UsbPortPower] = []
        if let details: [[String: Any]] = prop("PowerOutDetails") {
            for entry in details {
                let portIndex = entry["PortIndex"] as? Int ?? 0
                // PDPowermW is milliwatts; fall back to Watts key (also mW despite the name)
                let mw = entry["PDPowermW"] as? Int ?? entry["Watts"] as? Int ?? 0
                if mw > 0 {
                    usbPorts.append(UsbPortPower(portIndex: portIndex, watts: Double(mw) / 1000.0))
                }
            }
        }

        return BatterySnapshot(
            currentCapacityMAh: currentCap,
            maxCapacityMAh: maxCap,
            designCapacityMAh: designCap,
            socPercent: socPct,
            voltageMV: voltage,
            cycleCount: cycles,
            isCharging: charging,
            isPluggedIn: pluggedIn,
            temperatureC: Double(tempRaw) / 100.0,
            timeToEmpty: tte,
            timeToFull: ttf,
            usbPortPower: usbPorts
        )
    }
}
