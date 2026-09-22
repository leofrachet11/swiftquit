//
//  ViewController.swift
//  Swift Quit
//
//  Created by Johnny Baird on 5/25/22.
//

import Cocoa
import UniformTypeIdentifiers

class ViewController: NSViewController, NSTableViewDelegate, NSTableViewDataSource {

    @IBOutlet weak var launchAtLoginSwitch: NSSwitch!
    @IBOutlet weak var launchHiddenSwitch: NSSwitch!
    @IBOutlet weak var menuBarIconSwitch: NSSwitch!
    @IBOutlet weak var listModePopUp: NSPopUpButton!
    @IBOutlet weak var listModeLabel: NSTextField!
    @IBOutlet weak var applicationTableView: NSTableView!
    @IBOutlet weak var removeApplicationButton: NSButton!
    @IBOutlet weak var closeDelayTextField: NSTextField!
    @IBOutlet weak var versionLabel: NSTextField!

    private var listedApplications = Settings.listedApplications

    override func viewDidLoad() {
        super.viewDidLoad()

        launchAtLoginSwitch.state = Settings.launchAtLogin ? .on : .off
        launchHiddenSwitch.state = Settings.launchHidden ? .on : .off
        menuBarIconSwitch.state = Settings.menuBarIconVisible ? .on : .off

        listModeLabel.textColor = .labelColor
        listModePopUp.selectItem(at: Settings.listMode == .quitOnlyListed ? 1 : 0)

        closeDelayTextField.stringValue = "\(Settings.closeDelay)"
        closeDelayTextField.toolTip = "How long to wait after the last window closes. 0 quits the app straight away."

        versionLabel.stringValue = "v \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")"

        applicationTableView.dataSource = self
        applicationTableView.delegate = self
        removeApplicationButton.isHidden = true
    }

    @IBAction func toggleLaunchAtLogin(_ sender: NSSwitch) {
        let enabled = sender.state == .on

        do {
            try Settings.setLaunchAtLogin(enabled)
        }
        catch {
            sender.state = enabled ? .off : .on
            presentAlert(title: "Could not change the login item", message: "macOS refused the request: \(error.localizedDescription)\n\nSwift Quit usually needs to live in your Applications folder before it can start at login.")
        }
    }

    @IBAction func toggleLaunchHidden(_ sender: NSSwitch) {
        Settings.launchHidden = sender.state == .on
    }

    @IBAction func toggleMenuBarIcon(_ sender: NSSwitch) {
        Settings.menuBarIconVisible = sender.state == .on

        guard Settings.menuBarIconVisible else {
            appDelegate.hideStatusItem()
            presentAlert(title: "Hidden from the menu bar", message: "Open Swift Quit again from your Applications folder to get back to these settings.")
            return
        }

        appDelegate.showStatusItem()
    }

    @IBAction func changeListMode(_ sender: NSPopUpButton) {
        Settings.listMode = sender.indexOfSelectedItem == 1 ? .quitOnlyListed : .quitAllExceptListed
    }

    @IBAction func changeCloseDelay(_ sender: NSTextField) {
        guard let delay = Int(sender.stringValue.trimmingCharacters(in: .whitespaces)), (0 ... maximumCloseDelay).contains(delay) else {
            sender.stringValue = "\(Settings.closeDelay)"
            return
        }

        Settings.closeDelay = delay
        sender.stringValue = "\(delay)"
    }

    @IBAction func addApplication(_ sender: Any) {
        let panel = NSOpenPanel()

        panel.title = "Choose Application"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        guard panel.runModal() == .OK else { return }

        let additions = panel.urls.compactMap { ListedApplication(path: $0.path) }.filter { addition in
            !listedApplications.contains { $0.bundleIdentifier == addition.bundleIdentifier }
        }

        guard !additions.isEmpty else { return }

        listedApplications.append(contentsOf: additions)
        Settings.listedApplications = listedApplications
        applicationTableView.reloadData()
    }

    @IBAction func removeApplication(_ sender: Any) {
        let selection = applicationTableView.selectedRowIndexes

        guard !selection.isEmpty else { return }

        listedApplications.remove(atOffsets: IndexSet(selection))
        Settings.listedApplications = listedApplications
        applicationTableView.reloadData()
        removeApplicationButton.isHidden = true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeApplicationButton.isHidden = applicationTableView.selectedRowIndexes.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        return listedApplications.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        return listedApplications[row].name
    }

    func tableView(_ tableView: NSTableView, toolTipFor cell: NSCell, rect: NSRectPointer, tableColumn: NSTableColumn?, row: Int, mouseLocation: NSPoint) -> String {
        return listedApplications[row].path
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()

        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: view.window!, completionHandler: nil)
    }
}
