#pragma once

// The preparation script downloads the official sherpa-onnx XCFramework here.
// Re-export its C API through a uniquely named SwiftPM C target so it can coexist
// with FluidAudio's static XCFramework module map in the same Xcode target.
#include "../../../Binaries/SherpaOnnxC.xcframework/macos-arm64_x86_64/Headers/c-api.h"
