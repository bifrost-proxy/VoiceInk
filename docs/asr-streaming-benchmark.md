# ASR realtime parity benchmark

This opt-in benchmark compares the complete-file result with the result produced by VoiceInk's normal realtime transcription path.

For every selected recording and downloaded realtime-capable local model, it:

1. transcribes the complete WAV file twice to measure identical-input repeatability;
2. uses the first complete-file result as a pseudo-reference;
3. replays the same PCM in real time using 100 ms chunks through `StreamingTranscriptionSession`;
4. records partial previews, first-preview latency, finalization route and latency;
5. compares the normalized batch and realtime outputs;
6. sends both outputs through the current mode's configured AI enhancement flow;
7. writes detailed JSON and Markdown reports.

Run it with:

```bash
scripts/run-asr-streaming-benchmark.sh
```

By default it uses the 10 most recently modified WAV files in the live VoiceInk recordings directory and every downloaded local model whose realtime mode is `nativeStreaming` or `slidingWindow`, including FluidAudio and sherpa-onnx/Qwen models.

The following environment variables can narrow a local run:

- `VOICEINK_BENCHMARK_AUDIO_COUNT`: number of recent recordings;
- `VOICEINK_BENCHMARK_MODELS`: comma-separated model names;
- `VOICEINK_BENCHMARK_RECORDINGS_DIR`: alternative recordings directory;
- `VOICEINK_BENCHMARK_OUTPUT_DIR`: alternative report directory;
- `VOICEINK_BENCHMARK_SKIP_ENHANCEMENT=1`: skip AI enhancement;
- `VOICEINK_BENCHMARK_FAST_REPLAY=1`: replay without real-time delays.

The default reports are private runtime artifacts and are saved under:

```text
~/Library/Application Support/com.prakashjoshipax.VoiceInk/Benchmarks/<timestamp>/
```

The complete-file output is not human-labelled ground truth. The benchmark proves integration parity and exposes preview/finalization regressions, but absolute recognition quality still requires reviewed reference transcripts. Historical screen, clipboard and selected-text context is not retained with recordings, so enhancement comparisons use the current prompt/provider with an empty historical context snapshot.

Sliding-window models treat their incremental hypotheses as previews and refresh only the current bounded, unconfirmed window at stop. Previously finalized windows are not decoded again. Native streaming models finalize their decoder state directly.
