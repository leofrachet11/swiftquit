# Swift Quit

Swift Quit quits a macOS app when you close its last window. Close the final Safari window and Safari quits instead of sitting in the Dock.

This is a fork of [onebadidea/swiftquit](https://github.com/onebadidea/swiftquit), which hasn't been updated since 2022 and stopped working on recent macOS releases. It has a new detection engine and no third-party dependencies, and it runs on macOS 13 through 27.

## Accessibility access

Swift Quit runs without any permissions, but it only works properly with Accessibility access. Grant it from the settings window, or in System Settings > Privacy & Security > Accessibility. macOS 27 renamed that list to Device Control and Data Access.

The reason is a gap in what macOS reports. When you minimise a window, and when an app like Notes hides its window on close instead of destroying it, the WindowServer reports the same thing: the window exists but isn't ordered in. Only the Accessibility API tells them apart, because it lists minimised windows and skips hidden ones. Without it, Swift Quit has to assume a hidden window might be minimised, which means:

- apps that keep a closed window in memory are never quit. Among Apple's own apps, Notes, Calendar, Activity Monitor, Console and Chess do this.
- a window minimised before Swift Quit started doesn't keep its app open.

With access granted, neither applies.

macOS ties the permission to the app's signature. A build signed with a Developer ID certificate keeps it through rebuilds and updates, because macOS checks the developer's team rather than the exact binary. An ad hoc build, which is what `./build.sh` makes when your keychain has no Developer ID certificate, loses it on every rebuild: remove Swift Quit from the Accessibility list and add it again.

## How it decides

Swift Quit asks which windows are ordered in on any Space, using `NSWindow.windowNumbers(options: [.allApplications, .allSpaces])`. That list includes covered windows and windows on other desktops, and leaves out the menu bar surfaces and never-shown windows every app keeps. The Accessibility API only reports the current Space, which is why the other forks quit apps as you swipe between desktops. It reported 0 windows for VS Code where the WindowServer reported 2. Here a Space switch changes nothing: four real switches with a 0-second delay quit nothing.

When an app's last ordered-in window goes away, the app becomes a candidate. Minimising, hiding and going full screen do this too, since a full-screen transition leaves the app with no ordered-in windows for about half a second. After the close delay Swift Quit checks again, skips hidden apps, and asks Accessibility whether the app still has any window, minimised ones included. If a window comes back during the delay, the pending quit is cancelled and the delay starts over at the next close.

Each check takes about 75 µs, 27 times less than reading the full window list. Swift Quit checks every 0.1 s while you're using the Mac and once a second after 3 s without input. Apps are asked to quit the way Cmd+Q asks them, so unsaved work brings up the usual save dialog. Nothing is force-quit.

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
| Open settings when Swift Quit starts | Shows the settings window at launch. The first launch always shows it |
| Show menu bar icon | Hides the icon. Open the app again to get the settings back |
| Quit after | Seconds between the last window closing and the app quitting. 0 quits straight away, but very short delays can catch an app that briefly closes its only window, like an editor reloading |
| Quit | Quit every app except the listed ones, or only the listed ones |

The menu bar menu has a pause switch, and the icon dims while Swift Quit is paused. Finder is never quit.

Settings live in the `onebadidea.Swift-Quit` defaults domain, the same one 1.5 used, so an existing app list carries over.

To see what Swift Quit has quit:

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
- The delay can be 0.
- The menu bar menu can pause Swift Quit.
- Apps are matched by bundle identifier instead of file path, so moving an app doesn't drop it from the list. 1.5 settings migrate on first launch.
- No dependencies. Swindler, PromiseKit, AXSwift, LaunchAtLogin, Quick and Nimble are gone, launch at login uses `SMAppService`, and the 900-line storyboard is replaced by a small SwiftUI settings form.
- The v1.5 artwork is back.

## Credits

Original app by [Johnny Baird](https://github.com/onebadidea). This fork also draws on three others who each fixed part of the problem: [gogoSpace](https://github.com/gogoSpace/swiftquit) for showing that event-based detection had to become polling, [crushcitycoder](https://github.com/crushcitycoder/swiftquit) for moving window state to the WindowServer and for restoring the v1.5 artwork, and [bampudding](https://github.com/bampudding/swiftquit-tahoe) for the `SMAppService` login item.
