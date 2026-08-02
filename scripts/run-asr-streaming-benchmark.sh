#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"

cd "$repo_dir"

echo "Running the opt-in ASR benchmark against live VoiceInk recordings and downloaded models."
echo "Reports are written outside the repository under VoiceInk's Application Support directory."

xcodebuild test \
  -project VoiceInk.xcodeproj \
  -scheme VoiceInk \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:VoiceInkTests/ASRStreamingBenchmarkTests \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_TESTABILITY=YES \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) VOICEINK_ASR_BENCHMARK'
