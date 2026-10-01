# Swift Quit

Swift Quit quits a macOS app when you close its last window. Close the final Safari window and Safari quits instead of sitting in the Dock.

This is a fork of [onebadidea/swiftquit](https://github.com/onebadidea/swiftquit), which hasn't been updated since 2022 and stopped working on recent macOS releases. It has a new detection engine and no third-party dependencies, and it runs on macOS 13 through 27.

## Accessibility access

Swift Quit runs without any permissions, but it only works properly with Accessibility access. Grant it from the settings window, or in System Settings > Privacy & Security > Accessibility. macOS 27 renamed that list to Device Control and Data Access.

The reason is a gap in what macOS reports. When you minimise a window, and when an app like Notes hides its window on close instead of destroying it, the WindowServer reports the same thing: the window exists but isn't ordered in. Only the Accessibility API tells them apart, because it lists minimised windows and skips hidden ones. Without it, Swift Quit has to assume a hidden window might be minimised, which means:

- apps that keep a closed window in memory are never quit. Among Apple's own apps, Notes, Calendar, Activity Monitor, Console and Chess do this.
- a window minimised before Swift Quit started doesn't keep its app open.

With access granted, neither applies. Accessibility is also the only way Swift Quit can see menu bar icons, which it uses to leave apps like VPNs running (see below).

macOS ties the permission to the app's signature. A build signed with a Developer ID certificate keeps it through rebuilds and updates, because macOS checks the developer's team rather than the exact binary. An ad hoc build, which is what `./build.sh` makes when your keychain has no Developer ID certificate, loses it on every rebuild: remove Swift Quit from the Accessibility list and add it again.

## How it decides

Swift Quit asks which windows are ordered in on any Space, using `NSWindow.windowNumbers(options: [.allApplications, .allSpaces])`. That list includes covered windows and windows on other desktops, and leaves out the menu bar surfaces and never-shown windows every app keeps. The Accessibility API only reports the current Space, which is why the other forks quit apps as you swipe between desktops. It reported 0 windows for VS Code where the WindowServer reported 2. Here a Space switch changes nothing: four real switches with a 0-second delay quit nothing.

When an app's last ordered-in window goes away, the app becomes a candidate. Minimising, hiding and going full screen do this too, since a full-screen transition leaves the app with no ordered-in windows for about half a second. After the close delay Swift Quit checks again, skips hidden apps, and asks Accessibility whether the app still has any window, minimised ones included. If a window comes back during the delay, the pending quit is cancelled and the delay starts over at the next close.

A window only counts if you could see it: at least 10% opaque, at least 40 points across and on a display. Word shows an invisible window while it opens a document, InDesign keeps one parked far off-screen and Steam keeps a 1-point one. Swift Quit looks at windows that don't count again every second, in case they fade or move into view. The size and position rule also applies to the windows Accessibility lists.

Some apps draw their windows from a helper. Steam's window belongs to Steam Helper, an app inside Steam's bundle, so Steam itself never owns one. A window from a helper inside an app's bundle counts for that app, and Swift Quit asks Accessibility about the helper too.

Apps also empty themselves. Splash screens and sign-in windows hand over to the next window, sometimes with a gap: Photoshop's splash screen disappears 0.1 to 0.2 s before its main window appears. So Swift Quit checks who closed the last window. If you clicked or pressed a key just before it went, the close was yours and your delay applies, 0 included. If not, or if the app launched less than 30 seconds ago, the app gets at least 3 seconds to open its next window. macOS reports how long ago you last clicked or typed without any permission.

Swift Quit checks every 0.1 s while you're using the Mac and once a second after 3 s without input. Measured on macOS 27, that uses about 0.7% of one CPU core while you're active with a dozen windows open, 1.8% with 40, and about 0.1% when you're idle, plus 13 to 20 MB of memory. Most of it is AppKit's window list call, which asks the WindowServer about each window in turn. Apps are asked to quit the way Cmd+Q asks them, so unsaved work brings up the usual save dialog. Nothing is force-quit.

## Apps that should keep running

Some apps are meant to carry on without a window, like a VPN or a music player. Before quitting an app, Swift Quit looks for signs of one and leaves the app running if it finds any:

- It's a background app. Apps like NordVPN declare themselves menu bar apps and only take a Dock icon when you ask for one.
- It has a menu bar icon, like Happ, Docker and most VPNs. macOS 27 keeps menu bar icons out of the window list, so this needs Accessibility access.
- It's playing or recording audio, such as music, a podcast or a call. Sound from an app's helper processes counts, including the shared process that WebKit apps play through. This needs macOS 14.2 or later.
- It's keeping the Mac awake, as apps do during downloads, exports, encodes and calls.

These checks only run for an app that's about to be quit, so they cost nothing while Swift Quit watches windows. The log says which one kept an app open. Under "Only these apps", the apps you list are quit even if they live in the menu bar, but not while they're busy. Your list and the app's own Dock status are checked again when the delay ends, so adding an app during the delay still saves it.

That leaves your list for apps that keep working without a window and show none of these signs: a chat or mail app you keep open for notifications, a paused player you resume with the media keys, a timer, or a sync or download app that doesn't keep the Mac awake.

## Apps left running in the background

When an app quits but something it started is still running, macOS keeps it in the Dock with a grey dot and the label "Running in Background". It counts two kinds of leftover: processes in the app's coalition, which are the helpers it started itself, and background-only apps it launched. The Dock's "Stop Running in Background" sends those the terminate signal. Photoshop leaves two behind whether you quit it or Swift Quit does: Adobe's IPC broker and Creative Cloud's content manager. Vysor leaves its `adb` server.

For apps Swift Quit looks after, it does what that menu item does, whoever quit the app. It waits 5 seconds, then sends all the leftovers the terminate signal at once, but only ones that:

- are signed by the same developer as the app and started after it,
- have no windows or menu bar icon,
- aren't playing audio, keeping the Mac awake or using more than 2% of a CPU core.

While any of them is still working, the app really is running in the background, so Swift Quit looks again every 5 seconds for a minute. After Photoshop quits, Creative Cloud's content manager uses more than a whole CPU core for about 7 seconds, so Photoshop's dot goes 10 to 30 seconds after the quit. If you open the app again in the meantime, its helpers are left for its next quit.

The apps built into macOS carry no developer team, so they're left alone, and so are programs started from a terminal. A leftover from another developer keeps the dot: HTTP Toolkit starts the Android SDK's `adb` server, which other tools share. Apps on your exception list, and background apps like VPNs, are left alone. Nothing is force-quit.

## Install

1. Build it (see below) or download a release.
2. Move `Swift Quit.app` to Applications.
3. Open it. A copy you built yourself opens straight away. A notarized release asks once whether to open an app from the internet. A copy that isn't notarized has to be allowed in System Settings > Privacy & Security > Open Anyway.
4. Grant Accessibility access when asked.
5. Turn on "Start at login" if you want it running after a restart.

The Homebrew cask `swift-quit` and swiftquit.com still ship the old 1.5.

## Settings

| Setting | What it does |
| --- | --- |
| Start at login | Registers a login item with `SMAppService` |
| Show menu bar icon | Hides the icon. Open the app again to get the settings back |
| Quit after | Seconds between you closing the last window and the app quitting. 0 quits straight away. An app that closes its own window, or launched less than 30 s ago, gets at least 3 s |
| Quit | Quit every app except the listed ones, or only the listed ones |

The menu bar menu has a pause switch, and the icon dims while Swift Quit is paused. Finder is never quit.

Settings live in the `onebadidea.Swift-Quit` defaults domain, the same one 1.5 used, so an existing app list carries over.

To see what Swift Quit has quit or kept running, and why:

```
log show --last 1h --predicate 'subsystem == "onebadidea.Swift-Quit"' --style compact
```

## Building

```
./build.sh
```

This puts a universal (Apple silicon and Intel) `dist/Swift Quit.app` in the repo. It needs Xcode 15 or later, and there are no packages to resolve. If your keychain has a Developer ID Application certificate, the app is signed with it. Otherwise it's signed ad hoc.

### Notarized releases

```
./build.sh release
```

This also sends the app to Apple's notary service, staples the approval to it, and writes `dist/Swift-Quit-<version>.zip` for a GitHub release. The zip is there because the notary service and GitHub both take a single file, and a `.app` is a folder.

It needs a Developer ID Application certificate, which you can create in Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application. The first run asks for your Apple ID and an app-specific password, made at account.apple.com under Sign-In and Security, and keeps them in the keychain.

## Changes from the original

- Works on macOS 26 and 27. The original listened for Accessibility window events through Swindler, and those stopped arriving.
- Switching Spaces doesn't quit apps.
- Apps that hide their window on close, like Notes and Calendar, get quit (with Accessibility access).
- Apps meant to run without a window, like VPNs, music players and calls, are left running.
- Apps that swap windows on their own, like Word opening a document, aren't quit in the gap.
- Helpers an app leaves behind don't keep it in the Dock as "Running in Background".
- Steam, which draws its window from a helper, gets quit.
- The delay can be 0.
- The menu bar menu can pause Swift Quit.
- Apps are matched by bundle identifier instead of file path, so moving an app doesn't drop it from the list. 1.5 settings migrate on first launch.
- No dependencies. Swindler, PromiseKit, AXSwift, LaunchAtLogin, Quick and Nimble are gone, launch at login uses `SMAppService`, and the 900-line storyboard is replaced by a small SwiftUI settings form.
- The v1.5 app icon is back, and the menu bar icon is a sharp template drawn from it.

## Credits

Original app by [Johnny Baird](https://github.com/onebadidea). This fork also draws on three others who each fixed part of the problem: [gogoSpace](https://github.com/gogoSpace/swiftquit) for showing that event-based detection had to become polling, [crushcitycoder](https://github.com/crushcitycoder/swiftquit) for moving window state to the WindowServer and for restoring the v1.5 artwork, and [bampudding](https://github.com/bampudding/swiftquit-tahoe) for the `SMAppService` login item.
