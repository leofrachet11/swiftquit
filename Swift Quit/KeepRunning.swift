//
//  KeepRunning.swift
//  Swift Quit
//

import AppKit
import CoreAudio
import IOKit.pwr_mgt

// The assertion types apps pass to IOKit to hold off sleep. The two without "Prevent" are older
// names that Chrome still uses while it plays media.
let sleepPreventingAssertionTypes: Set<String> = ["PreventUserIdleSystemSleep", "PreventSystemSleep", "PreventUserIdleDisplaySleep", "NoIdleSleepAssertion", "NoDisplaySleepAssertion"]

typealias ResponsibleProcessFunction = @convention(c) (pid_t) -> pid_t

// macOS records which app each helper works for, including WebKit's shared audio process, which
// isn't a child of the app. The function that reads it is private, so it's looked up at runtime.
// The -2 handle is RTLD_DEFAULT, a C macro Swift doesn't import.
let responsibleProcess = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid").map { unsafeBitCast($0, to: ResponsibleProcessFunction.self) }

/*
 Some apps are meant to carry on after their last window closes, like a VPN or a music player.
 These are the signs of one that macOS makes visible. They're only read for an app that is about
 to be quit, so none of them cost anything while Swift Quit polls.
 */
enum KeepRunning {

    // Returns why the app should stay open, or nil if it should be quit. Naming an app under
    // "Only these apps" overrides the guess that it's a background app, but not that it's busy. The
    // process id is passed separately because Steam's NSRunningApplication reports -1 as its own.
    static func reason(for application: NSRunningApplication, processIdentifier: pid_t) -> String? {
        if Settings.listMode == .quitAllExceptListed {
            if declaresBackgroundApp(application) {
                return "it's a background app shown in the Dock"
            }

            if hasMenuBarItems(processIdentifier) {
                return "it has a menu bar icon"
            }
        }

        if usesAudio(processIdentifier) {
            return "it's playing or recording audio"
        }

        if preventsSleep(processIdentifier) {
            return "it's keeping the Mac awake"
        }

        return nil
    }

    static func isBusy(_ processIdentifier: pid_t) -> Bool {
        return usesAudio(processIdentifier) || preventsSleep(processIdentifier)
    }

    // Apps like NordVPN ship as menu bar apps and only take a Dock icon when you ask for one.
    static func declaresBackgroundApp(_ application: NSRunningApplication) -> Bool {
        guard let bundleURL = application.bundleURL, let info = Bundle(url: bundleURL)?.infoDictionary else { return false }

        return ["LSUIElement", "LSBackgroundOnly"].contains { key in
            (info[key] as? NSNumber)?.boolValue ?? (info[key] as? NSString)?.boolValue ?? false
        }
    }

    // macOS 27 keeps menu bar icons out of the window list, so only Accessibility can see them.
    // Without it the call fails and this returns false.
    static func hasMenuBarItems(_ processIdentifier: pid_t) -> Bool {
        let element = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(element, accessibilityTimeout)

        var menuBar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXExtrasMenuBarAttribute as CFString, &menuBar) == .success, let menuBar else { return false }

        var count: CFIndex = 0
        AXUIElementGetAttributeValueCount(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &count)

        return count > 0
    }

    private static func usesAudio(_ processIdentifier: pid_t) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0

        // Process objects arrived in macOS 14.2. Earlier versions answer with an error.
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return false }

        var processObjects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)

        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &processObjects) == noErr else { return false }

        return processObjects.contains { processObject in
            audioProperty(kAudioProcessPropertyIsRunning, of: processObject) != 0
                && belongs(pid_t(bitPattern: audioProperty(kAudioProcessPropertyPID, of: processObject)), to: processIdentifier)
        }
    }

    private static func audioProperty(_ selector: AudioObjectPropertySelector, of processObject: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)

        AudioObjectGetPropertyData(processObject, &address, 0, nil, &size, &value)

        return value
    }

    private static func preventsSleep(_ processIdentifier: pid_t) -> Bool {
        var assertionsByProcess: Unmanaged<CFDictionary>?

        guard IOPMCopyAssertionsByProcess(&assertionsByProcess) == kIOReturnSuccess,
              let assertions = assertionsByProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }

        return assertions.contains { owner, ownedAssertions in
            belongs(owner.int32Value, to: processIdentifier)
                && ownedAssertions.contains { sleepPreventingAssertionTypes.contains($0[kIOPMAssertionTypeKey] as? String ?? "") }
        }
    }

    // Browsers, Electron apps and web views play audio and hold assertions from helper processes.
    private static func belongs(_ candidate: pid_t, to processIdentifier: pid_t) -> Bool {
        guard candidate != processIdentifier else { return true }

        if let responsibleProcess {
            return responsibleProcess(candidate) == processIdentifier
        }

        var info = proc_bsdinfo()

        guard proc_pidinfo(candidate, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return false }

        return pid_t(info.pbi_ppid) == processIdentifier
    }
}
