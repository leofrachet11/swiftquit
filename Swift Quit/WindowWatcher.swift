//
//  WindowWatcher.swift
//  Swift Quit
//

import AppKit
import os

let activePollInterval = 0.15
let idlePollInterval = 1.0
let userIdleThreshold = 3.0

let neverQuitBundleIdentifiers: Set<String> = [
    "com.apple.finder",
    "com.apple.dock",
    "com.apple.Spotlight",
    "com.apple.controlcenter",
    "com.apple.notificationcenterui",
    "com.apple.systemuiserver",
    "com.apple.WindowManager",
    "com.apple.loginwindow"
]

private let windowListOptions: CGWindowListOption = [.optionAll, .excludeDesktopElements]
private let anyInputEventType = CGEventType(rawValue: ~0)!
private let log = Logger(subsystem: "onebadidea.Swift-Quit", category: "windowWatcher")

private let windowNumberKey = kCGWindowNumber as String
private let windowOwnerKey = kCGWindowOwnerPID as String
private let windowLayerKey = kCGWindowLayer as String
private let windowOnScreenKey = kCGWindowIsOnscreen as String

/*
 The WindowServer is the only window source that survives a Space switch. The Accessibility
 API reports zero windows for any app whose windows live on another Space, which is why every
 Accessibility-based build of Swift Quit quits apps as you swipe between desktops.

 CGWindowListCopyWindowInfo lists every window in the session, but that list also carries
 per-Space menu bar surfaces and parked windows an app never shows. A window earns the name
 "real" the first time the WindowServer reports it on screen, and keeps it until the window
 goes away, so minimised windows, occluded windows and windows on other Spaces all still
 count. An app is a candidate for quitting when its last real window disappears.
 */
enum WindowWatcher {

    private static let queue = DispatchQueue(label: "onebadidea.Swift-Quit.window-watcher", qos: .utility)
    private static var pollTimer: DispatchSourceTimer?
    private static var currentPollInterval = 0.0
    private static var realWindowIdentifiers = Set<CGWindowID>()
    private static var applicationsWithRealWindows = Set<pid_t>()
    private static var applicationsAwaitingQuit = Set<pid_t>()

    static func start() {
        queue.async {
            guard pollTimer == nil else { return }

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler(handler: poll)
            pollTimer = timer
            schedulePoll(every: activePollInterval)
            timer.resume()
        }
    }

    private static func schedulePoll(every interval: TimeInterval) {
        guard interval != currentPollInterval, let timer = pollTimer else { return }

        currentPollInterval = interval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 200)))
    }

    private static func poll() {
        let windows = CGWindowListCopyWindowInfo(windowListOptions, kCGNullWindowID) as? [[String: Any]] ?? []

        var ownerByWindow = [CGWindowID: pid_t](minimumCapacity: windows.count)

        for window in windows {
            guard (window[windowLayerKey] as? NSNumber)?.intValue == 0,
                  let identifier = (window[windowNumberKey] as? NSNumber)?.uint32Value,
                  let owner = (window[windowOwnerKey] as? NSNumber)?.int32Value else { continue }

            ownerByWindow[identifier] = owner

            if (window[windowOnScreenKey] as? NSNumber)?.boolValue == true {
                realWindowIdentifiers.insert(identifier)
            }
        }

        realWindowIdentifiers.formIntersection(ownerByWindow.keys)

        var occupied = Set<pid_t>(minimumCapacity: applicationsWithRealWindows.count)

        for identifier in realWindowIdentifiers {
            occupied.insert(ownerByWindow[identifier]!)
        }

        let emptied = applicationsWithRealWindows.subtracting(occupied)
        applicationsWithRealWindows = occupied

        if !Settings.paused {
            emptied.forEach(scheduleQuit)
        }

        let idleSeconds = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInputEventType)
        schedulePoll(every: idleSeconds > userIdleThreshold ? idlePollInterval : activePollInterval)
    }

    private static func scheduleQuit(of processIdentifier: pid_t) {
        guard !applicationsAwaitingQuit.contains(processIdentifier),
              let application = NSRunningApplication(processIdentifier: processIdentifier),
              shouldQuit(application) else { return }

        applicationsAwaitingQuit.insert(processIdentifier)

        queue.asyncAfter(deadline: .now() + .milliseconds(Settings.closeDelay * 1000)) {
            applicationsAwaitingQuit.remove(processIdentifier)

            guard !application.isTerminated, !Settings.paused, !hasRealWindow(processIdentifier) else { return }

            DispatchQueue.main.async { quit(application) }
        }
    }

    // Re-read the window list rather than trust the last poll, so a window reopened during the
    // close delay cancels the quit even when the delay is zero.
    private static func hasRealWindow(_ processIdentifier: pid_t) -> Bool {
        let windows = CGWindowListCopyWindowInfo(windowListOptions, kCGNullWindowID) as? [[String: Any]] ?? []

        for window in windows {
            guard (window[windowOwnerKey] as? NSNumber)?.int32Value == processIdentifier,
                  (window[windowLayerKey] as? NSNumber)?.intValue == 0,
                  let identifier = (window[windowNumberKey] as? NSNumber)?.uint32Value else { continue }

            if realWindowIdentifiers.contains(identifier) || (window[windowOnScreenKey] as? NSNumber)?.boolValue == true {
                return true
            }
        }

        return false
    }

    private static func shouldQuit(_ application: NSRunningApplication) -> Bool {
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              application.activationPolicy == .regular,
              application.isFinishedLaunching,
              let bundleIdentifier = application.bundleIdentifier,
              !neverQuitBundleIdentifiers.contains(bundleIdentifier) else { return false }

        let isListed = Settings.listedApplications.contains { $0.bundleIdentifier == bundleIdentifier }

        return Settings.listMode == .quitOnlyListed ? isListed : !isListed
    }

    private static func quit(_ application: NSRunningApplication) {
        log.notice("Quitting \(application.localizedName ?? application.bundleIdentifier ?? "unnamed", privacy: .public)")
        application.terminate()
    }
}
