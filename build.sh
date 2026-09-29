#!/bin/zsh
#
# ./build.sh            builds a universal (Apple silicon + Intel) dist/Swift Quit.app
# ./build.sh release    also notarizes it and zips it for sharing
#
# Both sign with the Developer ID Application certificate in your keychain when there is one, so
# macOS keeps Accessibility access across rebuilds. Without one the app is signed ad hoc.
#

set -euo pipefail

notary_profile="swiftquit"

cd "$(dirname "$0")"

mode="${1:-local}"
app="dist/Swift Quit.app"
developer_id=$(security find-identity -v -p codesigning | awk '/"Developer ID Application: / { print $2; exit }')

# A secure timestamp is a round trip to Apple, which only notarization needs.
timestamp="--timestamp=none"

if [[ $mode == release ]]; then
    if [[ -z $developer_id ]]; then
        echo "Releases need a Developer ID Application certificate in the keychain."
        echo "Create one in Xcode: Settings > Accounts > Manage Certificates > + > Developer ID Application."
        exit 1
    fi

    timestamp="--timestamp"
fi

xcodebuild -project "Swift Quit.xcodeproj" -scheme "Swift Quit" -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath build -quiet build

rm -rf dist
mkdir dist
ditto "build/Build/Products/Release/Swift Quit.app" "$app"

if [[ -n $developer_id ]]; then
    codesign --force --options runtime "$timestamp" --sign "$developer_id" "$app"
fi

if [[ $mode != release ]]; then
    echo "Built $app"
    exit 0
fi

team_id=$(codesign -dv "$app" 2>&1 | awk -F = '/^TeamIdentifier=/ { print $2 }')
version=$(defaults read "$PWD/$app/Contents/Info" CFBundleShortVersionString)
archive="dist/Swift-Quit-$version.zip"

if ! xcrun notarytool history --keychain-profile "$notary_profile" > /dev/null 2>&1; then
    echo "Notarizing needs your Apple ID and an app-specific password from account.apple.com > Sign-In and Security. It's only asked once."
    xcrun notarytool store-credentials "$notary_profile" --team-id "$team_id"
fi

# The notary service takes a zip, not a bare .app folder.
ditto -c -k --keepParent "$app" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$app"

# Zipped again so the download carries the stapled ticket and opens without a network check.
rm "$archive"
ditto -c -k --keepParent "$app" "$archive"
echo "Notarized $app and $archive"
