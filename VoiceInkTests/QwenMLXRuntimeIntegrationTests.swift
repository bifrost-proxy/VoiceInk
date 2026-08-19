import Foundation
import FluidAudio
import Testing
@testable import VoiceInk

struct QwenMLXRuntimeIntegrationTests {
    @Test func metalRuntimeStreamsIncrementallyWithMonotonicStableText() async throws {
        let markerURL = QwenMLXPaths.rootDirectory.appendingPathComponent(".run-integration-tests")
        let audioPathURL = QwenMLXPaths.rootDirectory.appendingPathComponent(".integration-test-audio-path")
        guard FileManager.default.fileExists(atPath: markerURL.path),
            let audioPath = try? String(contentsOf: audioPathURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !audioPath.isEmpty
        else {
            return
        }

        let model = try #require(
            TranscriptionModelRegistry.models.first {
                $0.name == "qwen3-asr-0.6b-mlx-int8-streaming"
            } as? QwenMLXModel
        )
        let runtime = QwenMLXRuntime.shared
        let backend = try await runtime.load(model: model)
        #expect(backend.localizedCaseInsensitiveContains("gpu"))

        _ = try await runtime.beginStreaming(
            language: "auto",
            context: "VoiceInk Qwen MLX integration test",
            chunkSizeSeconds: 2,
            maxContextSeconds: 30
        )

        let samples = try AudioConverter(sampleRate: 16_000)
            .resampleAudioFile(URL(fileURLWithPath: audioPath))
        var previousStableText = ""
        var maximumChunksProcessed = 0
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 8_000, samples.count)
            var pcm = samples[offset..<end].map { sample -> Int16 in
                let clamped = max(-1, min(1, sample))
                return Int16(clamped * Float(Int16.max)).littleEndian
            }
            let data = pcm.withUnsafeMutableBytes { buffer in
                Data(bytes: buffer.baseAddress!, count: buffer.count)
            }
            let snapshot = try await runtime.feedAudio(data)
            #expect(snapshot.stableText.hasPrefix(previousStableText))
            previousStableText = snapshot.stableText
            maximumChunksProcessed = max(maximumChunksProcessed, snapshot.chunksProcessed)
            offset = end
        }

        let final = try await runtime.finishStreaming()
        #expect(
            await runtime.releaseResourcesIfUnbound(boundModelNames: [model.name]) == nil
        )
        #expect(
            await runtime.releaseResourcesIfUnbound(boundModelNames: []) == model.name
        )
        #expect(maximumChunksProcessed >= 2)
        #expect(!final.text.isEmpty)
        #expect(final.stableText == final.text)
    }
}
