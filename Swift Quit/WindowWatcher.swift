//
//  WindowWatcher.swift
//  Swift Quit
//

import AppKit
import os

let activePollInterval = 0.1
let idlePollInterval = 1.0
let userIdleThreshold = 3.0
let accessibilityTimeout: Float = 1
let countedWindowLayers = 0 ... 8

let neverQuitBundleIdentifiers: Set<String> = ["com.apple.finder"]

private let anyInputEventType = CGEventType(rawValue: ~0)!
private let log = Logger(subsystem: "onebadidea.Swift-Quit", category: "windowWatcher")

/*
 An app counts as having windows while any of its windows is ordered in on any Space, which is
 what NSWindow.windowNumbers(options: [.allApplications, .allSpaces]) returns. That list survives
 Space switches and covered windows, and it leaves out the per-Space menu bar surfaces and the
 parked windows every app keeps but never shows. The Accessibility API only sees the current Space.

 Minimising, hiding, a full-screen transition and closing a window the app keeps in memory
 (Notes, Calendar, Activity Monitor) all order a window out, and the WindowServer describes them
 identically. So when an app runs out of ordered-in windows, it is only a candidate. After the
 close delay, Accessibility settles it: it lists minimised and transitioning windows but not ones
 the app hid on close. Without Accessibility access, any window that was once ordered in and
 still exists keeps the app open, because quitting on a minimise would be far worse.
 */
@MainActor
enum WindowWatcher {

    private static var windowOwners = [CGWindowID: pid_t]()
    private static var ignoredWindows = Set<CGWindowID>()
    private static var previouslyOrderedIn = Set<CGWindowID>()
    private static var applicationsWithWindows = Set<pid_t>()
    private static var pendingQuits = [pid_t: Task<Void, Error>]()
    private static var pollingTask: Task<Void, Error>?
    private static var sessionActive = true

    static func start() {
        guard pollingTask == nil else { return }

        let workspaceCenter = NSWorkspace.shared.notificationCenter

        workspaceCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { sessionActive = false }
        }
        workspaceCenter.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { sessionActive = true }
        }

        pollingTask = Task {
            while true {
                poll()

                let idleSeconds = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInputEventType)
                let interval = idleSeconds > userIdleThreshold ? idlePollInterval : activePollInterval
                try await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval / 5))
            }
        }
    }

    private static func poll() {
        guard sessionActive else { return }

        let orderedIn = orderedInWindows()

        // Only an unavailable WindowServer returns nothing; reading that as "every window
        // closed" would quit every app at once.
        guard !orderedIn.isEmpty else { return }

        let occupied = owners(of: orderedIn)
        let emptied = applicationsWithWindows.subtracting(occupied)
        applicationsWithWindows = occupied

        for processIdentifier in occupied where pendingQuits[processIdentifier] != nil {
            pendingQuits.removeValue(forKey: processIdentifier)?.cancel()
        }

        let orderedInSet = Set(orderedIn)

        if orderedInSet != previouslyOrderedIn {
            forgetDestroyedWindows(orderedIn: orderedInSet)
            previouslyOrderedIn = orderedInSet
        }

        guard !Settings.paused else { return }

        emptied.forEach(scheduleQuit)
    }

    private static func owners(of identifiers: [CGWindowID]) -> Set<pid_t> {
        let unknown = identifiers.filter { windowOwners[$0] == nil && !ignoredWindows.contains($0) }

        for window in describe(unknown) {
            guard let identifier = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }

            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value

            if let owner, countedWindowLayers.contains(layer) {
                windowOwners[identifier] = owner
            }
            else {
                ignoredWindows.insert(identifier)
            }
        }

        return Set(identifiers.compactMap { windowOwners[$0] })
    }

    // Ordered-out windows stay known until they are destroyed, since without Accessibility they
    // are the only evidence of a minimised window.
    private static func forgetDestroyedWindows(orderedIn: Set<CGWindowID>) {
        ignoredWindows.formIntersection(orderedIn)

        let orderedOut = windowOwners.keys.filter { !orderedIn.contains($0) }
        let surviving = Set(describe(orderedOut).compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })

        for identifier in orderedOut where !surviving.contains(identifier) {
            windowOwners[identifier] = nil
        }
    }

    private static func scheduleQuit(of processIdentifier: pid_t) {
        guard pendingQuits[processIdentifier] == nil,
              let application = NSRunningApplication(processIdentifier: processIdentifier),
              shouldQuit(application) else { return }

        // Cancelled by poll() if a window comes back, so the app has to stay windowless for the whole delay.
        pendingQuits[processIdentifier] = Task {
            try await Task.sleep(for: .seconds(Settings.closeDelay))

            pendingQuits[processIdentifier] = nil

            guard sessionActive, !Settings.paused, !application.isTerminated, !application.isHidden, !hasWindows(application) else { return }

            log.notice("Quitting \(application.localizedName ?? application.bundleIdentifier ?? "unnamed", privacy: .public)")
            application.terminate()
        }
    }

    private static func hasWindows(_ application: NSRunningApplication) -> Bool {
        let processIdentifier = application.processIdentifier
        let orderedIn = orderedInWindows()

        guard !orderedIn.isEmpty, !owners(of: orderedIn).contains(processIdentifier) else { return true }

        if AXIsProcessTrusted(), let count = accessibilityWindowCount(processIdentifier) {
            return count > 0
        }

        let known = windowOwners.filter { $0.value == processIdentifier }.map(\.key)

        return !describe(known).isEmpty
    }

    // Returns nil when the app doesn't answer, so a busy app falls back to the WindowServer rule
    // instead of being quit on a guess.
    private static func accessibilityWindowCount(_ processIdentifier: pid_t) -> Int? {
        let element = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(element, accessibilityTimeout)

        var windows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows)

        if result == .noValue {
            return 0
        }

        guard result == .success else { return nil }

        return (windows as? [AXUIElement])?.count ?? 0
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

    private static func orderedInWindows() -> [CGWindowID] {
        return (NSWindow.windowNumbers(options: [.allApplications, .allSpaces]) ?? []).map { CGWindowID($0.intValue) }
    }

    private static func describe(_ identifiers: [CGWindowID]) -> [[String: Any]] {
        guard !identifiers.isEmpty else { return [] }

        // The array has to hold raw window IDs, not CFNumbers.
        var values = identifiers.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        let array = CFArrayCreate(nil, &values, values.count, nil)

        return CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] ?? []
    }
}
