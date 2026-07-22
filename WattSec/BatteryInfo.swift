//
//  BatteryInfo.swift
//  WattSec
//
//  Reads the AppleSmartBattery IORegistry entry — the battery gas gauge.
//
//  Capacity keys on Apple Silicon:
//    - CurrentCapacity / MaxCapacity: PERCENT (user-facing SoC; MaxCapacity
//      is always 100). Never treat these as mAh.
//    - AppleRawCurrentCapacity / AppleRawMaxCapacity: gas gauge mAh —
//      present on macOS ≤ 26; REMOVED from the top level on macOS 27.
//    - BatteryData.{RemainingCapacity, FullChargeCapacity,
//      NominalChargeCapacity, DesignCapacity}: the same gauge values on
//      macOS 27+ (verified against 7 days of logged registry dumps on
//      Mac16,6 / macOS 27 beta).
//  The user-facing percent is intentionally massaged by macOS. Fitted from
//  ~66h of logged data (docs/CALIBRATION.md):
//      discharge: displayed% ≈ 1.062×raw% − 1.05   (residual σ 0.65pp)
//      charge:    displayed% ≈ raw% + 1.07         (residual σ 0.35pp)
//      100% is pinned while raw% drifts 94..100.
//
//  PowerTelemetryData (macOS 13+) is measured mW telemetry and, per the
//  same logs, the most accurate power source available:
//    - SystemPowerIn = SystemVoltageIn×SystemCurrentIn exactly; ≈ SMC PDTR
//      (energy ratio 0.990 over 132 Wh).
//    - SystemLoad = SystemPowerIn − BatteryPower exactly (energy-balance
//      residual). On battery it equals true battery drain (energy ratio
//      1.013 over 263 Wh) while SMC PSTR under-reads by ~5% on average
//      (down to −21% in some segments). SystemLoad is therefore the
//      preferred headline source.
//    - AdapterEfficiencyLoss: measured charger conversion loss
//      (~3% of SystemPowerIn above 10 W).
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
    let currentCapacityMAh: Int    // AppleRawCurrentCapacity (0 if unavailable)
    let maxCapacityMAh: Int        // AppleRawMaxCapacity → NominalChargeCapacity (0 if unavailable)
    let designCapacityMAh: Int     // DesignCapacity
    let socPercent: Int            // CurrentCapacity (macOS's user-facing 0-100%)
    let voltageMV: Int             // Voltage in mV
    let amperageMA: Int?           // Amperage (averaged) in mA: + charging, − discharging
    let instantAmperageMA: Int?    // InstantAmperage in mA (point sample, tracks changes faster)
    let cellCount: Int?            // Series cell count (from CellVoltage array)
    let cycleCount: Int
    let isCharging: Bool
    let isPluggedIn: Bool
    let fullyCharged: Bool         // FullyCharged flag from the gauge
    let notChargingReason: Int     // ChargerData.NotChargingReason (0 = none)
    let temperatureC: Double       // Temperature / 100 (0 when unavailable)
    let timeToEmpty: Int           // minutes, -1 if unknown
    let timeToFull: Int            // minutes, -1 if unknown
    let usbPortPower: [UsbPortPower]  // Per-port USB-C power delivery

    // PowerTelemetryData (macOS 13+), mW → W. Units/sign verified against
    // 7 days of logged data; SystemLoad is the preferred headline source.
    let telemetrySystemLoadW: Double?
    let telemetrySystemPowerInW: Double?
    let telemetryBatteryPowerW: Double?
    let telemetryAdapterLossW: Double?

    /// The complete raw AppleSmartBattery property table for diagnostics
    /// logging. Not used for display.
    let rawProperties: [String: Any]

    /// Total USB power delivery across all ports
    var totalUsbPowerWatts: Double {
        usbPortPower.reduce(0) { $0 + $1.watts }
    }

    /// Averaged battery charge/discharge power from the gas gauge (W).
    /// Positive while charging, negative while discharging, ~0 when the
    /// battery is full or charging is on hold. Unlike PDTR − PSTR this is
    /// the energy actually entering/leaving the battery — it already
    /// includes charger conversion losses.
    var batteryPowerW: Double? {
        guard let amperageMA = amperageMA else { return nil }
        return Double(amperageMA) * Double(voltageMV) / 1_000_000.0
    }

    /// Instantaneous battery power (W) — same convention as batteryPowerW
    /// but from a point sample: noisier, tracks rate changes fastest.
    var instantBatteryPowerW: Double? {
        guard let instantAmperageMA = instantAmperageMA else { return nil }
        return Double(instantAmperageMA) * Double(voltageMV) / 1_000_000.0
    }

    /// Nominal pack voltage in mV from the physical series cell count
    /// (3.85 V/cell Li-polymer nominal — matches Apple's published Wh specs).
    /// Falls back to estimating the cell count from the live pack voltage.
    /// Used for the mAh→Wh scale so it doesn't wobble with load/charge.
    var nominalPackVoltageMV: Double? {
        let perCellNominal = 3850.0
        if let cells = cellCount, cells > 0 {
            let perCell = Double(voltageMV) / Double(cells)
            // Sanity: a real Li-ion cell sits between ~3.0 and ~4.6 V
            if voltageMV == 0 || (perCell >= 3000 && perCell <= 4600) {
                return Double(cells) * perCellNominal
            }
        }
        guard voltageMV > 0 else { return nil }
        let estimatedCells = max(1, Int((Double(voltageMV) / perCellNominal).rounded()))
        return Double(estimatedCells) * perCellNominal
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

        // Fetch the whole property table in one call — cheaper than per-key
        // lookups, and the diagnostics logger records it verbatim.
        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let props = propsRef?.takeRetainedValue() as? [String: Any]
        else { return nil }

        func prop<T>(_ key: String) -> T? { props[key] as? T }
        let batteryData = (props["BatteryData"] as? [String: Any]) ?? [:]
        func bdProp<T>(_ key: String) -> T? { batteryData[key] as? T }

        // Max capacity in mAh. On Apple Silicon "MaxCapacity" is a PERCENT
        // (always 100) — using it as mAh is how a "1.2 Wh battery" happens.
        // On macOS 27+ the mAh keys moved from the top level into
        // BatteryData, so both locations are tried. Reject anything
        // percent-scale.
        func plausibleMAh(_ value: Int?) -> Int? {
            guard let value = value, value > 500 else { return nil }
            return value
        }
        let maxCap = plausibleMAh(prop("AppleRawMaxCapacity"))
            ?? plausibleMAh(bdProp("FullChargeCapacity"))
            ?? plausibleMAh(prop("NominalChargeCapacity"))
            ?? plausibleMAh(bdProp("NominalChargeCapacity"))
            ?? 0
        let designCap = plausibleMAh(prop("DesignCapacity"))
            ?? plausibleMAh(bdProp("DesignCapacity"))
            ?? maxCap
        let currentCap: Int = prop("AppleRawCurrentCapacity")
            ?? bdProp("RemainingCapacity")
            ?? 0

        let socPct: Int = prop("CurrentCapacity") ?? 0
        let voltage: Int = prop("Voltage") ?? 0
        let cycles: Int = prop("CycleCount") ?? 0
        let charging: Bool = prop("IsCharging") ?? false
        let pluggedIn: Bool = prop("ExternalConnected") ?? false
        let fullyCharged: Bool = prop("FullyCharged") ?? false
        let tempRaw: Int = prop("Temperature") ?? 0
        let chargerData = (props["ChargerData"] as? [String: Any]) ?? [:]
        let notChargingReason = chargerData["NotChargingReason"] as? Int ?? 0

        // Amperage (averaged) and InstantAmperage: signed mA, positive while
        // charging. Some firmware exposes them as an unsigned container
        // holding a 32-bit two's complement value — normalize that.
        func signedMilliamps(_ key: String) -> Int? {
            guard var value: Int = prop(key) else { return nil }
            if value > Int(Int32.max) {
                value -= Int(UInt32.max) + 1
            }
            return value
        }
        let amperage = signedMilliamps("Amperage")
        let instantAmperage = signedMilliamps("InstantAmperage")

        // Physical series cell count — CellVoltage has one entry per cell
        // group, which pins down the pack's nominal voltage exactly.
        let cellCount: Int? = {
            guard let volts: [Int] = prop("CellVoltage") else { return nil }
            let n = volts.filter { $0 > 0 }.count
            return n > 0 ? n : nil
        }()

        // IOKit reports 65535 (0xFFFF) for "unknown / still calculating".
        // Without this check the UI shows "Time Left 1092:15".
        func estimateMinutes(_ key: String) -> Int {
            let value: Int = prop(key) ?? -1
            return (value <= 0 || value >= 65535) ? -1 : value
        }
        let tte = estimateMinutes("AvgTimeToEmpty")
        let ttf = estimateMinutes("AvgTimeToFull")

        // PowerTelemetryData (macOS 13+): hardware-measured mW telemetry.
        var telemetrySystemLoadW: Double? = nil
        var telemetrySystemPowerInW: Double? = nil
        var telemetryBatteryPowerW: Double? = nil
        var telemetryAdapterLossW: Double? = nil
        if let telemetry: [String: Any] = prop("PowerTelemetryData") {
            func milliwatts(_ key: String) -> Double? {
                (telemetry[key] as? Int).map { Double($0) / 1000.0 }
            }
            telemetrySystemLoadW = milliwatts("SystemLoad")
            telemetrySystemPowerInW = milliwatts("SystemPowerIn")
            telemetryBatteryPowerW = milliwatts("BatteryPower")
            telemetryAdapterLossW = milliwatts("AdapterEfficiencyLoss")
        }

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
                        locationID: UInt32(truncatingIfNeeded: locationID)
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
            instantAmperageMA: instantAmperage,
            cellCount: cellCount,
            cycleCount: cycles,
            isCharging: charging,
            isPluggedIn: pluggedIn,
            fullyCharged: fullyCharged,
            notChargingReason: notChargingReason,
            temperatureC: Double(tempRaw) / 100.0,
            timeToEmpty: tte,
            timeToFull: ttf,
            usbPortPower: usbPorts,
            telemetrySystemLoadW: telemetrySystemLoadW,
            telemetrySystemPowerInW: telemetrySystemPowerInW,
            telemetryBatteryPowerW: telemetryBatteryPowerW,
            telemetryAdapterLossW: telemetryAdapterLossW,
            rawProperties: props
        )
    }
}
