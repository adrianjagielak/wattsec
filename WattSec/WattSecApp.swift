//
//  WattSecApp.swift
//  WattSec
//
//  Created by Ben Beutton on 3/4/25.
//

import Cocoa
import Combine
import Foundation
import ServiceManagement
import SwiftUI

// MARK: - Main App

@main
struct WattSecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - Enums

enum DetailLevel: Int, CaseIterable {
    case low = 0
    case medium = 1
    case high = 2
}

enum PaceLevel: Int, CaseIterable {
    case on = 1
    case off = 0

    /// EMA smoothing factor: 0.1 = smooth, 1.0 = raw values
    var smoothingAlpha: Double {
        switch self {
        case .on: return 0.1
        case .off: return 1.0
        }
    }
}

enum WidthMode: String, CaseIterable {
    case dynamic
    case fixed
}

// MARK: Default Settings

private struct Defaults {
    static let detailLevel: DetailLevel = .medium
    static let paceLevel: PaceLevel = .on
    static let widthMode: WidthMode = .dynamic
}

// MARK: Constants

private struct Constants {
    static let highWattageTimeoutSeconds: TimeInterval = 60.0
    static let highWattageThreshold: Double = 100.0
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: Properties

    private var statusItem: NSStatusItem?
    private var wattageSubscription: AnyCancellable?

    private var detailLevel: DetailLevel = Defaults.detailLevel
    private var paceLevel: PaceLevel = Defaults.paceLevel
    private var widthMode: WidthMode = Defaults.widthMode
    private var launchAtLogin: Bool = false

    // New properties for fixed width mode
    private var widestWidths: [DetailLevel: [Int: CGFloat]] = [:]
    private var highWattageTimestamp: Date?
    private var highWattageTimer: Timer?

    // Battery info menu items (updated dynamically)
    private var batteryCapacityItem: NSMenuItem?
    private var batteryTimeItem: NSMenuItem?
    private var batteryCyclesItem: NSMenuItem?
    private var batteryTempItem: NSMenuItem?
    // Power section items (pre-created, titles updated)
    private var powerSystemItem: NSMenuItem?
    private var powerDcInItem: NSMenuItem?
    private var powerNetItem: NSMenuItem?
    private var powerBreakdownItems: [NSMenuItem] = []
    private static let maxBreakdownItems = 16
    
    // MARK: Application Lifecycle
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        loadUserPreferences()
        setupMenuBar()
        calculateWidestWidths()
        bindToPowerMonitor()
        PowerMonitor.shared.fetchWattage()
        checkLaunchAtLoginStatus()
    }
    
    deinit {
        // Cancel subscription to prevent memory leaks
        wattageSubscription?.cancel()
        highWattageTimer?.invalidate()
    }
    
    // MARK: User Preferences
    
    private func loadUserPreferences() {
        let defaults = UserDefaults.standard
        let currentVersion = 3
        let savedVersion = defaults.integer(forKey: "settingsVersion")
        
        if savedVersion < currentVersion {
            // Reset to defaults if version is outdated, then update version
            defaults.set(currentVersion, forKey: "settingsVersion")
            defaults.set(Defaults.detailLevel.rawValue, forKey: "detailLevel")
            defaults.set(Defaults.paceLevel.rawValue, forKey: "paceLevel")
            defaults.set(Defaults.widthMode.rawValue, forKey: "widthMode")
            // We don't need to set launchAtLogin in UserDefaults anymore
        }
        
        detailLevel = DetailLevel(rawValue: defaults.integer(forKey: "detailLevel")) ?? Defaults.detailLevel
        paceLevel = PaceLevel(rawValue: defaults.integer(forKey: "paceLevel")) ?? Defaults.paceLevel
        widthMode = WidthMode(rawValue: defaults.string(forKey: "widthMode") ?? Defaults.widthMode.rawValue) ?? Defaults.widthMode
        
        // We'll set launchAtLogin in checkLaunchAtLoginStatus() instead
        
        PowerMonitor.shared.updatePace(paceLevel.smoothingAlpha)
    }
    
    // MARK: Widest Width Calculation
    
    private func calculateWidestWidths() {
        // Widest strings for each detail level and character count
        let widestStrings: [DetailLevel: [Int: String]] = [
            .low: [
                3: "20W",    // 3 chars
                4: "344W"    // 4 chars
            ],
            .medium: [
                5: "44.4W",  // 5 chars
                6: "304.4W"  // 6 chars
            ],
            .high: [
                6: "30.44W", // 6 chars
                7: "204.44W" // 7 chars
            ]
        ]
        
        // Calculate widths for widest strings
        for (level, strings) in widestStrings {
            widestWidths[level] = [:]
            for (charCount, widestString) in strings {
                if let button = statusItem?.button {
                    let width = ceil(estimateTextWidth(widestString, font: button.font ?? .systemFont(ofSize: NSFont.systemFontSize))) + 1
                    widestWidths[level]?[charCount] = width
                }
            }
        }
    }
    
    // MARK: Menu Setup
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        guard let statusItem = statusItem else {
            print("Failed to create status item. Terminating app.")
            NSApplication.shared.terminate(self)
            return
        }
        
        if let button = statusItem.button {
            button.action = #selector(showMenu)
            button.target = self
        }
        
        let menu = NSMenu()

        // Battery section
        batteryCapacityItem = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
        batteryCapacityItem?.isEnabled = false
        menu.addItem(batteryCapacityItem!)

        batteryTimeItem = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
        batteryTimeItem?.isEnabled = false
        menu.addItem(batteryTimeItem!)

        batteryCyclesItem = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
        batteryCyclesItem?.isEnabled = false
        menu.addItem(batteryCyclesItem!)

        batteryTempItem = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
        batteryTempItem?.isEnabled = false
        menu.addItem(batteryTempItem!)

        menu.addItem(NSMenuItem.separator())

        // Power section (pre-created, updated dynamically)
        powerSystemItem = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
        powerSystemItem?.isEnabled = false
        menu.addItem(powerSystemItem!)

        powerDcInItem = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
        powerDcInItem?.isEnabled = false
        powerDcInItem?.isHidden = true
        menu.addItem(powerDcInItem!)

        powerNetItem = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
        powerNetItem?.isEnabled = false
        powerNetItem?.isHidden = true
        menu.addItem(powerNetItem!)

        // Pre-create breakdown item slots
        for _ in 0..<Self.maxBreakdownItems {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.isHidden = true
            menu.addItem(item)
            powerBreakdownItems.append(item)
        }

        menu.addItem(NSMenuItem.separator())

        // Settings
        menu.addItem(createDetailMenuItem())
        menu.addItem(createPaceMenuItem())
        menu.addItem(createWidthModeItem())
        menu.addItem(NSMenuItem.separator())
        menu.addItem(createLaunchAtLoginMenuItem())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }
    
    private func createDetailMenuItem() -> NSMenuItem {
        let menuItem = NSMenuItem(title: "Detail", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        
        for level in DetailLevel.allCases {
            let label = String(describing: level).capitalized
            let item = createStyledMenuItem(
                title: label,
                suffix: "\(level.rawValue)",
                action: #selector(changeDetailLevel),
                value: level.rawValue,
                isSelected: level == detailLevel
            )
            submenu.addItem(item)
        }
        
        menuItem.submenu = submenu
        return menuItem
    }
    
    private func createPaceMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Smoothing", action: #selector(toggleSmoothing), keyEquivalent: "")
        item.target = self
        item.state = paceLevel == .on ? .on : .off
        return item
    }
    
    private func createWidthModeItem() -> NSMenuItem {
        let menuItem = NSMenuItem(title: "Width", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        
        for mode in WidthMode.allCases {
            let label = mode == .dynamic ? "Dynamic" : "Fixed"
            let item = NSMenuItem(title: label, action: #selector(changeWidthMode), keyEquivalent: "")
            item.representedObject = mode.rawValue
            item.target = self
            item.state = mode == widthMode ? .on : .off
            submenu.addItem(item)
        }
        
        menuItem.submenu = submenu
        return menuItem
    }
    
    private func createLaunchAtLoginMenuItem() -> NSMenuItem {
        let menuItem = NSMenuItem(title: "Launch", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        
        let item = NSMenuItem(title: "at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        item.target = self
        item.state = launchAtLogin ? .on : .off
        submenu.addItem(item)
        
        menuItem.submenu = submenu
        return menuItem
    }
    
    // MARK: Menu Actions
    
    @objc private func changeDetailLevel(sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? Int,
              let newLevel = DetailLevel(rawValue: rawValue) else { return }
        
        detailLevel = newLevel
        UserDefaults.standard.set(rawValue, forKey: "detailLevel")
        updateWattageDisplay()
        updateMenuStates(sender.menu, selectedValue: rawValue)
    }
    
    @objc private func toggleSmoothing(sender: NSMenuItem) {
        paceLevel = paceLevel == .on ? .off : .on
        UserDefaults.standard.set(paceLevel.rawValue, forKey: "paceLevel")
        PowerMonitor.shared.updatePace(paceLevel.smoothingAlpha)
        sender.state = paceLevel == .on ? .on : .off
    }
    
    @objc private func changeWidthMode(sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let newMode = WidthMode(rawValue: rawValue) else { return }
        
        widthMode = newMode
        UserDefaults.standard.set(rawValue, forKey: "widthMode")
        
        switch newMode {
        case .dynamic:
            statusItem?.length = NSStatusItem.variableLength
            highWattageTimer?.invalidate()
            highWattageTimer = nil
            highWattageTimestamp = nil
        case .fixed:
            // Initialize widest widths if needed
            if widestWidths.isEmpty {
                calculateWidestWidths()
            }
        }
        
        updateWattageDisplay()
        updateMenuStates(sender.menu, selectedValue: rawValue)
    }
    
    // MARK: Display Updates

    private func updateWattageDisplay() {
        let fmt = detailLevelFormatString()
        guard let button = statusItem?.button else { return }

        let monitor = PowerMonitor.shared
        let soc = monitor.battery?.socPercent ?? 0
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let defaultAttrs: [NSAttributedString.Key: Any] = [.font: font]

        if monitor.isCharging {
            let dcIn = String(format: fmt, monitor.dcInWattage)
            let consumption = String(format: fmt, monitor.wattage)
            let text = "\u{26A1}\(dcIn)  -\(consumption)  \(soc)%"
            button.attributedTitle = NSAttributedString(string: text, attributes: defaultAttrs)
        } else {
            // Time to 10% SoC based on 5-minute average drain
            let timeStr = timeToLowBattery(monitor: monitor)
            let consumption = String(format: fmt, monitor.wattage)
            let text = "\(timeStr)  -\(consumption)  \(soc)%"

            let attributed = NSMutableAttributedString(string: text, attributes: defaultAttrs)

            // Color the time portion: red at ≤10%, orange when Low Power Mode is on
            let timeRange = NSRange(location: 0, length: timeStr.count)
            if soc <= 10 {
                attributed.addAttribute(.foregroundColor, value: NSColor.systemRed, range: timeRange)
            } else if ProcessInfo.processInfo.isLowPowerModeEnabled {
                attributed.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: timeRange)
            }

            button.attributedTitle = attributed
        }

        if widthMode == .fixed {
            let text = button.attributedTitle.string
            updateFixedWidth(for: text, wattage: monitor.wattage)
        }
    }

    private func timeToLowBattery(monitor: PowerMonitor) -> String {
        // Use the same SoC-derived Wh as the Capacity row so the estimate
        // always agrees with the displayed percentage and capacity.
        guard let cap = monitor.interpolatedCapacity() else { return "--:--" }

        let avgPower = monitor.averageWattage
        guard avgPower > 0.5 else { return "--:--" }

        // Remaining Wh until 10% SoC
        let remainingWh = cap.currentWh - cap.maxWh * 0.10
        guard remainingWh > 0 else { return "0:00" }

        let hoursLeft = remainingWh / avgPower
        let totalMinutes = Int(hoursLeft * 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return String(format: "%d:%02d", hours, minutes)
    }

    private func updateBatteryMenuItems() {
        let monitor = PowerMonitor.shared
        let bat = monitor.battery

        // Battery section
        if let bat = bat {
            // Use interpolated Wh (sub-percent granularity, stable voltage)
            if let cap = monitor.interpolatedCapacity() {
                batteryCapacityItem?.title = String(format: "Capacity    %.1f / %.1f Wh", cap.currentWh, cap.maxWh)
            }

            if monitor.isCharging {
                if !bat.isCharging {
                    // On AC but the battery isn't taking charge — either
                    // full or held back (charge limiting / heat). Without
                    // this check the row says "calculating..." forever.
                    batteryTimeItem?.title = bat.socPercent >= 100
                        ? "Fully Charged"
                        : "Charging Paused"
                } else if bat.timeToFull > 0 {
                    batteryTimeItem?.title = String(format: "Time to Full    %d:%02d", bat.timeToFull / 60, bat.timeToFull % 60)
                } else {
                    batteryTimeItem?.title = "Time to Full    calculating..."
                }
            } else {
                if bat.timeToEmpty > 0 {
                    batteryTimeItem?.title = String(format: "Time Left    %d:%02d", bat.timeToEmpty / 60, bat.timeToEmpty % 60)
                } else {
                    batteryTimeItem?.title = "Time Left    calculating..."
                }
            }

            batteryCyclesItem?.title = "Cycles    \(bat.cycleCount)"
            batteryTempItem?.title = String(format: "Temp    %.1f\u{00B0}C", bat.temperatureC)
        }

        // Power section — update titles only, never add/remove items
        let fmt = detailLevelFormatString()
        powerSystemItem?.title = "System    " + String(format: fmt, monitor.wattage)

        if monitor.isCharging {
            powerDcInItem?.title = "DC In    " + String(format: fmt, monitor.dcInWattage)
            powerDcInItem?.isHidden = false
            // Prefer the gas gauge's measured battery power over the
            // DC-in-minus-system estimate, which includes charger
            // conversion losses and reads nonzero on a full battery.
            let batteryW = monitor.battery?.batteryPowerW
                ?? (monitor.dcInWattage - monitor.wattage)
            if batteryW >= 0 {
                powerNetItem?.title = "To Battery    " + String(format: fmt, batteryW)
            } else {
                powerNetItem?.title = "From Battery    " + String(format: fmt, -batteryW)
            }
            powerNetItem?.isHidden = false
        } else {
            powerDcInItem?.isHidden = true
            powerNetItem?.isHidden = true
        }

        // Component breakdown — fill pre-created slots
        let breakdown = monitor.powerBreakdown
        for (i, item) in powerBreakdownItems.enumerated() {
            if i < breakdown.count {
                item.title = "  \(breakdown[i].label)    " + String(format: fmt, breakdown[i].watts)
                item.isHidden = false
            } else {
                item.isHidden = true
            }
        }
    }

    private func updateFixedWidth(for wattageText: String, wattage: Double) {
        let charCount = wattageText.count
        let isHighWattage = wattage >= Constants.highWattageThreshold
        
        guard let widthsForLevel = widestWidths[detailLevel],
              !widthsForLevel.isEmpty else {
            return
        }
        
        let sortedCharCounts = widthsForLevel.keys.sorted()
        let smallestCharCount = sortedCharCounts.first ?? 0
        let largestCharCount = sortedCharCounts.last ?? 0
        
        if isHighWattage {
            // For high wattage (≥100), use the largest width
            if highWattageTimestamp == nil {
                highWattageTimestamp = Date()
                if let width = widthsForLevel[largestCharCount] {
                    statusItem?.length = width
                }
                
                // Cancel any existing timer
                highWattageTimer?.invalidate()
                highWattageTimer = nil
            }
        } else {
            // For lower wattage, determine appropriate width based on character count
            let targetCharCount = charCount <= smallestCharCount ? smallestCharCount : 
                                 (charCount >= largestCharCount ? largestCharCount : charCount)
            
            // If we were in high wattage mode, check if we should scale back
            if let timestamp = highWattageTimestamp {
                let timeInHighWattage = Date().timeIntervalSince(timestamp)
                
                if timeInHighWattage >= Constants.highWattageTimeoutSeconds {
                    // Scale back after timeout period
                    highWattageTimestamp = nil
                    if let width = widthsForLevel[targetCharCount] {
                        statusItem?.length = width
                    }
                    
                    // Cancel any existing timer
                    highWattageTimer?.invalidate()
                    highWattageTimer = nil
                } else if highWattageTimer == nil {
                    // Set a timer to check again after the remaining time
                    let remainingTime = Constants.highWattageTimeoutSeconds - timeInHighWattage
                    highWattageTimer = Timer.scheduledTimer(withTimeInterval: remainingTime, repeats: false) { [weak self] _ in
                        self?.checkHighWattageTimeout()
                    }
                }
            } else {
                // Normal mode - use width based on character count
                if let width = widthsForLevel[targetCharCount] {
                    statusItem?.length = width
                }
            }
        }
    }
    
    private func checkHighWattageTimeout() {
        guard let timestamp = highWattageTimestamp else {
            return
        }
        
        let timeInHighWattage = Date().timeIntervalSince(timestamp)
        if timeInHighWattage >= Constants.highWattageTimeoutSeconds && PowerMonitor.shared.wattage < Constants.highWattageThreshold {
            // Scale back after timeout period if wattage is still low
            highWattageTimestamp = nil
            
            // Update display with appropriate width
            updateWattageDisplay()
        }
        
        // Clear the timer
        highWattageTimer = nil
    }
    
    // MARK: Helper Methods
    
    private func createStyledMenuItem(title: String, suffix: String, action: Selector, value: Any, isSelected: Bool) -> NSMenuItem {
        let fullText = "\(title)  \(suffix)"
        let attributedTitle = NSMutableAttributedString(string: fullText)
        
        let suffixRange = (fullText as NSString).range(of: suffix)
        let smallFont = NSFont.systemFont(ofSize: 11)
        attributedTitle.addAttributes([
            .font: smallFont,
            .foregroundColor: NSColor.darkGray
        ], range: suffixRange)
        
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.attributedTitle = attributedTitle
        item.representedObject = value
        item.target = self
        item.state = isSelected ? .on : .off
        return item
    }
    
    private func detailLevelFormatString() -> String {
        switch detailLevel {
        case .low: return "%.0fW"
        case .medium: return "%.1fW"
        case .high: return "%.2fW"
        }
    }
    
    private func estimateTextWidth(_ text: String, font: NSFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return (text as NSString).size(withAttributes: attributes).width
    }
    
    private func updateMenuStates(_ menu: NSMenu?, selectedValue: Any) {
        menu?.items.forEach { item in
            if item.representedObject as AnyObject? === selectedValue as AnyObject? {
                item.state = .on
            } else {
                item.state = .off
            }
        }
    }
    
    private func bindToPowerMonitor() {
        wattageSubscription = PowerMonitor.shared.$wattage
            .combineLatest(PowerMonitor.shared.$dcInWattage, PowerMonitor.shared.$battery)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in
                self?.updateWattageDisplay()
                self?.updateBatteryMenuItems()
            }
    }
    
    // MARK: Menu Actions
    
    @objc private func showMenu() {
        statusItem?.button?.performClick(nil)
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    // MARK: Launch at Login
    
    private func checkLaunchAtLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        
        // Update menu item state if menu exists
        if let menu = statusItem?.menu {
            for item in menu.items {
                if let submenu = item.submenu, 
                   let loginItem = submenu.items.first(where: { $0.action == #selector(toggleLaunchAtLogin) }) {
                    loginItem.state = launchAtLogin ? .on : .off
                    break
                }
            }
        }
    }
    
    @objc private func toggleLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
                launchAtLogin = false
            } else {
                try SMAppService.mainApp.register()
                launchAtLogin = true
            }
            
            // Update menu item state
            if let menu = statusItem?.menu {
                for item in menu.items {
                    if let submenu = item.submenu, 
                       let loginItem = submenu.items.first(where: { $0.action == #selector(toggleLaunchAtLogin) }) {
                        loginItem.state = launchAtLogin ? .on : .off
                        break
                    }
                }
            }
        } catch let error as NSError {
            print("Error toggling launch at login: \(error.localizedDescription)")
            print("Error domain: \(error.domain), code: \(error.code)")
            if let reason = error.userInfo[NSLocalizedFailureReasonErrorKey] as? String {
                print("Reason: \(reason)")
            }
            
            let alert = NSAlert()
            alert.messageText = "Launch at Login Error"
            alert.informativeText = "Could not change launch at login setting: \(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            
            // Reset the state to match the actual system state
            checkLaunchAtLoginStatus()
        }
    }
}
