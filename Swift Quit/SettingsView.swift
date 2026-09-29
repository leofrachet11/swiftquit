//
//  SettingsView.swift
//  Swift Quit
//

import SwiftUI
import UniformTypeIdentifiers

// Named after the list in Privacy & Security, which macOS 27 renamed.
private let accessibilitySettingName = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "Device Control and Data Access" : "Accessibility"

struct SettingsView: View {

    @AppStorage(launchHiddenKey) private var launchHidden = true
    @AppStorage(closeDelayKey) private var closeDelay = defaultCloseDelay
    @AppStorage(listModeKey) private var listMode = ListMode.quitAllExceptListed

    @State private var menuBarIconVisible = Settings.menuBarIconVisible
    @State private var launchAtLogin = Settings.launchAtLogin
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var listedApplications = Settings.listedApplications
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Swift Quit").font(.headline)
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                LabeledContent(accessibilitySettingName) {
                    if accessibilityGranted {
                        Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    else {
                        Button("Grant Access…") {
                            appDelegate.requestAccessibility()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
            } footer: {
                Text(accessibilityGranted
                     ? "Swift Quit can tell a minimised window from one an app hides when you close it."
                     : "Without it, apps that keep a closed window in memory (Notes, Calendar, Activity Monitor) are never quit, and windows minimised before Swift Quit started don't keep their app open.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Start at login", isOn: Binding(get: { launchAtLogin }, set: changeLaunchAtLogin))
                Toggle("Open settings when Swift Quit starts", isOn: Binding(get: { !launchHidden }, set: { launchHidden = !$0 }))
                Toggle("Show menu bar icon", isOn: Binding(get: { menuBarIconVisible }, set: changeMenuBarIcon))
            } footer: {
                if !menuBarIconVisible {
                    Text("Open Swift Quit again from Applications to get back here.").foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Quit after") {
                    HStack(spacing: 6) {
                        TextField("Seconds", value: Binding(get: { closeDelay }, set: { closeDelay = min(max($0, 0), maximumCloseDelay) }), format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 56)
                        Stepper("Seconds", value: $closeDelay, in: 0 ... maximumCloseDelay).labelsHidden()
                        Text(closeDelay == 1 ? "second" : "seconds")
                    }
                }

                Picker("Quit", selection: $listMode) {
                    Text("All apps except these").tag(ListMode.quitAllExceptListed)
                    Text("Only these apps").tag(ListMode.quitOnlyListed)
                }

                ForEach(listedApplications) { application in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: application.path))
                            .resizable()
                            .frame(width: 20, height: 20)
                        Text(application.name)
                        Spacer()
                        Button {
                            listedApplications.removeAll { $0 == application }
                            Settings.listedApplications = listedApplications
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(application.name)")
                    }
                    .help(application.path)
                }

                Button("Add App…", action: addApplications)
            } footer: {
                Text("0 seconds quits straight away. Very short delays can catch apps that briefly close their only window, such as an editor reloading.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 440)
        .fixedSize()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = AXIsProcessTrusted()
            launchAtLogin = Settings.launchAtLogin
        }
        .alert("Couldn't change the login item", isPresented: Binding(get: { loginItemError != nil }, set: { if !$0 { loginItemError = nil } })) {
            Button("OK") {}
        } message: {
            Text("\(loginItemError ?? "")\n\nSwift Quit usually has to be in your Applications folder before it can start at login.")
        }
    }

    private func changeLaunchAtLogin(_ enabled: Bool) {
        do {
            try Settings.setLaunchAtLogin(enabled)
        }
        catch {
            loginItemError = error.localizedDescription
        }

        launchAtLogin = Settings.launchAtLogin
    }

    private func changeMenuBarIcon(_ visible: Bool) {
        menuBarIconVisible = visible
        Settings.menuBarIconVisible = visible
        appDelegate.setStatusItemVisible(visible)
    }

    private func addApplications() {
        let panel = NSOpenPanel()

        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        guard panel.runModal() == .OK else { return }

        let additions = panel.urls.compactMap { ListedApplication(path: $0.path) }.filter { addition in
            !listedApplications.contains { $0.bundleIdentifier == addition.bundleIdentifier }
        }

        listedApplications.append(contentsOf: additions)
        Settings.listedApplications = listedApplications
    }
}
