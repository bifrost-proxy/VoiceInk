import Foundation
import Testing
@testable import VoiceInk

struct DoubaoStreamingTests {
    @Test func fullClientRequestUsesDocumentedPCMFormatWithoutCompression() throws {
        let frame = try DoubaoStreamingProtocol.makeFullClientRequest(
            customVocabulary: ["VoiceInk", "豆包"]
        )
        let bytes = [UInt8](frame)

        #expect(Array(bytes.prefix(4)) == [0x11, 0x10, 0x10, 0x00])
        let payloadSize = Int(readUInt32(bytes, offset: 4))
        #expect(payloadSize == bytes.count - 8)

        let payload = Data(bytes[8...])
        let root = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let audio = try #require(root["audio"] as? [String: Any])
        let request = try #require(root["request"] as? [String: Any])
        let user = try #require(root["user"] as? [String: Any])

        #expect(audio["format"] as? String == "pcm")
        #expect(audio["codec"] as? String == "raw")
        #expect(audio["rate"] as? Int == 16_000)
        #expect(audio["bits"] as? Int == 16)
        #expect(audio["channel"] as? Int == 1)
        #expect(request["model_name"] as? String == "bigmodel")
        #expect(request["enable_nonstream"] as? Bool == true)
        #expect(request["show_utterances"] as? Bool == true)
        #expect((user["uid"] as? String)?.hasPrefix("voiceink-") == true)
        #expect(user["did"] == nil)
    }

    @Test func audioFramesMarkOnlyTheCommitAsFinal() {
        let audio = Data([0x01, 0x02, 0x03])
        let regular = [UInt8](DoubaoStreamingProtocol.makeAudioRequest(audio, isFinal: false))
        let final = [UInt8](DoubaoStreamingProtocol.makeAudioRequest(Data(), isFinal: true))

        #expect(Array(regular.prefix(4)) == [0x11, 0x20, 0x00, 0x00])
        #expect(readUInt32(regular, offset: 4) == 3)
        #expect(Array(regular.dropFirst(8)) == [0x01, 0x02, 0x03])
        #expect(Array(final.prefix(4)) == [0x11, 0x22, 0x00, 0x00])
        #expect(readUInt32(final, offset: 4) == 0)
    }

    @Test func finalServerFrameReturnsFullAndStableText() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "result": [
                "text": "你好，VoiceInk。",
                "utterances": [
                    ["text": "你好，", "definite": true],
                    ["text": "VoiceInk。", "definite": false],
                ],
            ]
        ])
        var frame = Data([0x11, 0x93, 0x10, 0x00])
        appendUInt32(3, to: &frame)
        appendUInt32(UInt32(payload.count), to: &frame)
        frame.append(payload)

        let parsedResponse = try DoubaoStreamingProtocol.parseServerFrame(frame)
        let response = try #require(parsedResponse)
        #expect(response.text == "你好，VoiceInk。")
        #expect(response.stableText == "你好，")
        #expect(response.isFinal)
    }

    @Test func serverErrorFramePreservesCodeAndMessage() throws {
        let message = Data("invalid api key".utf8)
        var frame = Data([0x11, 0xF0, 0x10, 0x00])
        appendUInt32(45_000_003, to: &frame)
        appendUInt32(UInt32(message.count), to: &frame)
        frame.append(message)

        #expect(throws: DoubaoStreamingProtocolError.server(code: 45_000_003, message: "invalid api key")) {
            _ = try DoubaoStreamingProtocol.parseServerFrame(frame)
        }
    }

    @Test func doubaoAKAlwaysUsesSystemKeychain() {
        #expect(APIKeyManager.storagePolicy(forProvider: "Doubao Speech") == .keychainOnly)
        #expect(APIKeyManager.storagePolicy(forProvider: "doubao speech") == .keychainOnly)
        #expect(APIKeyManager.storagePolicy(forProvider: "Deepgram") == .standard)
    }

    #if LOCAL_BUILD
        @Test func keychainOnlyStorageRoundTripsInAdHocBuild() {
            let testKey = "doubaoSpeechKeychainTest-\(UUID().uuidString)"
            defer {
                _ = KeychainService.shared.delete(
                    forKey: testKey,
                    storagePolicy: .keychainOnly
                )
            }

            #expect(
                KeychainService.shared.save(
                    "temporary-test-value",
                    forKey: testKey,
                    storagePolicy: .keychainOnly
                )
            )
            #expect(
                KeychainService.shared.getString(
                    forKey: testKey,
                    storagePolicy: .keychainOnly
                ) == "temporary-test-value"
            )
            #expect(
                KeychainService.shared.exists(
                    forKey: testKey,
                    storagePolicy: .keychainOnly
                )
            )
        }
    #endif

    @Test func catalogExposesBothDoubaoTwoPointZeroBillingResources() throws {
        let provider = try #require(CloudProviderRegistry.provider(for: .doubaoSpeech))
        let models = provider.models

        #expect(models.map(\.name) == [
            "volc.seedasr.sauc.duration",
            "volc.seedasr.sauc.concurrent",
        ])
        #expect(models.map(\.supportsStreaming) == [true, true])
        let defaultModel = try #require(models.first)
        #expect(TranscriptionRealtimeSupport.isRequired(for: defaultModel))
    }

    private func readUInt32(_ bytes: [UInt8], offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
