#!/bin/zsh
# Builds Still from this checkout and installs it as /Applications/Still.app, replacing the copy there.
# If that copy is running, waits for it to quit first.
#
#   Scripts/install.sh
#
# Signs with the project team's Developer ID certificate when this Mac has it, as releases are, so macOS
# keeps the app's identity, its data and its Photos permission across updates. Otherwise it signs with
# Apple Development. SIGN_IDENTITY overrides either.

set -euo pipefail
cd "${0:A:h}/.."

installed=/Applications/Still.app

team=$(sed -n 's/^ *DEVELOPMENT_TEAM: *//p' project.yml | head -1)
if [[ -z ${SIGN_IDENTITY:-} ]]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning |
        sed -n "s/.*\"\(Developer ID Application: .*($team)\)\"/\1/p" | head -1)
    : ${SIGN_IDENTITY:=Apple Development}
fi
export SIGN_IDENTITY

Scripts/package.sh
built=build/DerivedData.noindex/Build/Products/Release/Still.app

if pgrep -f "^$installed/Contents/MacOS/Still" >/dev/null; then
    print "Waiting for Still to quit…"
    while pgrep -f "^$installed/Contents/MacOS/Still" >/dev/null; do sleep 2; done
fi

# Copy first, then swap, so a failed copy leaves the installed app alone.
staging=$(mktemp -d /Applications/.Still-install.XXXXXX)
ditto $built $staging/Still.app
rm -rf $installed
mv $staging/Still.app $installed
rmdir $staging
# Only the installed copy should appear in Open With; Xcode registers the one it built.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$lsregister -u $built
$lsregister -f $installed

codesign --verify --deep --strict $installed
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $installed/Contents/Info.plist)
print "Installed Still $version ($(git rev-parse --short HEAD)), signed by: $SIGN_IDENTITY"
