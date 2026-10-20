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
        xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m --output-format json
    else
        : ${NOTARY_KEY_PATH:?Set NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID, or NOTARY_PROFILE}
        xcrun notarytool submit "$1" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
            --issuer "$NOTARY_ISSUER_ID" --wait --timeout 30m --output-format json
    fi
}

notarize_file() {
    local result status id
    result=$(submit "$1")
    status=$(print -r -- $result | plutil -extract status raw -o - - 2>/dev/null || print unknown)
    id=$(print -r -- $result | plutil -extract id raw -o - - 2>/dev/null || print "")
    print "Notarization of ${1:t}: $status"
    if [[ $status != Accepted ]]; then
        [[ -n $id && -n ${NOTARY_PROFILE:-} ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE"
        [[ -n $id && -z ${NOTARY_PROFILE:-} ]] && xcrun notarytool log "$id" --key "$NOTARY_KEY_PATH" \
            --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
        exit 1
    fi
}

rm -rf $dist && mkdir -p $dist
zip=$dist/$name.zip
ditto -c -k --sequesterRsrc --keepParent $app $zip

if $notarize; then
    notarize_file $zip
    xcrun stapler staple $app
    # Re-zip so the download carries the stapled ticket and opens offline.
    rm $zip && ditto -c -k --sequesterRsrc --keepParent $app $zip
    spctl --assess --type execute --verbose=2 $app
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
    if $notarize; then
        notarize_file $dmg
        xcrun stapler staple $dmg
    fi
fi

print "Packaged:"
ls -lh $dist
