//
//  Settings.swift
//  Swift Quit
//

import AppKit
import ServiceManagement

let defaultCloseDelay = 2
let maximumCloseDelay = 3600

let closeDelayKey = "SwiftQuit.closeDelay"
let menuBarIconVisibleKey = "SwiftQuit.menuBarIconVisible"
let listModeKey = "SwiftQuit.listMode"
let listedApplicationsKey = "SwiftQuit.listedApplications"
let pausedKey = "SwiftQuit.paused"
let accessibilityRequestedKey = "SwiftQuit.accessibilityRequested"

private let migrationCompletedKey = "SwiftQuit.migratedFromVersion1"
private let legacySettingsKey = "SwiftQuitSettings"
private let legacyApplicationsKey = "SwiftQuitExcludedApps"

enum ListMode: String {
    case quitAllExceptListed
    case quitOnlyListed
}

struct ListedApplication: Identifiable, Equatable {
    let bundleIdentifier: String
    let name: String
    let path: String

    var id: String { bundleIdentifier }

    init?(path: String) {
        guard let bundle = Bundle(path: path), let bundleIdentifier = bundle.bundleIdentifier else { return nil }

        self.bundleIdentifier = bundleIdentifier
        self.name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? FileManager.default.displayName(atPath: path)
        self.path = path
    }

    init?(stored: [String: String]) {
        guard let bundleIdentifier = stored["bundleIdentifier"] else { return nil }

        self.bundleIdentifier = bundleIdentifier
        self.name = stored["name"] ?? bundleIdentifier
        self.path = stored["path"] ?? ""
    }

    var stored: [String: String] {
        return ["bundleIdentifier": bundleIdentifier, "name": name, "path": path]
    }
}

enum Settings {

    static var closeDelay: Int {
        get { return UserDefaults.standard.object(forKey: closeDelayKey) == nil ? defaultCloseDelay : min(max(UserDefaults.standard.integer(forKey: closeDelayKey), 0), maximumCloseDelay) }
        set { UserDefaults.standard.set(min(max(newValue, 0), maximumCloseDelay), forKey: closeDelayKey) }
    }

    static var menuBarIconVisible: Bool {
        get { return UserDefaults.standard.object(forKey: menuBarIconVisibleKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: menuBarIconVisibleKey) }
    }

    static var paused: Bool {
        get { return UserDefaults.standard.bool(forKey: pausedKey) }
        set { UserDefaults.standard.set(newValue, forKey: pausedKey) }
    }

    static var accessibilityRequested: Bool {
        get { return UserDefaults.standard.bool(forKey: accessibilityRequestedKey) }
        set { UserDefaults.standard.set(newValue, forKey: accessibilityRequestedKey) }
    }

    static var listMode: ListMode {
        get { return ListMode(rawValue: UserDefaults.standard.string(forKey: listModeKey) ?? "") ?? .quitAllExceptListed }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: listModeKey) }
    }

    static var listedApplications: [ListedApplication] {
        get { return (UserDefaults.standard.array(forKey: listedApplicationsKey) as? [[String: String]] ?? []).compactMap(ListedApplication.init(stored:)) }
        set { UserDefaults.standard.set(newValue.map(\.stored), forKey: listedApplicationsKey) }
    }

    static var launchAtLogin: Bool {
        return SMAppService.mainApp.status == .enabled
    }

    static func setLaunchAtLogin(_ enabled: Bool) throws {
        guard enabled != launchAtLogin else { return }

        if enabled {
            try SMAppService.mainApp.register()
        }
        else {
            try SMAppService.mainApp.unregister()
        }
    }
}

// Version 1 kept everything in one [String: String] dictionary and matched apps by absolute
// path, which broke whenever an app moved between /Applications and /System/Applications.
func migrateVersionOneSettings() {
    let defaults = UserDefaults.standard

    guard !defaults.bool(forKey: migrationCompletedKey) else { return }

    defaults.set(true, forKey: migrationCompletedKey)

    if let legacy = defaults.dictionary(forKey: legacySettingsKey) as? [String: String] {
        Settings.closeDelay = Int(legacy["closeDelay"] ?? "") ?? defaultCloseDelay
        Settings.menuBarIconVisible = legacy["menubarIconEnabled"] != "false"
        Settings.listMode = legacy["excludeBehaviour"] == "includeApps" ? .quitOnlyListed : .quitAllExceptListed
    }

    if let legacyPaths = defaults.array(forKey: legacyApplicationsKey) as? [String] {
        Settings.listedApplications = legacyPaths.compactMap(ListedApplication.init(path:))
    }

    defaults.removeObject(forKey: legacySettingsKey)
    defaults.removeObject(forKey: legacyApplicationsKey)
}
