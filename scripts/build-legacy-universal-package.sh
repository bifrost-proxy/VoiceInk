#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_ENTITLEMENTS="$REPO_ROOT/VoiceInk/VoiceInk.local.entitlements"
EXPECTED_BUNDLE_ID="com.prakashjoshipax.VoiceInk"
VERSION=""
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
OUTPUT_DIR="${VOICEINK_RELEASE_OUTPUT_DIR:-$REPO_ROOT/build/release}"

usage() {
    printf '%s\n' \
        "Usage: scripts/build-legacy-universal-package.sh --version <MAJOR.MINOR.PATCH> [--build-number N] [--output-dir DIR]" \
        "" \
        "Merges VoiceInk-arm64.zip and VoiceInk-x86_64.zip into the one-time legacy VoiceInk.zip updater bridge."
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
for command_name in assetutil awk chmod cmp codesign ditto file find grep lipo mktemp mv plutil readlink sed shasum sort stat tr; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done

OUTPUT_DIR="$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)"
ARM64_ZIP_PATH="$OUTPUT_DIR/VoiceInk-arm64.zip"
X86_64_ZIP_PATH="$OUTPUT_DIR/VoiceInk-x86_64.zip"
LEGACY_ZIP_PATH="$OUTPUT_DIR/VoiceInk.zip"
WORK_DIR="$(mktemp -d "$OUTPUT_DIR/.legacy-universal.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

[[ -f "$ARM64_ZIP_PATH" ]] || fail "missing release archive: $ARM64_ZIP_PATH"
[[ -f "$X86_64_ZIP_PATH" ]] || fail "missing release archive: $X86_64_ZIP_PATH"

ARM64_ROOT="$WORK_DIR/arm64"
X86_64_ROOT="$WORK_DIR/x86_64"
UNIVERSAL_ROOT="$WORK_DIR/universal"
mkdir -p "$ARM64_ROOT" "$X86_64_ROOT" "$UNIVERSAL_ROOT"
ditto -x -k "$ARM64_ZIP_PATH" "$ARM64_ROOT"
ditto -x -k "$X86_64_ZIP_PATH" "$X86_64_ROOT"

ARM64_APP="$ARM64_ROOT/VoiceInk.app"
X86_64_APP="$X86_64_ROOT/VoiceInk.app"
UNIVERSAL_APP="$UNIVERSAL_ROOT/VoiceInk.app"
[[ -d "$ARM64_APP" ]] || fail "arm64 archive does not contain VoiceInk.app"
[[ -d "$X86_64_APP" ]] || fail "x86_64 archive does not contain VoiceInk.app"

find "$ARM64_APP" \( -type f -o -type l \) -print \
    | sed "s|^$ARM64_APP/||" \
    | sort > "$WORK_DIR/arm64-files"
find "$X86_64_APP" \( -type f -o -type l \) -print \
    | sed "s|^$X86_64_APP/||" \
    | sort > "$WORK_DIR/x86_64-files"
cmp -s "$WORK_DIR/arm64-files" "$WORK_DIR/x86_64-files" \
    || fail "architecture-specific apps do not contain the same file layout"

while IFS= read -r -d '' arm64_link; do
    relative_path="${arm64_link#"$ARM64_APP/"}"
    x86_64_link="$X86_64_APP/$relative_path"
    [[ -L "$x86_64_link" ]] || fail "missing x86_64 symlink: $relative_path"
    [[ "$(readlink "$arm64_link")" == "$(readlink "$x86_64_link")" ]] \
        || fail "architecture-specific symlink targets differ: $relative_path"
done < <(find "$ARM64_APP" -type l -print0)

ditto "$ARM64_APP" "$UNIVERSAL_APP"

while IFS= read -r -d '' arm64_file; do
    relative_path="${arm64_file#"$ARM64_APP/"}"
    x86_64_file="$X86_64_APP/$relative_path"
    universal_file="$UNIVERSAL_APP/$relative_path"
    arm64_type="$(file -b "$arm64_file")"
    x86_64_type="$(file -b "$x86_64_file")"

    case "$arm64_type" in
        Mach-O*)
            case "$x86_64_type" in
                Mach-O*) ;;
                *) fail "x86_64 counterpart is not Mach-O: $relative_path" ;;
            esac
            [[ "$(lipo -archs "$arm64_file")" == "arm64" ]] \
                || fail "arm64 input contains unexpected architectures: $relative_path"
            [[ "$(lipo -archs "$x86_64_file")" == "x86_64" ]] \
                || fail "x86_64 input contains unexpected architectures: $relative_path"

            original_mode="$(stat -f '%Lp' "$universal_file")"
            merged_file="$universal_file.universal"
            lipo -create "$arm64_file" "$x86_64_file" -output "$merged_file"
            chmod "$original_mode" "$merged_file"
            mv -f "$merged_file" "$universal_file"
            ;;
        *)
            case "$relative_path" in
                */_CodeSignature/*) ;;
                Contents/Resources/Metadata.appintents/version.json)
                    cmp -s \
                        <(plutil -convert xml1 -o - "$arm64_file") \
                        <(plutil -convert xml1 -o - "$x86_64_file") \
                        || fail "App Intents metadata differs semantically between architectures"
                    ;;
                Contents/Resources/Assets.car)
                    cmp -s \
                        <(assetutil --info "$arm64_file" | sed -E '/"(Timestamp|RenditionName|SHA1Digest)"[[:space:]]*:/d') \
                        <(assetutil --info "$x86_64_file" | sed -E '/"(Timestamp|RenditionName|SHA1Digest)"[[:space:]]*:/d') \
                        || fail "asset catalogs differ semantically between architectures"
                    ;;
                *)
                    cmp -s "$arm64_file" "$x86_64_file" \
                        || fail "architecture-independent files differ: $relative_path"
                    ;;
            esac
            ;;
    esac
done < <(find "$ARM64_APP" -type f -print0)

codesign --force --deep --sign - --entitlements "$LOCAL_ENTITLEMENTS" "$UNIVERSAL_APP"
codesign --verify --deep --strict --verbose=2 "$UNIVERSAL_APP"

INFO_PLIST="$UNIVERSAL_APP/Contents/Info.plist"
EXECUTABLE="$UNIVERSAL_APP/Contents/MacOS/VoiceInk"
[[ -f "$INFO_PLIST" ]] || fail "legacy app Info.plist not found"
[[ -x "$EXECUTABLE" ]] || fail "legacy app executable not found"
APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
APP_BUILD="$(plutil -extract CFBundleVersion raw "$INFO_PLIST")"
APP_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$INFO_PLIST")"
[[ "$APP_VERSION" == "$VERSION" ]] || fail "app version $APP_VERSION does not match $VERSION"
[[ "$APP_BUILD" == "$BUILD_NUMBER" ]] || fail "app build $APP_BUILD does not match $BUILD_NUMBER"
[[ "$APP_BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || fail "unexpected bundle id: $APP_BUNDLE_ID"

while IFS= read -r -d '' binary_path; do
    case "$(file -b "$binary_path")" in
        Mach-O*)
            architectures="$(lipo -archs "$binary_path" | tr ' ' '\n' | sort | tr '\n' ' ')"
            [[ "$architectures" == "arm64 x86_64 " ]] \
                || fail "legacy bridge is not exactly arm64 + x86_64: $binary_path ($architectures)"
            ;;
    esac
done < <(find "$UNIVERSAL_APP" -type f -print0)

signature_details="$(codesign --display --verbose=4 "$UNIVERSAL_APP" 2>&1)"
grep -Fq "Signature=adhoc" <<<"$signature_details" \
    || fail "expected ad-hoc signature on legacy app"
grep -Fq "TeamIdentifier=not set" <<<"$signature_details" \
    || fail "unexpected Team ID on legacy app"

rm -f "$LEGACY_ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$UNIVERSAL_APP" "$LEGACY_ZIP_PATH"
LEGACY_SHA256="$(shasum -a 256 "$LEGACY_ZIP_PATH" | awk '{print $1}')"

printf '%s\n' \
    "Legacy updater bridge package created:" \
    "  zip: $LEGACY_ZIP_PATH" \
    "  architectures: arm64 x86_64" \
    "  sha256: $LEGACY_SHA256"
