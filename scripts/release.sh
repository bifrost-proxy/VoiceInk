#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/VoiceInk.xcodeproj"
SCHEME="VoiceInk"
LOCAL_CONFIG="$REPO_ROOT/LocalBuild.xcconfig"
LOCAL_ENTITLEMENTS="$REPO_ROOT/VoiceInk/VoiceInk.local.entitlements"
EXPECTED_BUNDLE_ID="com.prakashjoshipax.VoiceInk"
ARCHITECTURES=(arm64 x86_64)
REQUESTED_ARCHITECTURE="all"
VERSION=""
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
OUTPUT_DIR="${VOICEINK_RELEASE_OUTPUT_DIR:-$REPO_ROOT/build/release}"

usage() {
    printf '%s\n' \
        "Usage: scripts/release.sh --version <MAJOR.MINOR.PATCH> [--architecture arm64|x86_64|all] [--build-number N] [--output-dir DIR]" \
        "" \
        "Builds one or both ad-hoc-signed VoiceInk architectures and packages one ZIP per architecture." \
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
        --architecture)
            [[ $# -ge 2 ]] || fail "--architecture requires a value"
            REQUESTED_ARCHITECTURE="$2"
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
case "$REQUESTED_ARCHITECTURE" in
    all) ARCHITECTURES=(arm64 x86_64) ;;
    arm64|x86_64) ARCHITECTURES=("$REQUESTED_ARCHITECTURE") ;;
    *) fail "architecture must be arm64, x86_64, or all" ;;
esac

for command_name in awk chmod codesign cp curl ditto file find grep lipo make mv plutil sed shasum stat tr unzip xcodebuild; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done

if [[ -d "/Applications/Xcode_26.5.app/Contents/Developer" && -z "${DEVELOPER_DIR:-}" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode_26.5.app/Contents/Developer"
elif [[ -d "/Applications/Xcode.app/Contents/Developer" && -z "${DEVELOPER_DIR:-}" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

OUTPUT_DIR="$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)"
# shellcheck disable=SC2016
SWIFT_BUILD_CONDITIONS='$(inherited) LOCAL_BUILD'

for architecture in "${ARCHITECTURES[@]}"; do
    rm -rf "$OUTPUT_DIR/DerivedData-$architecture"
    rm -f "$OUTPUT_DIR/VoiceInk-$architecture.zip"
done
if [[ "$REQUESTED_ARCHITECTURE" == "all" ]]; then
    rm -f "$OUTPUT_DIR/voiceink.rb" "$OUTPUT_DIR/SHA256SUMS"
fi

make -C "$REPO_ROOT" whisper
"$REPO_ROOT/scripts/prepare-sherpa-onnx.sh"

verify_ad_hoc_signature() {
    local code_path="$1"
    local signature_details
    signature_details="$(codesign --display --verbose=4 "$code_path" 2>&1)"
    grep -Fq "Signature=adhoc" <<<"$signature_details" \
        || fail "expected ad-hoc signature: $code_path"
    grep -Fq "TeamIdentifier=not set" <<<"$signature_details" \
        || fail "unexpected Team ID in ad-hoc release: $code_path"
}

verify_app_architecture() {
    local app_path="$1"
    local expected_architecture="$2"
    local binary_path
    local binary_architectures
    local file_type

    while IFS= read -r -d '' binary_path; do
        file_type="$(file -b "$binary_path")"
        case "$file_type" in
            Mach-O*)
                binary_architectures="$(lipo -archs "$binary_path")"
                [[ "$binary_architectures" == "$expected_architecture" ]] \
                    || fail "unexpected architectures in $binary_path: $binary_architectures (expected only $expected_architecture)"
                ;;
        esac
    done < <(find "$app_path" -type f -print0)
}

thin_app_architecture() {
    local app_path="$1"
    local expected_architecture="$2"
    local binary_path
    local binary_architectures
    local file_type
    local original_mode
    local thin_path

    while IFS= read -r -d '' binary_path; do
        file_type="$(file -b "$binary_path")"
        case "$file_type" in
            Mach-O*)
                binary_architectures="$(lipo -archs "$binary_path")"
                if [[ "$binary_architectures" != "$expected_architecture" ]]; then
                    tr ' ' '\n' <<<"$binary_architectures" | grep -qx "$expected_architecture" \
                        || fail "missing $expected_architecture slice in $binary_path: $binary_architectures"
                    original_mode="$(stat -f '%Lp' "$binary_path")"
                    thin_path="$binary_path.thin"
                    lipo "$binary_path" -thin "$expected_architecture" -output "$thin_path"
                    chmod "$original_mode" "$thin_path"
                    mv -f "$thin_path" "$binary_path"
                fi
                ;;
        esac
    done < <(find "$app_path" -type f -print0)
}

build_architecture() {
    local architecture="$1"
    local derived_data="$OUTPUT_DIR/DerivedData-$architecture"
    local app_path="$derived_data/Build/Products/Release/VoiceInk.app"
    local zip_path="$OUTPUT_DIR/VoiceInk-$architecture.zip"
    local info_plist="$app_path/Contents/Info.plist"
    local executable="$app_path/Contents/MacOS/VoiceInk"
    local app_version
    local app_build
    local app_bundle_id
    local zip_sha256

    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -derivedDataPath "$derived_data" \
        -xcconfig "$LOCAL_CONFIG" \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=YES \
        DEVELOPMENT_TEAM="" \
        CODE_SIGN_ENTITLEMENTS="$LOCAL_ENTITLEMENTS" \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS="$SWIFT_BUILD_CONDITIONS" \
        ARCHS="$architecture" \
        ONLY_ACTIVE_ARCH=NO \
        MARKETING_VERSION="$VERSION" \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        build

    [[ -d "$app_path" ]] || fail "built app not found: $app_path"
    [[ -f "$info_plist" ]] || fail "app Info.plist not found: $info_plist"
    [[ -x "$executable" ]] || fail "app executable not found: $executable"

    thin_app_architecture "$app_path" "$architecture"
    codesign --force --deep --sign - --entitlements "$LOCAL_ENTITLEMENTS" "$app_path"
    codesign --verify --deep --strict --verbose=2 "$app_path"
    verify_ad_hoc_signature "$app_path"
    while IFS= read -r framework_path; do
        verify_ad_hoc_signature "$framework_path"
    done < <(find "$app_path/Contents/Frameworks" -type d -name "*.framework" -prune -print)

    app_version="$(plutil -extract CFBundleShortVersionString raw "$info_plist")"
    app_build="$(plutil -extract CFBundleVersion raw "$info_plist")"
    app_bundle_id="$(plutil -extract CFBundleIdentifier raw "$info_plist")"
    [[ "$app_version" == "$VERSION" ]] || fail "app version $app_version does not match $VERSION"
    [[ "$app_build" == "$BUILD_NUMBER" ]] || fail "app build $app_build does not match $BUILD_NUMBER"
    [[ "$app_bundle_id" == "$EXPECTED_BUNDLE_ID" ]] || fail "unexpected bundle id: $app_bundle_id"
    verify_app_architecture "$app_path" "$architecture"

    ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"
    zip_sha256="$(shasum -a 256 "$zip_path" | awk '{print $1}')"
    printf '%s\n' \
        "Release package created:" \
        "  architecture: $architecture" \
        "  zip: $zip_path" \
        "  sha256: $zip_sha256"
}

for architecture in "${ARCHITECTURES[@]}"; do
    build_architecture "$architecture"
done

if [[ "$REQUESTED_ARCHITECTURE" == "all" ]]; then
    "$REPO_ROOT/scripts/generate-release-metadata.sh" \
        --version "$VERSION" \
        --output-dir "$OUTPUT_DIR"
fi
