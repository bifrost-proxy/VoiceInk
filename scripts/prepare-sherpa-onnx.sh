#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
package_root="$repo_root/Dependencies/SherpaOnnxMac"
binaries_dir="$package_root/Binaries"
sherpa_target="$binaries_dir/SherpaOnnxC.xcframework"
onnx_target="$binaries_dir/OnnxRuntimeMacOS.xcframework"

normalize_frameworks() {
    local sherpa_framework="$1"
    local onnx_framework="$2"
    local framework
    local version_a

    # FluidAudio already contributes a static framework module map with this path.
    find "$sherpa_framework" -name module.modulemap -delete

    # The upstream ZIP expands framework symlinks into duplicate directories. Rebuild the
    # canonical macOS framework layout so Xcode can locate and validate Resources/Info.plist.
    framework="$(find "$onnx_framework" -type d -name onnxruntime.framework -print -quit)"
    [[ -n "$framework" ]] || { echo "onnxruntime.framework not found" >&2; exit 1; }
    if [[ -L "$framework/Versions/Current" && -L "$framework/onnxruntime" ]]; then
        return
    fi

    version_a="$framework/Versions/A"
    mkdir -p "$version_a"
    for item in Headers Modules Resources onnxruntime; do
        if [[ ! -e "$version_a/$item" && -e "$framework/$item" ]]; then
            mv "$framework/$item" "$version_a/$item"
        fi
        [[ -e "$version_a/$item" ]] || { echo "missing ONNX framework item: $item" >&2; exit 1; }
        rm -rf "$framework/$item"
    done
    rm -rf "$framework/Versions/Current"
    ln -s A "$framework/Versions/Current"
    for item in Headers Modules Resources onnxruntime; do
        ln -s "Versions/Current/$item" "$framework/$item"
    done
}

if [[ -d "$sherpa_target" && -d "$onnx_target" ]]; then
    normalize_frameworks "$sherpa_target" "$onnx_target"
    exit 0
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

sherpa_url="https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.4/sherpa-onnx-v1.13.4-macos.xcframework.zip"
onnx_url="https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.27.1/onnxruntime-macos-shared-xcframework-1.27.1.xcframework.zip"
sherpa_sha="4325d8aed99b94be58969005b19f9626f3f3afc4ebd42378b0aad2b84e233552"
onnx_sha="9d1d49b7c5ba7d5ccff048aff3f0c40431f8232b67259df9ab7f85d76e57cb75"

mkdir -p "$binaries_dir"
curl -fL --retry 3 -o "$work_dir/sherpa.zip" "$sherpa_url"
curl -fL --retry 3 -o "$work_dir/onnx.zip" "$onnx_url"

actual_sherpa_sha="$(shasum -a 256 "$work_dir/sherpa.zip" | awk '{print $1}')"
actual_onnx_sha="$(shasum -a 256 "$work_dir/onnx.zip" | awk '{print $1}')"
[[ "$actual_sherpa_sha" == "$sherpa_sha" ]] || { echo "sherpa-onnx checksum mismatch" >&2; exit 1; }
[[ "$actual_onnx_sha" == "$onnx_sha" ]] || { echo "ONNX Runtime checksum mismatch" >&2; exit 1; }

unzip -q "$work_dir/sherpa.zip" -d "$work_dir/sherpa"
unzip -q "$work_dir/onnx.zip" -d "$work_dir/onnx"

normalize_frameworks \
    "$work_dir/sherpa/sherpa-onnx.xcframework" \
    "$work_dir/onnx/onnxruntime.xcframework"
rm -rf "$sherpa_target" "$onnx_target"
mv "$work_dir/sherpa/sherpa-onnx.xcframework" "$sherpa_target"
mv "$work_dir/onnx/onnxruntime.xcframework" "$onnx_target"
