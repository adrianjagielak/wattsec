//
//  BatteryInfo.swift
//  WattSec
//
//  Created by Claude on 4/3/26.
//

import Foundation
import IOKit

/// Per-port USB-C power delivery measurement from PD controller hardware.
///
/// Source: "PowerOutDetails" array on AppleSmartBattery IORegistry entry.
/// Each entry contains { PortIndex, PDPowermW, Watts, LocationID }.
/// PDPowermW and Watts are both in milliwatts (Watts is misnamed).
///
/// Availability: NOT present on all Apple Silicon models/macOS versions.
/// When absent, the property simply doesn't exist in the registry.
/// macpow (k06a/macpow) and other tools also depend on this and
/// silently return empty data when it's missing.
/// No workaround is known; it appears to be firmware-dependent.
struct UsbPortPower {
    let portIndex: Int       // 1-indexed port number
    let watts: Double        // Actual measured power delivery in watts
    let locationID: UInt32   // USB location ID for device correlation
}

struct BatterySnapshot {
    let currentCapacityMAh: Int    // AppleRawCurrentCapacity
    let maxCapacityMAh: Int        // AppleRawMaxCapacity
    let designCapacityMAh: Int     // DesignCapacity
    let socPercent: Int            // CurrentCapacity (macOS's own 0-100%)
    let voltageMV: Int             // Voltage in mV
    let amperageMA: Int?           // Amperage in mA: + charging, − discharging
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

    /// Measured battery charge/discharge power from the gas gauge (W).
    /// Positive while charging, negative while discharging, ~0 when the
    /// battery is full or charging is on hold. This is the ground truth
    /// for energy actually entering/leaving the battery — unlike
    /// PDTR − PSTR, it excludes charger conversion losses.
    var batteryPowerW: Double? {
        guard let amperageMA = amperageMA else { return nil }
        return Double(amperageMA) * Double(voltageMV) / 1_000_000.0
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

        // Amperage: signed mA, positive while charging. Some firmware exposes
        // it as an unsigned container holding a 32-bit two's complement value.
        var amperage: Int? = prop("Amperage")
        if let raw = amperage, raw > Int(Int32.max) {
            amperage = raw - (Int(UInt32.max) + 1)
        }

        // IOKit reports 65535 (0xFFFF) for "unknown / still calculating".
        // Without this check the UI shows "Time Left 1092:15".
        func estimateMinutes(_ key: String) -> Int {
            let value: Int = prop(key) ?? -1
            return (value <= 0 || value >= 65535) ? -1 : value
        }
        let tte = estimateMinutes("AvgTimeToEmpty")
        let ttf = estimateMinutes("AvgTimeToFull")

        // Per-port USB-C power delivery (actual measured milliwatts from PD controller).
        // PowerOutDetails is an undocumented property that provides hardware-measured
        // power delivery per USB-C port. It is NOT available on all Apple Silicon machines.
        // When absent, the property simply doesn't exist (returns nil).
        // macpow (k06a) uses the same approach with no fallback.
        //
        // Keys per entry:
        //   "Watts" (int, milliwatts despite the name) -- preferred by macpow
        //   "PDPowermW" (int, milliwatts) -- fallback
        //   "PortIndex" (int) -- 1-indexed port number
        //   "LocationID" (int) -- USB location ID for device correlation
        var usbPorts: [UsbPortPower] = []
        if let details: [[String: Any]] = prop("PowerOutDetails") {
            for entry in details {
                let portIndex = entry["PortIndex"] as? Int ?? 0
                let locationID = entry["LocationID"] as? Int ?? 0
                // Watts key is preferred (same convention as macpow); PDPowermW as fallback
                let wattsMw = entry["Watts"] as? Int ?? 0
                let pdMw = entry["PDPowermW"] as? Int ?? 0
                let mw = wattsMw > 0 ? wattsMw : pdMw
                if mw > 0 {
                    usbPorts.append(UsbPortPower(
                        portIndex: portIndex,
                        watts: Double(mw) / 1000.0,
                        locationID: UInt32(locationID)
                    ))
                }
            }
        }

        return BatterySnapshot(
            currentCapacityMAh: currentCap,
            maxCapacityMAh: maxCap,
            designCapacityMAh: designCap,
            socPercent: socPct,
            voltageMV: voltage,
            amperageMA: amperage,
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
