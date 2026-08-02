#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/VoiceInk.xcodeproj"
SCHEME="VoiceInk"
LOCAL_CONFIG="$REPO_ROOT/LocalBuild.xcconfig"
LOCAL_ENTITLEMENTS="$REPO_ROOT/VoiceInk/VoiceInk.local.entitlements"
EXPECTED_BUNDLE_ID="com.prakashjoshipax.VoiceInk"
EXPECTED_ARCHS="${EXPECTED_ARCHS:-arm64 x86_64}"
VERSION=""
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
OUTPUT_DIR="${VOICEINK_RELEASE_OUTPUT_DIR:-$REPO_ROOT/build/release}"

usage() {
    printf '%s\n' \
        "Usage: scripts/release.sh --version <MAJOR.MINOR.PATCH> [--build-number N] [--output-dir DIR]" \
        "" \
        "Builds an ad-hoc-signed universal VoiceInk.app and packages VoiceInk.zip." \
        "No Apple Developer certificate or notarization credentials are required."
}

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -ge 2 ]] || fail "--version requires a value"
            VERSION="$2"
            shift 2
            ;;
        --build-number)
            [[ $# -ge 2 ]] || fail "--build-number requires a value"
            BUILD_NUMBER="$2"
            shift 2
            ;;
        --output-dir)
            [[ $# -ge 2 ]] || fail "--output-dir requires a value"
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must use MAJOR.MINOR.PATCH"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || fail "build number must be numeric"

for command_name in awk codesign cp curl ditto find grep lipo make plutil shasum tr unzip xcodebuild; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done

if [[ -d "/Applications/Xcode_26.5.app/Contents/Developer" && -z "${DEVELOPER_DIR:-}" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode_26.5.app/Contents/Developer"
elif [[ -d "/Applications/Xcode.app/Contents/Developer" && -z "${DEVELOPER_DIR:-}" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

OUTPUT_DIR="$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)"
DERIVED_DATA="$OUTPUT_DIR/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Release/VoiceInk.app"
ZIP_PATH="$OUTPUT_DIR/VoiceInk.zip"
CASK_PATH="$OUTPUT_DIR/voiceink.rb"
CHECKSUM_PATH="$OUTPUT_DIR/SHA256SUMS"
# shellcheck disable=SC2016
SWIFT_BUILD_CONDITIONS='$(inherited) LOCAL_BUILD'

rm -rf "$DERIVED_DATA"
rm -f "$ZIP_PATH" "$CASK_PATH" "$CHECKSUM_PATH"

make -C "$REPO_ROOT" whisper
"$REPO_ROOT/scripts/prepare-sherpa-onnx.sh"

xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -xcconfig "$LOCAL_CONFIG" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=YES \
    DEVELOPMENT_TEAM="" \
    CODE_SIGN_ENTITLEMENTS="$LOCAL_ENTITLEMENTS" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS="$SWIFT_BUILD_CONDITIONS" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    build

[[ -d "$APP_PATH" ]] || fail "built app not found: $APP_PATH"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
EXECUTABLE="$APP_PATH/Contents/MacOS/VoiceInk"
[[ -f "$INFO_PLIST" ]] || fail "app Info.plist not found"
[[ -x "$EXECUTABLE" ]] || fail "app executable not found"

codesign --force --deep --sign - --entitlements "$LOCAL_ENTITLEMENTS" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

verify_ad_hoc_signature() {
    local code_path="$1"
    local signature_details
    signature_details="$(codesign --display --verbose=4 "$code_path" 2>&1)"
    grep -Fq "Signature=adhoc" <<<"$signature_details" \
        || fail "expected ad-hoc signature: $code_path"
    grep -Fq "TeamIdentifier=not set" <<<"$signature_details" \
        || fail "unexpected Team ID in ad-hoc release: $code_path"
}

verify_ad_hoc_signature "$APP_PATH"
while IFS= read -r framework_path; do
    verify_ad_hoc_signature "$framework_path"
done < <(find "$APP_PATH/Contents/Frameworks" -type d -name "*.framework" -prune -print)

APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
APP_BUILD="$(plutil -extract CFBundleVersion raw "$INFO_PLIST")"
APP_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$INFO_PLIST")"
[[ "$APP_VERSION" == "$VERSION" ]] || fail "app version $APP_VERSION does not match $VERSION"
[[ "$APP_BUILD" == "$BUILD_NUMBER" ]] || fail "app build $APP_BUILD does not match $BUILD_NUMBER"
[[ "$APP_BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || fail "unexpected bundle id: $APP_BUNDLE_ID"

for architecture in $EXPECTED_ARCHS; do
    lipo -archs "$EXECUTABLE" | tr ' ' '\n' | grep -qx "$architecture" \
        || fail "missing executable architecture: $architecture"
done

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
ZIP_SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
printf '%s  %s\n' "$ZIP_SHA256" "VoiceInk.zip" > "$CHECKSUM_PATH"

cp "$REPO_ROOT/release/voiceink.rb.template" "$CASK_PATH"

printf '%s\n' \
    "Release package created:" \
    "  app: $APP_PATH" \
    "  zip: $ZIP_PATH" \
    "  cask: $CASK_PATH" \
    "  sha256: $ZIP_SHA256"
