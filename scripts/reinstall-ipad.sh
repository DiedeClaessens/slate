#!/bin/bash
# Rebuilds Slate and reinstalls it on the iPad, so the free 7-day signature never runs out.
# launchd runs it every day, see scripts/com.diedeclaessens.slate.reinstall.plist and the README.
set -euo pipefail
cd "$(dirname "$0")/.."

ipad=$(<scripts/ipad-id)
build="$HOME/Library/Caches/Slate"
profiles="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
echo "$(date '+%Y-%m-%d %H:%M') reinstalling Slate"

# Xcode keeps using a profile until it expires. Removing Slate's profile two days early makes the build fetch a new one in time.
for profile in "$profiles"/*.mobileprovision; do
  contents=$(security cms -D -i "$profile" 2>/dev/null) || continue
  [[ $(plutil -extract Entitlements.application-identifier raw -o - - <<<"$contents") == *.com.diedeclaessens.slate ]] || continue
  expires=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$(plutil -extract ExpirationDate raw -o - - <<<"$contents")" +%s)
  if (( expires - $(date +%s) < 2 * 86400 )); then
    echo "Profile expires $(date -r "$expires" '+%Y-%m-%d %H:%M'), fetching a new one"
    rm "$profile"
  fi
done

# A generic build doesn't need the iPad nearby. Only the install does.
xcodebuild build -project Slate.xcodeproj -scheme Slate -destination 'generic/platform=iOS' \
  -derivedDataPath "$build" -allowProvisioningUpdates -quiet
xcrun devicectl device install app --device "$ipad" "$build/Build/Products/Debug-iphoneos/Slate.app"
echo "Installed, signature valid until $(security cms -D -i "$build/Build/Products/Debug-iphoneos/Slate.app/embedded.mobileprovision" | plutil -extract ExpirationDate raw -o - -)"
