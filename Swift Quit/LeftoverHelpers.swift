//
//  LeftoverHelpers.swift
//  Swift Quit
//

import AppKit
import os

// How long a quit app's helpers get to exit on their own before Swift Quit stops them, and how many
// times it looks again for ones that were still working.
let helperExitGrace = 5.0
let helperChecks = 12
// A helper using more than this share of a CPU core is still working, like an updater installing.
let workingHelperCPUShare = 0.02

private let log = Logger(subsystem: "onebadidea.Swift-Quit", category: "leftoverHelpers")

// PROC_PIDCOALITIONINFO and its struct aren't in the SDK. The second id is the jetsam coalition,
// the one LaunchServices groups an app's processes by.
private let coalitionInfoFlavor: Int32 = 20
private struct CoalitionInfo {
    var resourceIdentifier: UInt64 = 0
    var jetsamIdentifier: UInt64 = 0
    var reserved = (UInt64(0), UInt64(0), UInt64(0))
}

// LaunchServices remembers which app launched which, even after the launcher has quit. The functions
// that read it are private, so they're looked up at runtime. The -2s are RTLD_DEFAULT and the current
// login session.
private typealias CopyRunningApplications = @convention(c) (Int32) -> Unmanaged<CFArray>?
private typealias CopyApplicationInformation = @convention(c) (Int32, CFTypeRef, CFArray?) -> Unmanaged<CFDictionary>?
private let copyRunningApplications = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_LSCopyRunningApplicationArray").map { unsafeBitCast($0, to: CopyRunningApplications.self) }
private let copyApplicationInformation = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_LSCopyApplicationInformation").map { unsafeBitCast($0, to: CopyApplicationInformation.self) }
private let currentSession: Int32 = -2

// The kernel counts CPU time in Mach ticks, which aren't nanoseconds on Apple silicon.
private let secondsPerMachTick: Double = {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
}()

// A quit app, and the coalitions its leftovers can be in.
private struct QuitInstance {
    let processIdentifier: pid_t
    let startDate: Date
    var coalitions: Set<UInt64>
}

/*
 macOS shows a quit app as "Running in Background" while any process in its coalition (the helpers
 it started itself) or any background-only app it launched is still running, and the Dock's "Stop
 Running in Background" sends those processes the terminate signal. Photoshop leaves Adobe's IPC
 broker and Creative Cloud's content manager behind like this, however it's quit. So once an app
 Swift Quit looks after has quit and its helpers have had a moment to exit, Swift Quit does what that
 menu item does, but only to helpers signed by the app's own developer that started after the app,
 have no windows or menu bar icon, and are idle rather than playing audio, keeping the Mac awake or
 working. The apps built into macOS carry no developer team, so they're left alone, and so are
 programs started from a terminal, which the terminal's developer didn't sign.
 */
@MainActor
enum LeftoverHelpers {

    // Read while each app runs, since neither can be looked up once the app has gone.
    private static var coalitions = [pid_t: UInt64]()
    private static var startDates = [pid_t: Date]()
    // Quit apps whose helpers were left because the app was opened again, retried at its next quit.
    private static var reopenedInstances = [String: [QuitInstance]]()

    static func start() {
        for application in NSWorkspace.shared.runningApplications {
            remember(application)
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter

        workspaceCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }

            MainActor.assumeIsolated { remember(application) }
        }
        workspaceCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }

            MainActor.assumeIsolated { stopHelpers(of: application) }
        }
    }

    private static func remember(_ application: NSRunningApplication) {
        let processIdentifier = application.processIdentifier

        coalitions[processIdentifier] = coalition(of: processIdentifier)
        startDates[processIdentifier] = startDate(of: processIdentifier)
    }

    private static func stopHelpers(of application: NSRunningApplication) {
        let processIdentifier = application.processIdentifier
        let appCoalition = coalitions.removeValue(forKey: processIdentifier)
        let appStartDate = startDates.removeValue(forKey: processIdentifier)

        guard let appCoalition, let appStartDate,
              !Settings.paused,
              application.activationPolicy == .regular,
              WindowWatcher.manages(application),
              !KeepRunning.declaresBackgroundApp(application),
              let bundleIdentifier = application.bundleIdentifier,
              let team = application.bundleURL.flatMap(teamIdentifier(ofBundleAt:)) else { return }

        let name = application.localizedName ?? bundleIdentifier
        let quitInstances = [QuitInstance(processIdentifier: processIdentifier, startDate: appStartDate, coalitions: [appCoalition])] + (reopenedInstances.removeValue(forKey: bundleIdentifier) ?? [])

        _ = Task {
            var instances = quitInstances
            var teams = [pid_t: String]()
            var stopped = Set<pid_t>()

            // The app's helpers are still exiting now, so this first look only reads how much CPU its
            // coalition has used, which takes a fraction of a millisecond.
            var previousCPUTimes = Dictionary(uniqueKeysWithValues: instances.flatMap(coalitionMembers).map { ($0, cpuTime(of: $0)) })

            for _ in 0 ..< helperChecks {
                try await Task.sleep(for: .seconds(helperExitGrace))

                guard !Settings.paused else { return }

                // Opening the app again can put its helpers back to work, so they wait for its next quit.
                guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty else {
                    reopenedInstances[bundleIdentifier, default: []] += instances
                    return
                }

                var helpers = Set<pid_t>()

                for index in instances.indices {
                    let launched = launchedBackgroundApps(of: instances[index].processIdentifier)

                    // A launched helper's record goes when it quits, but helpers it started itself stay
                    // in its coalition and keep the app in the Dock.
                    instances[index].coalitions.formUnion(launched.compactMap(coalition(of:)))
                    helpers.formUnion(leftovers(of: instances[index], launched: launched, team: team, teams: &teams))
                }

                helpers.subtract(stopped)

                guard !helpers.isEmpty else { return }

                let cpuTimes = Dictionary(uniqueKeysWithValues: helpers.map { ($0, cpuTime(of: $0)) })

                // A helper seen for the first time has no earlier reading, so it counts as working.
                let idle = helpers.allSatisfy { helper in
                    guard let previousCPUTime = previousCPUTimes[helper] else { return false }

                    return (cpuTimes[helper]! - previousCPUTime) / helperExitGrace < workingHelperCPUShare && !KeepRunning.isBusy(helper)
                }

                // All at once, like the Dock, since Creative Cloud restarts its IPC broker when that
                // goes first. While any of them works, the app really is running in the background.
                if idle {
                    for helper in helpers {
                        log.notice("Stopping \(processName(helper), privacy: .public), which \(name, privacy: .public) left running")
                        kill(helper, SIGTERM)
                    }

                    stopped.formUnion(helpers)
                }

                previousCPUTimes = cpuTimes
            }
        }
    }

    // The processes in the instance's coalitions that started after it. A system extension the app
    // borrowed can sit in its coalition too, but it started first.
    private static func coalitionMembers(of instance: QuitInstance) -> [pid_t] {
        return allProcesses().filter { member in
            member != instance.processIdentifier
                && coalition(of: member).map(instance.coalitions.contains) ?? false
                && startDate(of: member).map { $0 >= instance.startDate } ?? false
        }
    }

    // What macOS still counts as the app: the processes in its coalition, and the background-only apps
    // it launched along with their own coalitions. Reading a signature takes most of a millisecond,
    // so each helper's developer is looked up once and only after the cheaper checks pass.
    private static func leftovers(of instance: QuitInstance, launched: [pid_t], team: String, teams: inout [pid_t: String]) -> Set<pid_t> {
        let candidates = coalitionMembers(of: instance) + launched.filter { startDate(of: $0).map { $0 >= instance.startDate } ?? false }

        // kill() with -1 would signal every process, so only real process ids get through.
        return Set(candidates.filter { helper in
            guard helper > 0,
                  NSRunningApplication(processIdentifier: helper)?.activationPolicy != .regular,
                  !WindowWatcher.showsWindows(helper) else { return false }

            if teams[helper] == nil {
                teams[helper] = teamIdentifier(of: helper) ?? ""
            }

            return teams[helper] == team && !KeepRunning.hasMenuBarItems(helper)
        })
    }

    private static func launchedBackgroundApps(of processIdentifier: pid_t) -> [pid_t] {
        guard let copyRunningApplications, let copyApplicationInformation,
              let applications = copyRunningApplications(currentSession)?.takeRetainedValue() as? [CFTypeRef] else { return [] }

        return applications.compactMap { application in
            guard let information = copyApplicationInformation(currentSession, application, nil)?.takeRetainedValue() as? [String: Any],
                  information["ApplicationType"] as? String == "BackgroundOnly",
                  let parent = information["LSParentASN"],
                  let parentInformation = copyApplicationInformation(currentSession, parent as CFTypeRef, nil)?.takeRetainedValue() as? [String: Any],
                  parentInformation["pid"] as? pid_t == processIdentifier,
                  let helper = information["pid"] as? pid_t, helper > 0 else { return nil }

            return helper
        }
    }

    private static func allProcesses() -> [pid_t] {
        var processIdentifiers = [pid_t](repeating: 0, count: 8192)
        let count = proc_listallpids(&processIdentifiers, Int32(processIdentifiers.count * MemoryLayout<pid_t>.size))

        return processIdentifiers.prefix(Int(max(count, 0))).filter { $0 > 0 }
    }

    // Processes the kernel won't describe, like root's, come back without an id rather than as 0.
    private static func coalition(of processIdentifier: pid_t) -> UInt64? {
        var info = CoalitionInfo()

        guard proc_pidinfo(processIdentifier, coalitionInfoFlavor, 0, &info, Int32(MemoryLayout<CoalitionInfo>.size)) > 0, info.jetsamIdentifier != 0 else { return nil }

        return info.jetsamIdentifier
    }

    private static func startDate(of processIdentifier: pid_t) -> Date? {
        var info = proc_bsdinfo()

        guard proc_pidinfo(processIdentifier, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }

        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    private static func cpuTime(of processIdentifier: pid_t) -> Double {
        var info = proc_taskinfo()

        guard proc_pidinfo(processIdentifier, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 else { return 0 }

        return Double(info.pti_total_user + info.pti_total_system) * secondsPerMachTick
    }

    private static func processName(_ processIdentifier: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)

        guard proc_pidpath(processIdentifier, &buffer, UInt32(buffer.count)) > 0 else { return "a helper" }

        return URL(fileURLWithFileSystemRepresentation: buffer, isDirectory: false, relativeTo: nil).lastPathComponent
    }

    private static func teamIdentifier(of processIdentifier: pid_t) -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?

        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: processIdentifier] as CFDictionary, [], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }

        return teamIdentifier(of: staticCode)
    }

    private static func teamIdentifier(ofBundleAt url: URL) -> String? {
        var staticCode: SecStaticCode?

        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return nil }

        return teamIdentifier(of: staticCode)
    }

    private static func teamIdentifier(of code: SecStaticCode) -> String? {
        var information: CFDictionary?

        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess else { return nil }

        return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
