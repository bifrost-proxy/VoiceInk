# Chinese literary milestones and counting upgrade

Goal: Chinese and English users see familiar Chinese literary works, all four classics, combined two/three/four-book milestones and repeated complete sets, with next-target progress. Chinese counts use Han characters individually and non-Han text uses word segmentation. Counts and progress are language-independent.

Scope: dashboard benchmark/copy, localized count formatting, versioned session counts, backfill, additive sync compatibility and cache invalidation. No ASR, audio, permissions or model changes. No /Applications installation.

Fixed approximate thresholds: 千字文 1,000; 孙子兵法 6,000; 阿Q正传 25,000; 呐喊 80,000; 骆驼祥子 140,000; 围城 250,000; 三国演义 600,000; 西游记 720,000; 红楼梦 850,000; 水浒传 (120 chapters) 900,000. Combinations: 三国+西游 1,320,000; +水浒 2,220,000; +红楼 3,070,000. Further sets are integer multiples of 3,070,000. These are rounded product benchmarks, not exact text editions or English translation lengths. Record source URLs in repository documentation.

Counting: add optional wordCountVersion to SwiftData and sync payload (nil is legacy). New records use version 2. Recompute available completed original/enhanced text before startup retention cleanup, in background batches. Missing text keeps legacy totals and is disclosed in dashboard help. Backfill is idempotent and retryable; incoming legacy sync must not downgrade corrected counts. Completed transcripts are fetched once per batch. Each durable batch reports its IDs to sync even if a later batch fails. Synchronized text changes recount current-version metrics while preserving future count versions. Retention monitoring starts even when backfill fails, honoring the existing cleanup preference; unavailable text retains its legacy estimate. No transcript content added to metric sync. Counts (and existing time estimates derived from counts) may rise for Chinese history; session totals, audio and settings are retained. Additive schema can be read by older releases, but older releases do not understand the new counting convention.

Verification: unit tests all threshold boundaries, sums/repetitions, overflow, Chinese/English/mixed/emoji/punctuation counting, persisted legacy data + idempotent backfill, sync old/new payloads, localized English/Chinese text and real rendered card. Full required VoiceInkTests, focused UI tests, git diff --check; PR dual-architecture CI. Squash merge verified head, tag next SemVer minor (2.4.0 if available), monitor release and Homebrew jobs. Download both published ZIPs and verify SHA256, version/build/bundle ID, Mach-O architectures, ad-hoc signatures and required resources. Rollback with prior release; never rewrite published tags.

## Reference lengths (retrieved 2026-09-05)

These references establish approximate scale; rounded thresholds are deliberately product constants. Electronic editions may count punctuation, prefaces or commentary differently. They are not claims of exact character counts or English translation word counts.

- 千字文: 商务印书馆, 1,000 characters: https://www.cp.com.cn/book/e19d8c0f-2.html
- 孙子兵法: CCTV, approximately 6,000: https://tv.cctv.com/2013/04/03/VIDE1364948463858201.shtml
- 阿Q正传 / 呐喊: literary study, approximately 25,000 plus 13 stories averaging approximately 4,000: https://api.lib.kyushu-u.ac.jp/opac_download_md/5619/slc021p065.pdf
- 骆驼祥子: 人民文学出版社 electronic edition, approximately 136,000: https://read.douban.com/ebook/2928915/
- 围城: approximately 244,000: https://read.douban.com/ebook/472348339/
- 三国演义: 浙江古籍出版社 2018 edition, approximately 593,000: https://read.douban.com/ebook/108117936/
- 西游记: 当当公版电子书, approximately 717,000: https://e.dangdang.com/touch/products/1900018071.html
- 红楼梦: 豆瓣阅读公版电子书, approximately 853,000: https://read.douban.com/ebook/7835788/
- 水浒全传: 120-chapter edition, approximately 896,000: https://www.dedao.cn/ebook/detail?id=BpM1nLOerPa1XOp27zqQ8KGR56loVWrXvnwdLygv94jYmnENDxAMZJBkbNzEblgQ

English titles: Thousand Character Classic; The Art of War; The True Story of Ah Q; Call to Arms; Rickshaw Boy; Fortress Besieged; Romance of the Three Kingdoms; Journey to the West; Dream of the Red Chamber; Water Margin. English UI uses “words / characters” and explicitly describes Chinese-original approximate benchmarks. Chinese compact counts use 万 / 亿; Latin-language compact counts retain K / M.

## Local validation

- Required arm64 `xcodebuild test ... -only-testing:VoiceInkTests -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES`: 453 Swift Testing tests plus 2 XCTest rendering tests; all passed. Parameterized cases cover every milestone boundary and en/zh-Hans/de localization.
- Focused `VoiceInkUITests/testChineseBenchmarkExplanation` and `testEnglishBenchmarkExplanation`: both passed with the project's ad-hoc local signing (`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`). Tests close startup guidance, open the main window, and read the localized estimate popover without granting microphone permissions.
- Eight real SwiftUI card snapshots: empty / 82,200 / three-classic combination / two full sets in Chinese and English, including long-title wrapping at 640-point card width. Chinese and English renders visually inspected.
- Created a physical SQLite/SwiftData statistics store with the unmodified main-branch SessionMetric model, opened it with the new model, and verified record count, word count, duration, mode and persisted version marker. The previous model reopened the upgraded store and retained the count and duration.
- A two-device local iCloud-operation test imports legacy Chinese counts and verifies that a subsequent older-peer update cannot downgrade the corrected count while other fields still synchronize. This uses the real sync engine over a temporary local directory, not live iCloud accounts.
- `make check`, `git diff --check`, and placeholder/translation validation for all 21 new catalog entries passed.
- `scripts/release.sh --version 2.4.0 --architecture arm64 --build-number 1 --output-dir <temporary directory>` successfully built and verified a local ad-hoc arm64 release rehearsal. Published assets are verified separately after the tag workflow.

Existing real-model ASR benchmarks are opt-in and were not run: no ASR behavior changed. This work does not install into /Applications. Historical text that has already been deleted cannot be reconstructed; those metric counts remain explicitly identified as legacy estimates. Original texts, recordings and settings are not rewritten by the count backfill. The fixed typing-speed assumption remains an estimate; corrected Chinese counts can increase the displayed time saved.

## Review follow-up validation

- Added regression coverage for interruption after a committed 500-row page and retry of the remaining row, and for synchronized re-enhancement after a metric already uses count version 2. All three relevant migration/sync tests passed.
- The required full local command after review fixes executed 455 Swift Testing tests plus 2 rendering XCTest tests. Ten existing RecorderOverlayPanel tests failed with 16 visibility assertions while macOS reported `CGSSessionScreenIsLocked=Yes`; the remaining tests passed. The earlier unlocked local run and both original PR architecture jobs passed. The updated commit must pass the full arm64/x86_64 CI again before merge. No local UI re-run is claimed while the desktop is locked.
- Retention startup is unconditional after the backfill attempt. Failed statistics migration cannot disable automatic/zero-retention cleanup for the process lifetime.

## Final recovery and scope checks

- Local history backfill saves an additive optional `wordCountNeedsSync` outbox flag in the same transaction as corrected counts. Sync scans this flag on startup/retry and acknowledges it only after a durable export or an identical existing cloud value. The flag is not part of the sync payload. Remote imports only recount locally, preserving the existing no-echo behavior.
- Duplicate transcriptions use the existing deterministic preferred-row selector. Short-enhancement decisions retain the original NLTokenizer word count, independently of character-based session statistics.
- The final required local full command passed: 457 Swift Testing tests in 37 suites plus 2 XCTest rendering tests, zero failures. This includes duplicate/no-echo sync, short-enhancement segmentation, restart without a backfill notification, and outbox acknowledgement. Earlier intermediate sync regressions were fixed before this passing run.
- The original main-branch physical store was migrated again with the final optional outbox field; nil-to-true persistence and reopening with the original model both passed.

- Final UI verification: English passed in the scoped-menu run; Chinese passed on the observed retry after a transient system SecurityAgent interruption. No keychain or microphone permission was granted. The test scopes the VoiceInk item to the Window menu to avoid hidden namesakes.
