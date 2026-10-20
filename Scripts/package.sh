#!/bin/zsh
# Builds a universal Release copy of Still, signs it, and, when credentials are available, notarizes and
# staples it. Used by CI (.github/workflows/build.yml) and runnable locally.
#
#   Scripts/package.sh                 Apple Development signing: runs on this Mac only
#   SIGN_IDENTITY="Developer ID Application" Scripts/package.sh --notarize --dmg
#
# Environment:
#   SIGN_IDENTITY      Code-signing identity (default "Apple Development"; "-" signs ad hoc)
#   BUILD_NUMBER       CFBundleVersion (default: the project's)
#   NOTARY_KEY_PATH    App Store Connect API key (.p8) for notarization,
#   NOTARY_KEY_ID      with its key ID
#   NOTARY_ISSUER_ID   and issuer ID
#   NOTARY_PROFILE     Or a keychain profile saved with `xcrun notarytool store-credentials`
#   NOTARY_TIMEOUT     How long to wait for Apple (default 30m)
#   NOTARY_REQUIRED    "false" keeps a signed but unnotarized build when Apple is still processing
#                      at the timeout; a rejection always fails (default true)
#
# Output: build/dist/Still-<version>.zip, and Still-<version>.dmg with --dmg.

set -euo pipefail
cd "${0:A:h}/.."

notarize=false
make_dmg=false
for arg in "$@"; do
    case $arg in
        --notarize) notarize=true ;;
        --dmg) make_dmg=true ;;
        *) print -u2 "Unknown option: $arg"; exit 64 ;;
    esac
done

identity=${SIGN_IDENTITY:-Apple Development}
derived=build/DerivedData
app=$derived/Build/Products/Release/Still.app
dist=build/dist

xcodegen generate --quiet

build_settings=(CODE_SIGN_IDENTITY="$identity" OTHER_CODE_SIGN_FLAGS="--timestamp")
[[ $identity == "-" ]] && build_settings=(CODE_SIGN_IDENTITY=- OTHER_CODE_SIGN_FLAGS=)
[[ -n ${BUILD_NUMBER:-} ]] && build_settings+=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")

build() {
    xcodebuild -project Still.xcodeproj -scheme Still -configuration Release \
        -destination 'generic/platform=macOS' -derivedDataPath $derived $build_settings build
}
# xcbeautify, when installed, keeps the log readable.
if command -v xcbeautify >/dev/null; then build | xcbeautify --quiet; else build; fi

codesign --verify --deep --strict --verbose=2 $app
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $app/Contents/Info.plist)
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $app/Contents/Info.plist)
name="Still-$version-$build"
print "Built $name: $(lipo -archs $app/Contents/MacOS/Still), signed by: $identity"

submit() {
    if [[ -n ${NOTARY_PROFILE:-} ]]; then
        xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --timeout "${NOTARY_TIMEOUT:-30m}" --output-format json
    else
        : ${NOTARY_KEY_PATH:?Set NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID, or NOTARY_PROFILE}
        xcrun notarytool submit "$1" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
            --issuer "$NOTARY_ISSUER_ID" --wait --timeout "${NOTARY_TIMEOUT:-30m}" --output-format json
    fi
}

# Returns 0 when Apple accepted the file, 2 when it is still processing and that is allowed, else exits.
notarize_file() {
    # Not `status`: zsh reserves it for the last exit code.
    local result outcome id
    # notarytool exits non-zero on a timeout and writes that JSON to stderr; read it either way, from the
    # last JSON line.
    result=$(submit "$1" 2>&1) || true
    result=$(print -r -- $result | grep '^{' | tail -1)
    outcome=$(print -r -- $result | plutil -extract status raw -o - - 2>/dev/null || print unknown)
    id=$(print -r -- $result | plutil -extract id raw -o - - 2>/dev/null || print "")
    if [[ $outcome == unknown && $result == *Timeout* ]]; then
        outcome="In Progress"
    fi
    print "Notarization of ${1:t}: $outcome${id:+ (submission $id)}"
    if [[ $outcome == "In Progress" && ${NOTARY_REQUIRED:-true} == false ]]; then
        print "Apple is still processing it; keeping the signed build without a notarization ticket."
        return 2
    fi
    if [[ $outcome == "In Progress" ]]; then
        print -u2 "Apple hasn't finished within ${NOTARY_TIMEOUT:-30m}. Check later with: xcrun notarytool info $id"
        exit 1
    fi
    if [[ $outcome != Accepted ]]; then
        [[ -n $id && -n ${NOTARY_PROFILE:-} ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE"
        [[ -n $id && -z ${NOTARY_PROFILE:-} ]] && xcrun notarytool log "$id" --key "$NOTARY_KEY_PATH" \
            --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
        exit 1
    fi
}

rm -rf $dist && mkdir -p $dist
zip=$dist/$name.zip
ditto -c -k --sequesterRsrc --keepParent $app $zip

notarized=false
if $notarize; then
    if notarize_file $zip; then
        notarized=true
        xcrun stapler staple $app
        # Re-zip so the download carries the stapled ticket and opens offline.
        rm $zip && ditto -c -k --sequesterRsrc --keepParent $app $zip
        spctl --assess --type execute --verbose=2 $app
    fi
fi

if $make_dmg; then
    staging=$(mktemp -d)
    ditto $app $staging/Still.app
    ln -s /Applications $staging/Applications
    dmg=$dist/$name.dmg
    hdiutil create -volname Still -srcfolder $staging -ov -format UDZO -fs APFS $dmg >/dev/null
    rm -rf $staging
    if [[ $identity != "-" ]]; then
        # Sign with the certificate the app carries: a name like "Apple Development" can match several.
        certs=$(mktemp -d)
        codesign -d --extract-certificates=$certs/cert $app 2>/dev/null
        signer=$(openssl x509 -inform DER -in $certs/cert0 -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')
        rm -rf $certs
        codesign --sign $signer --timestamp $dmg
    fi
    # The DMG is only worth notarizing when the app inside it was.
    if $notarized && notarize_file $dmg; then
        xcrun stapler staple $dmg
    fi
fi

print "Packaged:"
ls -lh $dist
