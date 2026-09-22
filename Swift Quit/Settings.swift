//
//  Settings.swift
//  Swift Quit
//

import AppKit
import ServiceManagement

let defaultCloseDelay = 2
let maximumCloseDelay = 3600

private let closeDelayKey = "SwiftQuit.closeDelay"
private let menuBarIconVisibleKey = "SwiftQuit.menuBarIconVisible"
private let launchHiddenKey = "SwiftQuit.launchHidden"
private let listModeKey = "SwiftQuit.listMode"
private let listedApplicationsKey = "SwiftQuit.listedApplications"
private let pausedKey = "SwiftQuit.paused"
private let migrationCompletedKey = "SwiftQuit.migratedFromVersion1"

private let legacySettingsKey = "SwiftQuitSettings"
private let legacyApplicationsKey = "SwiftQuitExcludedApps"

private let defaults = UserDefaults.standard

enum ListMode: String {
    case quitAllExceptListed
    case quitOnlyListed
}

struct ListedApplication: Equatable {
    let bundleIdentifier: String
    let name: String
    let path: String

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
        get { return defaults.object(forKey: closeDelayKey) == nil ? defaultCloseDelay : min(max(defaults.integer(forKey: closeDelayKey), 0), maximumCloseDelay) }
        set { defaults.set(min(max(newValue, 0), maximumCloseDelay), forKey: closeDelayKey) }
    }

    static var menuBarIconVisible: Bool {
        get { return defaults.object(forKey: menuBarIconVisibleKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: menuBarIconVisibleKey) }
    }

    static var launchHidden: Bool {
        get { return defaults.object(forKey: launchHiddenKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: launchHiddenKey) }
    }

    static var paused: Bool {
        get { return defaults.bool(forKey: pausedKey) }
        set { defaults.set(newValue, forKey: pausedKey) }
    }

    static var listMode: ListMode {
        get { return ListMode(rawValue: defaults.string(forKey: listModeKey) ?? "") ?? .quitAllExceptListed }
        set { defaults.set(newValue.rawValue, forKey: listModeKey) }
    }

    static var listedApplications: [ListedApplication] {
        get { return (defaults.array(forKey: listedApplicationsKey) as? [[String: String]] ?? []).compactMap(ListedApplication.init(stored:)) }
        set { defaults.set(newValue.map(\.stored), forKey: listedApplicationsKey) }
    }

    static var launchAtLogin: Bool {
        return SMAppService.mainApp.status == .enabled
    }

    static func setLaunchAtLogin(_ enabled: Bool) throws {
        let service = SMAppService.mainApp

        guard enabled != (service.status == .enabled) else { return }

        if enabled {
            try service.register()
        }
        else {
            try service.unregister()
        }
    }
}

// Version 1 kept everything in one [String: String] dictionary and matched apps by absolute
// path, which broke whenever an app moved between /Applications and /System/Applications.
func migrateVersionOneSettings() {
    guard !defaults.bool(forKey: migrationCompletedKey) else { return }

    defaults.set(true, forKey: migrationCompletedKey)

    if let legacy = defaults.dictionary(forKey: legacySettingsKey) as? [String: String] {
        Settings.closeDelay = Int(legacy["closeDelay"] ?? "") ?? defaultCloseDelay
        Settings.menuBarIconVisible = legacy["menubarIconEnabled"] != "false"
        Settings.launchHidden = legacy["launchHidden"] != "false"
        Settings.listMode = legacy["excludeBehaviour"] == "includeApps" ? .quitOnlyListed : .quitAllExceptListed
    }

    if let legacyPaths = defaults.array(forKey: legacyApplicationsKey) as? [String] {
        Settings.listedApplications = legacyPaths.compactMap(ListedApplication.init(path:))
    }

    defaults.removeObject(forKey: legacySettingsKey)
    defaults.removeObject(forKey: legacyApplicationsKey)
}
