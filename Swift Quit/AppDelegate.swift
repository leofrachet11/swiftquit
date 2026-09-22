//
//  AppDelegate.swift
//  Swift Quit
//
//  Created by Johnny Baird on 5/25/22.
//

import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var pauseItem: NSMenuItem?
    private lazy var settingsWindowController = NSStoryboard(name: "Main", bundle: nil).instantiateController(withIdentifier: "settings") as! NSWindowController

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateVersionOneSettings()
        WindowWatcher.start()

        if Settings.menuBarIconVisible {
            showStatusItem()
        }

        if !Settings.launchHidden {
            openSettings()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard settingsWindowController.window?.isVisible != true else { return }

        openSettings()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows visibleWindows: Bool) -> Bool {
        if !visibleWindows {
            openSettings()
        }

        return true
    }

    func applicationSupportsSecureRestorableState(_ application: NSApplication) -> Bool {
        return true
    }

    @objc func openSettings() {
        settingsWindowController.showWindow(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showStatusItem() {
        guard statusItem == nil else {
            statusItem?.isVisible = true
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(named: "MenuIcon")
        item.button?.image?.size = NSSize(width: 18, height: 18)
        item.button?.image?.isTemplate = true

        let pause = NSMenuItem(title: "Pause Swift Quit", action: #selector(togglePause), keyEquivalent: "")
        pause.state = Settings.paused ? .on : .off
        pause.target = self
        pauseItem = pause

        let settings = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self

        let menu = NSMenu()
        menu.addItem(pause)
        menu.addItem(.separator())
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Quit Swift Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        statusItem = item
    }

    func hideStatusItem() {
        statusItem?.isVisible = false
    }

    @objc private func togglePause() {
        Settings.paused.toggle()
        pauseItem?.state = Settings.paused ? .on : .off
    }
}

var appDelegate: AppDelegate {
    return NSApp.delegate as! AppDelegate
}
