//
//  BatteryInfo.swift
//  WattSec
//
//  Created by Claude on 4/3/26.
//

import Foundation
import IOKit

struct BatterySnapshot {
    let currentCapacityMAh: Int    // AppleRawCurrentCapacity
    let maxCapacityMAh: Int        // AppleRawMaxCapacity
    let designCapacityMAh: Int     // DesignCapacity
    let voltageMV: Int             // Voltage in mV
    let cycleCount: Int
    let isCharging: Bool
    let isPluggedIn: Bool
    let temperatureC: Double       // Temperature / 100
    let timeToEmpty: Int           // minutes, -1 if unknown
    let timeToFull: Int            // minutes, -1 if unknown

    /// State of charge as percentage (0-100)
    var socPercent: Int {
        guard maxCapacityMAh > 0 else { return 0 }
        return min(100, (currentCapacityMAh * 100) / maxCapacityMAh)
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
        let voltage: Int = prop("Voltage") ?? 0
        let cycles: Int = prop("CycleCount") ?? 0
        let charging: Bool = prop("IsCharging") ?? false
        let pluggedIn: Bool = prop("ExternalConnected") ?? false
        let tempRaw: Int = prop("Temperature") ?? 0
        let tte: Int = prop("AvgTimeToEmpty") ?? -1
        let ttf: Int = prop("AvgTimeToFull") ?? -1

        return BatterySnapshot(
            currentCapacityMAh: currentCap,
            maxCapacityMAh: maxCap,
            designCapacityMAh: designCap,
            voltageMV: voltage,
            cycleCount: cycles,
            isCharging: charging,
            isPluggedIn: pluggedIn,
            temperatureC: Double(tempRaw) / 100.0,
            timeToEmpty: tte,
            timeToFull: ttf
        )
    }
}
