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

// Word opens an invisible window while it loads a document, InDesign parks one far off-screen and
// Steam keeps a 1-point one. A window has to be at least this opaque and this big, and on a display,
// to count.
let minimumWindowAlpha = 0.1
let minimumWindowSide = 40.0
// Windows can fade or move into view, so ones that didn't count are looked at again this often.
let hiddenWindowRecheckInterval = 1.0

// When an app empties itself (a splash screen handing over, a sign-in window closing), it gets at
// least this long to open its next window before it's quit.
let appClosedWindowGrace = 3.0
// A click or key press this long before the windows vanished means the user closed them.
let userCloseLeeway = 1.0

let neverQuitBundleIdentifiers: Set<String> = ["com.apple.finder"]

private let anyInputEventType = CGEventType(rawValue: ~0)!
private let clickEventTypes: [CGEventType] = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
private let log = Logger(subsystem: "onebadidea.Swift-Quit", category: "windowWatcher")

/*
 An app counts as having windows while any of its windows is ordered in on any Space, which is
 what NSWindow.windowNumbers(options: [.allApplications, .allSpaces]) returns. That list survives
 Space switches and covered windows, and it leaves out the per-Space menu bar surfaces and the
 parked windows every app keeps but never shows. The Accessibility API only sees the current Space.
 Windows too faint, too small or too far off-screen to see don't count either.

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
    private static var windowAppearances = [CGWindowID: Date]()
    // The helper process behind a window that counts for its app, like Steam's.
    private static var helperWindowOwners = [CGWindowID: pid_t]()
    private static var ignoredWindows = Set<CGWindowID>()
    private static var hiddenWindows = Set<CGWindowID>()
    private static var lastHiddenWindowCheck = Date.distantPast
    private static var previouslyOrderedIn = Set<CGWindowID>()
    private static var applicationsWithWindows = Set<pid_t>()
    private static var pendingQuits = [pid_t: Task<Void, Error>]()
    private static var pollingTask: Task<Void, Error>?
    private static var sessionActive = true
    private static var lastPollTime = Date()

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

        let pollTime = Date()
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

        let windowsLastSeen = lastPollTime
        lastPollTime = pollTime

        // Before destroyed windows are forgotten, since when they appeared tells who closed them.
        if !Settings.paused {
            for processIdentifier in emptied {
                scheduleQuit(of: processIdentifier, windowsLastSeen: windowsLastSeen)
            }
        }

        let orderedInSet = Set(orderedIn)

        if orderedInSet != previouslyOrderedIn {
            forgetDestroyedWindows(orderedIn: orderedInSet)
            previouslyOrderedIn = orderedInSet
        }
    }

    private static func owners(of identifiers: [CGWindowID]) -> Set<pid_t> {
        let recheckHidden = Date().timeIntervalSince(lastHiddenWindowCheck) >= hiddenWindowRecheckInterval
        let unknown = identifiers.filter { windowOwners[$0] == nil && !ignoredWindows.contains($0) && (recheckHidden || !hiddenWindows.contains($0)) }

        if !unknown.isEmpty {
            let displays = onlineDisplayBounds()

            if recheckHidden {
                lastHiddenWindowCheck = Date()
            }

            for window in describe(unknown) {
                guard let identifier = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }

                let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1

                guard let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, countedWindowLayers.contains(layer) else {
                    ignoredWindows.insert(identifier)
                    continue
                }

                if isVisible(window, on: displays) {
                    let countedOwner = application(drawingFrom: owner)

                    windowOwners[identifier] = countedOwner
                    windowAppearances[identifier] = Date()
                    helperWindowOwners[identifier] = countedOwner == owner ? nil : owner
                    hiddenWindows.remove(identifier)
                }
                else {
                    hiddenWindows.insert(identifier)
                }
            }
        }

        return Set(identifiers.compactMap { windowOwners[$0] })
    }

    // Steam draws its window from a helper app inside its bundle, so Steam itself never owns one. A
    // window like that counts for the app the helper works for.
    private static func application(drawingFrom owner: pid_t) -> pid_t {
        guard let helper = NSRunningApplication(processIdentifier: owner), helper.activationPolicy != .regular,
              let responsible = responsibleProcess?(owner), responsible != owner,
              let application = NSRunningApplication(processIdentifier: responsible), application.activationPolicy == .regular,
              let helperPath = helper.bundleURL?.standardizedFileURL.path,
              let applicationPath = application.bundleURL?.standardizedFileURL.path,
              helperPath.hasPrefix(applicationPath + "/") else { return owner }

        return responsible
    }

    private static func isVisible(_ window: [String: Any], on displays: [CGRect]) -> Bool {
        let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1

        guard alpha >= minimumWindowAlpha,
              let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else { return false }

        return bounds.width >= minimumWindowSide && bounds.height >= minimumWindowSide && displays.contains { $0.intersects(bounds) }
    }

    // Online rather than active displays, so a sleeping display doesn't make every window look off-screen.
    private static func onlineDisplayBounds() -> [CGRect] {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count)

        return displays.prefix(Int(count)).map(CGDisplayBounds)
    }

    // Ordered-out windows stay known until they are destroyed, since without Accessibility they
    // are the only evidence of a minimised window.
    private static func forgetDestroyedWindows(orderedIn: Set<CGWindowID>) {
        ignoredWindows.formIntersection(orderedIn)
        hiddenWindows.formIntersection(orderedIn)

        let orderedOut = windowOwners.keys.filter { !orderedIn.contains($0) }
        let surviving = Set(describe(orderedOut).compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })

        for identifier in orderedOut where !surviving.contains(identifier) {
            windowOwners[identifier] = nil
            windowAppearances[identifier] = nil
            helperWindowOwners[identifier] = nil
        }
    }

    private static func scheduleQuit(of processIdentifier: pid_t, windowsLastSeen: Date) {
        guard pendingQuits[processIdentifier] == nil,
              let application = NSRunningApplication(processIdentifier: processIdentifier),
              shouldQuit(application) else { return }

        let closeDelay = Double(Settings.closeDelay)
        let delay = closedByUser(processIdentifier, windowsLastSeen: windowsLastSeen) ? closeDelay : max(closeDelay, appClosedWindowGrace)

        // Cancelled by poll() if a window comes back, so the app has to stay windowless for the whole delay.
        pendingQuits[processIdentifier] = Task {
            try await Task.sleep(for: .seconds(delay))

            pendingQuits[processIdentifier] = nil

            // The list, or the app's own Dock presence, can change during the delay.
            guard sessionActive, !Settings.paused, !application.isTerminated, !application.isHidden, shouldQuit(application), !hasWindows(processIdentifier) else { return }

            let name = application.localizedName ?? application.bundleIdentifier ?? "unnamed"

            if let reason = KeepRunning.reason(for: application, processIdentifier: processIdentifier) {
                log.notice("Keeping \(name, privacy: .public) running because \(reason, privacy: .public)")
                return
            }

            log.notice("Quitting \(name, privacy: .public)")

            application.terminate()
        }
    }

    // A close the user made follows a click, or a key press in that app (a background window's red
    // button works without switching to it), after the window appeared and just before it went.
    // Splash screens and sign-in windows hand over to the next window on their own, sometimes with a
    // gap, and the click that opened the app came before its first window did. macOS reports how
    // long ago the last click and key press were without any permission.
    private static func closedByUser(_ processIdentifier: pid_t, windowsLastSeen: Date) -> Bool {
        var lastWindowAppeared = Date.distantPast

        for (window, owner) in windowOwners where owner == processIdentifier {
            lastWindowAppeared = max(lastWindowAppeared, windowAppearances[window] ?? .distantPast)
        }

        let clickAge = clickEventTypes.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
        let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
        let keyAge = isFrontmost ? CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown) : .infinity
        let inputAge = min(clickAge, keyAge)

        return inputAge <= Date().timeIntervalSince(windowsLastSeen) + userCloseLeeway && inputAge < Date().timeIntervalSince(lastWindowAppeared)
    }

    // Takes the window owner's process id, since Steam's NSRunningApplication reports -1 as its own.
    private static func hasWindows(_ processIdentifier: pid_t) -> Bool {
        let orderedIn = orderedInWindows()

        guard !orderedIn.isEmpty, !owners(of: orderedIn).contains(processIdentifier) else { return true }

        let known = windowOwners.filter { $0.value == processIdentifier }.map(\.key)
        // Accessibility only lists a helper's windows when asked about the helper.
        let drawingProcesses = Set([processIdentifier] + known.compactMap { helperWindowOwners[$0] })
        let accessibilityCounts = AXIsProcessTrusted() ? drawingProcesses.map(accessibilityWindowCount) : []

        if !accessibilityCounts.isEmpty, !accessibilityCounts.contains(nil) {
            return accessibilityCounts.contains { $0! > 0 }
        }

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

        let displays = onlineDisplayBounds()

        return (windows as? [AXUIElement])?.filter { couldBeSeen($0, on: displays) }.count ?? 0
    }

    // The same size and position rule as the WindowServer check, since Accessibility also lists
    // Steam's 1-point window and InDesign's off-screen one. A frame that can't be read counts.
    private static func couldBeSeen(_ window: AXUIElement, on displays: [CGRect]) -> Bool {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        var position = CGPoint.zero
        var size = CGSize.zero

        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return true }

        let frame = CGRect(origin: position, size: size)

        return size.width >= minimumWindowSide && size.height >= minimumWindowSide && displays.contains { $0.intersects(frame) }
    }

    // Whether the process itself draws any window Swift Quit counts, minimised ones included.
    static func showsWindows(_ processIdentifier: pid_t) -> Bool {
        return windowOwners.contains { (helperWindowOwners[$0.key] ?? $0.value) == processIdentifier }
    }

    private static func shouldQuit(_ application: NSRunningApplication) -> Bool {
        return application.activationPolicy == .regular && application.isFinishedLaunching && manages(application)
    }

    // Whether the app is one Swift Quit looks after at all, going by who it is and the user's list.
    static func manages(_ application: NSRunningApplication) -> Bool {
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
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
