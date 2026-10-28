import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = Monitor()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        let host = NSHostingController(rootView: PopoverView(monitor: monitor))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        monitor.onUpdate = { [weak self] in self?.updateTitle() }
        monitor.log.logEvent("BatteryWatch started")
        monitor.sample()
        // A quick second sample so CPU usage shows up without waiting a full minute.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.monitor.sample() }

        timer = Timer.scheduledTimer(withTimeInterval: Monitor.interval, repeats: true) { [weak self] _ in
            self?.monitor.sample()
        }
        timer?.tolerance = 10

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.monitor.willSleep()
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.monitor.didWake()
        }
    }

    private func updateTitle() {
        guard let s = monitor.latest, let button = statusItem.button else { return }
        let warn = monitor.sustainedHogs.values.contains { $0 >= Monitor.hogSamples } ? "⚠︎ " : ""
        if s.onBattery {
            let w = monitor.averageWatts(minutes: 3) ?? s.watts
            button.title = String(format: "%@%.1fW", warn, w)
        } else {
            button.title = "\(warn)\(s.isCharging ? "⚡︎" : "🔌")\(s.percent)%"
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            monitor.refreshBlockers()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
