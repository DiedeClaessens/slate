<img src="assets/icon.svg" width="64" height="64" alt="">

# Slate

A personal iPad app for handwriting with the Apple Pencil on pages, PDFs and images. See [docs/design.md](docs/design.md) for what it does and the build order.

> [!WARNING]
> Slate is a personal project I put together for fun, because I wanted a notes app that works exactly the way I like. It is not on the App Store and never will be. Nobody supports it, and an update can change how notes are stored, so I don't recommend trusting it with notes you can't lose. Read the code or borrow ideas from it if you like.

## Run it on your iPad

You need a Mac with Xcode 27 and an iPad on iPadOS 27 or later.

1. Connect the iPad with a cable and open `Slate.xcodeproj` in Xcode.
2. On the iPad, turn on Settings > Privacy & Security > Developer Mode (it appears after the first connection) and restart.
3. Pick the iPad as the run destination and press Run. Signing uses your free Personal Team.
4. The first time, trust the developer on the iPad: Settings > General > VPN & Device Management.

With a free Apple ID the app stops opening after 7 days. Press Run again to reinstall it. Your notes stay.

## Automatic reinstall

`scripts/reinstall-ipad.sh` rebuilds Slate and reinstalls it on the iPad, so the 7-day signature never runs out. When Slate's signing profile has less than two days left, the script removes it so Xcode fetches a new one. A launch agent runs the script every day at 13:00, or when the Mac wakes up if it was asleep then. It needs the Mac logged in, and the iPad on the cable or on the same Wi-Fi. For Wi-Fi, connect the iPad by cable once and tick "Connect via network" for it in Xcode under Window > Devices and Simulators. The log is in `~/Library/Logs/slate-reinstall.log`.

The script reads the iPad's identifier from `scripts/ipad-id`, which git ignores. Find the identifier with `xcrun devicectl list devices` and save it in that file.

Turn it on:

```sh
cp scripts/com.diedeclaessens.slate.reinstall.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.diedeclaessens.slate.reinstall.plist
```

Run it now with `launchctl kickstart gui/$(id -u)/com.diedeclaessens.slate.reinstall`. Turn it off with `launchctl bootout gui/$(id -u)/com.diedeclaessens.slate.reinstall`.

## Where notes live

In the Files app under On My iPad > Slate. Each note is a `.slate` folder with `note.json`, `drawing.data`, `thumbnail.png` and a `files` folder with its PDFs and images.

## Tests

```sh
xcodebuild test -project Slate.xcodeproj -scheme Slate -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)'
```
