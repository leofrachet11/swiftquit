//
//  AppDelegate.swift
//  Swift Quit
//
//  Created by Johnny Baird on 5/25/22.
//

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var statusItem: NSStatusItem?
    private var pauseItem: NSMenuItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateVersionOneSettings()
        NSApp.mainMenu = makeMainMenu()
        WindowWatcher.start()
        LeftoverHelpers.start()

        if Settings.menuBarIconVisible {
            setStatusItemVisible(true)
        }

        // Starting at login stays out of the way, while opening the app by hand shows its settings.
        let launchedAtLogin = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem

        if !launchedAtLogin || !Settings.accessibilityRequested {
            openSettings()
        }

        guard !Settings.accessibilityRequested else { return }

        Settings.accessibilityRequested = true
        requestAccessibility()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard settingsWindow?.isVisible != true else { return }

        openSettings()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows visibleWindows: Bool) -> Bool {
        if !visibleWindows {
            openSettings()
        }

        return true
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let hostingController = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Swift Quit"
            window.styleMask = [.titled, .closable]
            window.delegate = self

            // SwiftUI sizes the window after it appears, so centring the empty window would pin its
            // top-left corner to the middle of the screen.
            window.setContentSize(hostingController.view.fittingSize)
            window.center()
            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Dropping the window hands SwiftUI's memory back, and hiding returns focus to the
    // previous app instead of leaving a windowless Swift Quit in front.
    func windowWillClose(_ notification: Notification) {
        settingsWindow = nil
        NSApp.hide(nil)
    }

    // kAXTrustedCheckOptionPrompt is a mutable C global that Swift 6 refuses to read; this is its value.
    func requestAccessibility() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func setStatusItemVisible(_ visible: Bool) {
        guard visible else {
            statusItem?.isVisible = false
            return
        }

        if let statusItem {
            statusItem.isVisible = true
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(named: "MenuIcon")
        item.button?.appearsDisabled = Settings.paused

        let pause = NSMenuItem(title: "Pause Swift Quit", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.state = Settings.paused ? .on : .off
        pauseItem = pause

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self

        let menu = NSMenu()
        menu.addItem(pause)
        menu.addItem(.separator())
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Quit Swift Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        statusItem = item
    }

    @objc private func togglePause() {
        Settings.paused.toggle()
        pauseItem?.state = Settings.paused ? .on : .off
        statusItem?.button?.appearsDisabled = Settings.paused
    }

    // Never shown for a menu bar app, but its key equivalents are what make Cmd+Q, Cmd+W and
    // copy and paste work while the settings window is focused.
    private func makeMainMenu() -> NSMenu {
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "Quit Swift Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let mainMenu = NSMenu()

        for submenu in [applicationMenu, editMenu, windowMenu] {
            mainMenu.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
        }

        return mainMenu
    }
}
