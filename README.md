# Swift Quit

Swift Quit quits a macOS app when you close its last window. Close the final Safari window and Safari quits instead of sitting in the Dock doing nothing.

This is a fork of [onebadidea/swiftquit](https://github.com/onebadidea/swiftquit), which has not been updated since 2022 and stopped working on recent macOS releases. Version 2.0 replaces the detection engine, drops every third-party dependency, and no longer asks for Accessibility permission.

## What changed in 2.0

**It works again on macOS 26 and 27.** The old build listened for Accessibility window-destroyed events through [Swindler](https://github.com/tmandry/Swindler). Those events stopped arriving reliably, so nothing quit. Detection now reads the WindowServer directly.

**Switching Spaces no longer quits your apps.** This is the trap every other fork fell into. The Accessibility API reports zero windows for any app whose windows are on another Space, so an Accessibility-based build sees "no windows left" every time you swipe between desktops and starts quitting things. Measured on macOS 27 with five apps open: Accessibility reported 0 windows for Visual Studio Code while the WindowServer reported 2, and 1 window for Safari while the WindowServer reported 7.

**No Accessibility permission.** The whole install ritual is gone, along with the old rule that you had to remove the previous version from the Accessibility list before upgrading. Swift Quit reads window layout through `CGWindowListCopyWindowInfo`, which returns window owners, layers and visibility to any app without a permission grant. Window titles are the only thing macOS withholds, and Swift Quit never reads them.

**A delay of 0 is allowed.** The old field rejected it, so the shortest wait was one second. Set it to 0 and the app quits as soon as its last window is gone.

**Pause from the menu bar.** Useful when you are about to do something where an app closing its own window would be inconvenient.

**Apps are matched by bundle identifier, not by file path.** The old list stored absolute paths and compared them after some hand-rolled URL decoding, so an app moved between `/Applications` and `/System/Applications` silently fell off your list. Existing settings are migrated the first time 2.0 runs.

**Zero dependencies.** Swindler, PromiseKit, AXSwift, LaunchAtLogin, Quick and Nimble are all gone. The app is four Swift files and the system frameworks. Launch at login uses `SMAppService`.

The v1.5 app and menu bar artwork is back, replacing the icons from a later pull request.

## How it decides

Every app keeps windows you never see: a menu bar surface per Space, and parked windows AppKit creates but never shows. Counting an app's windows naively counts those too, so the count never reaches zero and nothing ever quits. Filtering them out by size or position is guesswork that breaks on the next macOS release.

Instead, a window becomes "real" the first time the WindowServer reports it on screen, and stays real until it is destroyed. Minimised windows, occluded windows and windows on other Spaces all keep counting, because they still exist. An app becomes a candidate for quitting when its last real window disappears. After the configured delay, Swift Quit re-reads the window list and only quits if the app is still empty, so reopening a window during the delay cancels the quit.

Polling adapts to what you are doing. While you are typing or clicking it checks every 150 ms; after three seconds of no input it drops to once a second. The idle check costs about 50 nanoseconds and the window read about 2 ms, so Swift Quit does nothing measurable while you are away from the machine.

### Known limitation

If you close an app's last window on your current Space while that app has another window on a Space you have not visited since Swift Quit started, the app is quit. Swift Quit has never seen the other window, so it does not know it exists. Visiting that Space once is enough to fix it for the rest of the session. The original Swift Quit had the same blind spot and quit in more situations besides.

## Install

1. Build the app (see below) or grab it from Releases.
2. Move `Swift Quit.app` to your Applications folder.
3. Right-click it and choose Open, then confirm. macOS asks because the app is not signed with a paid Developer ID.
4. Turn on "Start Swift Quit Automatically" in Settings if you want it running after a restart.

The Homebrew cask `swift-quit` and the downloads on swiftquit.com are the old 1.5 release, not this fork.

## Settings

| Setting | What it does |
| --- | --- |
| Start Swift Quit Automatically | Registers a login item through `SMAppService` |
| Hide App on Startup | Skips the settings window at launch |
| Display Icon in Menubar | Hides the menu bar icon. Open the app again to get the settings back |
| Quit apps after (seconds) | Wait between the last window closing and the app quitting. 0 quits immediately |
| Quit / app list | Either quit everything except the listed apps, or quit only the listed apps |

Finder, Dock, Spotlight, Control Centre, Notification Centre, SystemUIServer, WindowManager and loginwindow are never quit.

Swift Quit asks apps to quit the same way the Quit menu item does, so an app with unsaved work shows its save dialog and stays open. Nothing is force-killed.

To see what it has been doing:

```
log show --last 1h --predicate 'subsystem == "onebadidea.Swift-Quit"' --style compact
```

## Building

Requires Xcode 15 or later. macOS 13 is the deployment target.

```
xcodebuild -project "Swift Quit.xcodeproj" -scheme "Swift Quit" \
  -configuration Release -destination 'generic/platform=macOS' build
```

The built app lands in the scheme's build products directory. Without `-destination` you get a binary for your own Mac only; with it you get a universal `arm64` and `x86_64` build.

There is nothing to resolve first. The project has no package dependencies.

## Credits

Original app by [Johnny Baird](https://github.com/onebadidea). This fork also draws on the work of three others who each fixed part of the problem: [gogoSpace](https://github.com/gogoSpace/swiftquit) for showing that event-based detection had to be replaced with polling, [crushcitycoder](https://github.com/crushcitycoder/swiftquit) for moving window state to the WindowServer and for restoring the v1.5 artwork, and [bampudding](https://github.com/bampudding/swiftquit-tahoe) for the `SMAppService` login item and the wider list of system apps to leave alone.
