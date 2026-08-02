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

## Latest local validation snapshot

The 2026-08-02 validation replayed the 10 most recent recordings through all 6 downloaded realtime-capable models (60 cases). Among cases where the whole-file pseudo-reference was non-empty:

- Nemotron Multilingual: 7/7 realtime finals exactly matched whole-file inference;
- Parakeet CTC zh-CN: 9/9 exact;
- Qwen3-ASR INT8: 8/8 exact, with median first preview reduced from 1.620 s to 0.610 s;
- SenseVoice Small: 6/6 exact;
- Parakeet V3: average raw parity 0.965 across 3 scored cases; most Chinese recordings were unscored because V3 supports English and European languages, not Mandarin;
- Paraformer Large zh: average raw parity 0.786 and identical-input batch repeatability 0.741. Repeating inference and voting was tested, did not produce a reliable net gain, and is intentionally not part of the product path.

Parakeet V2/V3 whole-file inference conditionally appends one second of trailing silence when the recording has no quiet tail. Removing it reduced V3 parity from 0.965 to 0.512 and caused a very short recording to fail with `invalidAudioData`, so the bounded padding is retained. It does not cause a recording-length-dependent final pass.

The detailed private report is stored at:

```text
~/Library/Application Support/com.prakashjoshipax.VoiceInk/Benchmarks/20260802-215748/
```

## Model loading and memory lifetime

The recorder callback is installed before asynchronous local-model initialization finishes, so cold-start PCM chunks queue instead of being discarded. When prewarm-on-wake is enabled, the selected sherpa-onnx/Qwen model now follows the same launch/wake prewarm path as other local runtimes. Its recognizer is reused while active and released after 10 minutes without inference; every preview or batch inference resets that idle timer. This avoids both first-recording initialization delay and indefinite Qwen residency.
