# Swift Quit

Swift Quit quits a Mac app when you close its last window, so it doesn't sit in the Dock with nothing open.

This is a fork of [onebadidea/swiftquit](https://github.com/onebadidea/swiftquit), which stopped working on macOS 26. It runs on macOS 13 through 27.

## Install

1. Download the latest [release](https://github.com/leofrachet11/swiftquit/releases), open the zip and move Swift Quit to Applications.
2. Open it and grant access when macOS asks. The setting is under Privacy & Security > Accessibility, which macOS 27 calls Device Control and Data Access.
3. Turn on "Start at login".

Swift Quit works without access, with two gaps. It can't quit apps that hide their window when you close it, like Notes and Calendar. It can't see menu bar icons, so it may quit menu bar apps.

The Homebrew cask and swiftquit.com still ship the old 1.5.

## How it works

- Swift Quit checks which apps have a window open on any desktop, 10 times a second while you use the Mac and once a second when you don't. Switching desktops never quits anything.
- When you close an app's last window, it waits for your delay, from 0 seconds up, then quits the app the way Cmd+Q does. Unsaved work still asks to be saved. Nothing is force-quit.
- An app that closes its own window, like a splash screen handing over to the main window, gets at least 3 seconds to open the next one.
- Windows you can't see don't count, whether nearly transparent, tiny or off-screen.
- Apps meant to work without a window keep running. That covers menu bar apps, VPNs, apps playing audio and apps keeping the Mac awake. Add anything else to the exception list.
- When an app quits but leaves idle helpers behind, which keep it in the Dock as "Running in Background", Swift Quit stops them.
- Finder is never quit.

To see what it quit or kept running, and why:

```
log show --last 1h --predicate 'subsystem == "onebadidea.Swift-Quit"' --style compact
```

## Changes from 1.5

- Works on macOS 26 and 27.
- Switching desktops doesn't quit apps.
- Quits apps that hide their window on close, like Notes, and Steam.
- Leaves VPNs, music, calls and menu bar apps running.
- Doesn't quit apps while they swap windows, like Word opening a document.
- Clears the "Running in Background" state apps leave in the Dock.
- The delay can be 0, and the menu bar menu has a pause switch.
- Apps on your list stay on it if you move them. A 1.5 list carries over.
- No third-party code, 0.9 MB instead of 2.4 MB, and notarized.

## Building

```
./build.sh            # dist/Swift Quit.app, universal
./build.sh release    # also notarizes and zips it
```

It needs Xcode 15 or later. With a Developer ID Application certificate in your keychain the app is signed with it, otherwise ad hoc. An ad hoc build loses its access on every rebuild. The first release build asks for your Apple ID and an app-specific password.

## Credits

Original app by [Johnny Baird](https://github.com/onebadidea). This fork borrows from three others. [gogoSpace](https://github.com/gogoSpace/swiftquit) showed that detection had to poll. [crushcitycoder](https://github.com/crushcitycoder/swiftquit) moved window state to the WindowServer and brought back the 1.5 artwork. [bampudding](https://github.com/bampudding/swiftquit-tahoe) used `SMAppService` for the login item.
