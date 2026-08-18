#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION=""
OUTPUT_DIR="${VOICEINK_RELEASE_OUTPUT_DIR:-$REPO_ROOT/build/release}"

usage() {
    printf '%s\n' \
        "Usage: scripts/generate-release-metadata.sh --version <MAJOR.MINOR.PATCH> [--output-dir DIR]" \
        "" \
        "Requires VoiceInk-arm64.zip and VoiceInk-x86_64.zip, then creates SHA256SUMS and voiceink.rb."
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
for command_name in awk grep ruby sed shasum; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done

OUTPUT_DIR="$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)"
ARM64_ZIP_PATH="$OUTPUT_DIR/VoiceInk-arm64.zip"
X86_64_ZIP_PATH="$OUTPUT_DIR/VoiceInk-x86_64.zip"
CHECKSUM_PATH="$OUTPUT_DIR/SHA256SUMS"
CASK_PATH="$OUTPUT_DIR/voiceink.rb"

[[ -f "$ARM64_ZIP_PATH" ]] || fail "missing release archive: $ARM64_ZIP_PATH"
[[ -f "$X86_64_ZIP_PATH" ]] || fail "missing release archive: $X86_64_ZIP_PATH"

ARM64_SHA256="$(shasum -a 256 "$ARM64_ZIP_PATH" | awk '{print $1}')"
X86_64_SHA256="$(shasum -a 256 "$X86_64_ZIP_PATH" | awk '{print $1}')"
printf '%s  %s\n%s  %s\n' \
    "$ARM64_SHA256" "VoiceInk-arm64.zip" \
    "$X86_64_SHA256" "VoiceInk-x86_64.zip" > "$CHECKSUM_PATH"

sed \
    -e "s/__VERSION__/$VERSION/g" \
    -e "s/__ARM64_SHA256__/$ARM64_SHA256/g" \
    -e "s/__X86_64_SHA256__/$X86_64_SHA256/g" \
    "$REPO_ROOT/release/voiceink.rb.template" > "$CASK_PATH"

ruby -c "$CASK_PATH" >/dev/null
grep -Fq "version \"$VERSION\"" "$CASK_PATH" \
    || fail "generated cask does not contain release version"
grep -Fq "arm:   \"$ARM64_SHA256\"" "$CASK_PATH" \
    || fail "generated cask does not contain arm64 checksum"
grep -Fq "intel: \"$X86_64_SHA256\"" "$CASK_PATH" \
    || fail "generated cask does not contain x86_64 checksum"
grep -Fq 'releases/download/v#{version}/VoiceInk-#{arch}.zip' "$CASK_PATH" \
    || fail "generated cask does not use an architecture-specific release URL"
grep -Fq 'com.apple.quarantine' "$CASK_PATH" \
    || fail "generated cask does not remove the quarantine attribute"

printf '%s\n' \
    "Release metadata created:" \
    "  cask: $CASK_PATH" \
    "  checksums: $CHECKSUM_PATH"
