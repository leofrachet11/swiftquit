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

// LaunchServices keeps a record of what a quit app left running, which is what the Dock reads. The
// functions that read it are private, so they're looked up at runtime. The -2s are RTLD_DEFAULT and
// the current login session.
private typealias CreateApplicationSerialNumber = @convention(c) (CFAllocator?, pid_t) -> Unmanaged<CFTypeRef>?
private typealias CopyApplicationInformation = @convention(c) (Int32, CFTypeRef, CFArray?) -> Unmanaged<CFDictionary>?
private let createApplicationSerialNumber = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_LSASNCreateWithPid").map { unsafeBitCast($0, to: CreateApplicationSerialNumber.self) }
private let copyApplicationInformation = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_LSCopyApplicationInformation").map { unsafeBitCast($0, to: CopyApplicationInformation.self) }
private let currentSession: Int32 = -2

private let coalitionProcessesKey = "LSApplicationCoalitionPIDsKey"
private let launchedApplicationsKey = "LSApplicationChildApplicationASNsArrayKey"
private let inheritedApplicationsKey = "LSApplicationRelatedApplicationASNsArrayKey"
private let inheritedCoalitionsKey = "LSApplicationRelatedCoalitionsIDsArrayKey"
private let recordKeys = [coalitionProcessesKey, launchedApplicationsKey, inheritedApplicationsKey, inheritedCoalitionsKey, "LSLaunchTime", "ApplicationType", "pid"]

// The kernel counts CPU time in Mach ticks, which aren't nanoseconds on Apple silicon.
private let secondsPerMachTick: Double = {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
}()

/*
 macOS shows a quit app as "Running in Background" while processes are left in its coalition (the
 helpers it started itself) or background-only apps it launched are still running, and the Dock's
 "Stop Running in Background" sends those the terminate signal. Photoshop leaves Adobe's IPC broker
 and Creative Cloud's content manager behind like this, however it's quit. Reopening an app hands
 its predecessor's leftovers to the new copy. So once an app Swift Quit looks after has quit and its
 helpers have had a moment to exit, Swift Quit reads LaunchServices' list of what's left and does
 what that menu item does. It only stops helpers signed by the app's own developer that have no
 windows or menu bar icon, and only once all of them are idle rather than playing audio, keeping
 the Mac awake or working. The apps built into macOS carry no developer team, so they're left
 alone, and so are programs started from a terminal, which the terminal's developer didn't sign.
 */
@MainActor
enum LeftoverHelpers {

    static func start() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }

            MainActor.assumeIsolated { stopHelpers(of: application) }
        }
    }

    private static func stopHelpers(of application: NSRunningApplication) {
        let processIdentifier = application.processIdentifier

        guard processIdentifier > 0,
              !Settings.paused,
              application.activationPolicy == .regular,
              WindowWatcher.manages(application),
              !KeepRunning.declaresBackgroundApp(application),
              let bundleIdentifier = application.bundleIdentifier,
              let team = application.bundleURL.flatMap(teamIdentifier(ofBundleAt:)) else { return }

        let name = application.localizedName ?? bundleIdentifier

        _ = Task {
            var teams = [pid_t: String]()
            var stopped = Set<pid_t>()

            // The app's helpers are still exiting now, so this first look only reads their CPU time.
            var previousCPUTimes = Dictionary(uniqueKeysWithValues: Set(leftovers(of: processIdentifier)).map { ($0, cpuTime(of: $0)) })

            for _ in 0 ..< helperChecks {
                try await Task.sleep(for: .seconds(helperExitGrace))

                // An app opened again takes over what the last copy left, until it quits too.
                guard !Settings.paused, NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty else { return }

                let helpers = Set(leftovers(of: processIdentifier).filter { isStoppable($0, team: team, teams: &teams) }).subtracting(stopped)

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

    // What LaunchServices is waiting on before the app can leave the Dock: processes left in its
    // coalition, background-only apps it launched or inherited, and the processes those started. A
    // system extension the app borrowed can sit in its coalition too, but it started before the app.
    private static func leftovers(of processIdentifier: pid_t) -> [pid_t] {
        guard let record = record(of: processIdentifier) else { return [] }

        let launchTime = record["LSLaunchTime"] as? Date ?? .distantFuture
        var leftovers = (record[coalitionProcessesKey] as? [pid_t] ?? []).filter { startDate(of: $0).map { $0 >= launchTime } ?? false }

        for applicationSerialNumber in (record[launchedApplicationsKey] as? [CFTypeRef] ?? []) + (record[inheritedApplicationsKey] as? [CFTypeRef] ?? []) {
            guard let launched = copyApplicationInformation?(currentSession, applicationSerialNumber, recordKeys as CFArray)?.takeRetainedValue() as? [String: Any],
                  launched["ApplicationType"] as? String == "BackgroundOnly" else { continue }

            leftovers += [launched["pid"] as? pid_t ?? 0] + (launched[coalitionProcessesKey] as? [pid_t] ?? [])
        }

        let inheritedCoalitions = Set(record[inheritedCoalitionsKey] as? [UInt64] ?? [])

        if !inheritedCoalitions.isEmpty {
            leftovers += allProcesses().filter { coalition(of: $0).map(inheritedCoalitions.contains) ?? false }
        }

        // kill() with -1 would signal every process, so only real process ids get through.
        return leftovers.filter { $0 > 0 && $0 != processIdentifier }
    }

    // Reading a signature takes most of a millisecond, so each helper's developer is looked up once.
    private static func isStoppable(_ helper: pid_t, team: String, teams: inout [pid_t: String]) -> Bool {
        guard NSRunningApplication(processIdentifier: helper)?.activationPolicy != .regular,
              !WindowWatcher.showsWindows(helper) else { return false }

        if teams[helper] == nil {
            teams[helper] = teamIdentifier(of: helper) ?? ""
        }

        return teams[helper] == team && !KeepRunning.hasMenuBarItems(helper)
    }

    // LaunchServices keeps a quit app's record only while the Dock shows it running in the background.
    private static func record(of processIdentifier: pid_t) -> [String: Any]? {
        guard let createApplicationSerialNumber, let copyApplicationInformation,
              let applicationSerialNumber = createApplicationSerialNumber(nil, processIdentifier)?.takeRetainedValue() else { return nil }

        return copyApplicationInformation(currentSession, applicationSerialNumber, recordKeys as CFArray)?.takeRetainedValue() as? [String: Any]
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
