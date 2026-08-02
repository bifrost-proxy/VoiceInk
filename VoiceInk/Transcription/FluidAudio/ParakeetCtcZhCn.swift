@preconcurrency import CoreML
import FluidAudio
import Foundation

struct ParakeetCtcZhCnModels: @unchecked Sendable {
    let preprocessor: MLModel
    let encoder: MLModel
    let decoder: MLModel
    let vocabulary: [Int: String]

    static let blankID = 7000
    private static let repositoryBase =
        "https://huggingface.co/FluidInference/parakeet-ctc-0.6b-zh-cn-coreml/resolve/main"

    private static let requiredFiles: [(path: String, size: Int64)] = [
        ("Preprocessor.mlmodelc/analytics/coremldata.bin", 243),
        ("Preprocessor.mlmodelc/coremldata.bin", 502),
        ("Preprocessor.mlmodelc/metadata.json", 2_827),
        ("Preprocessor.mlmodelc/model.mil", 27_134),
        ("Preprocessor.mlmodelc/weights/weight.bin", 807_968),
        ("Encoder-v2-int8.mlmodelc/analytics/coremldata.bin", 243),
        ("Encoder-v2-int8.mlmodelc/coremldata.bin", 513),
        ("Encoder-v2-int8.mlmodelc/metadata.json", 2_943),
        ("Encoder-v2-int8.mlmodelc/model.mil", 1_098_426),
        ("Encoder-v2-int8.mlmodelc/weights/weight.bin", 593_429_888),
        ("Decoder.mlmodelc/analytics/coremldata.bin", 243),
        ("Decoder.mlmodelc/coremldata.bin", 471),
        ("Decoder.mlmodelc/metadata.json", 1_850),
        ("Decoder.mlmodelc/model.mil", 3_610),
        ("Decoder.mlmodelc/weights/weight.bin", 14_352_242),
        ("vocab.json", 67_395),
    ]

    static func modelsExist(at directory: URL) -> Bool {
        requiredFiles.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.path).path)
        }
    }

    static func download(
        to directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let totalBytes = requiredFiles.reduce(Int64(0)) { $0 + $1.size }
        var completedBytes: Int64 = 0

        for file in requiredFiles {
            let destination = directory.appendingPathComponent(file.path)
            if fileManager.fileExists(atPath: destination.path) {
                completedBytes += file.size
                progress(Double(completedBytes) / Double(totalBytes))
                continue
            }

            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let encodedPath = file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                let url = URL(string: "\(repositoryBase)/\(encodedPath)?download=true")
            else {
                throw URLError(.badURL)
            }
            let (temporaryURL, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            try fileManager.moveItem(at: temporaryURL, to: destination)
            completedBytes += file.size
            progress(Double(completedBytes) / Double(totalBytes))
        }
    }

    static func load(from directory: URL) throws -> Self {
        guard modelsExist(at: directory) else {
            throw ASRError.processingFailed("Parakeet CTC zh-CN model files are incomplete")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let vocabularyData = try Data(contentsOf: directory.appendingPathComponent("vocab.json"))
        let tokens = try JSONDecoder().decode([String].self, from: vocabularyData)
        let vocabulary = Dictionary(uniqueKeysWithValues: tokens.enumerated().map { ($0.offset, $0.element) })
        return Self(
            preprocessor: try MLModel(
                contentsOf: directory.appendingPathComponent("Preprocessor.mlmodelc"),
                configuration: configuration),
            encoder: try MLModel(
                contentsOf: directory.appendingPathComponent("Encoder-v2-int8.mlmodelc"),
                configuration: configuration),
            decoder: try MLModel(
                contentsOf: directory.appendingPathComponent("Decoder.mlmodelc"),
                configuration: configuration),
            vocabulary: vocabulary
        )
    }
}

actor ParakeetCtcZhCnManager {
    private let models: ParakeetCtcZhCnModels
    private let maxAudioSamples = 240_000

    init(models: ParakeetCtcZhCnModels) {
        self.models = models
    }

    func transcribe(audioURL: URL) throws -> String {
        let samples = try AudioConverter(sampleRate: 16_000).resampleAudioFile(audioURL)
        var audio = Array(samples.prefix(maxAudioSamples))
        if audio.count < maxAudioSamples {
            audio += [Float](repeating: 0, count: maxAudioSamples - audio.count)
        }

        let audioArray = try MLMultiArray(shape: [1, maxAudioSamples as NSNumber], dataType: .float32)
        let audioPointer = audioArray.dataPointer.assumingMemoryBound(to: Float32.self)
        audio.withUnsafeBufferPointer { source in
            audioPointer.update(from: source.baseAddress!, count: audio.count)
        }
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: min(samples.count, maxAudioSamples))

        let preprocessorInput = try MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": MLFeatureValue(multiArray: audioArray),
            "audio_length": MLFeatureValue(multiArray: length),
        ])
        let preprocessorOutput = try models.preprocessor.prediction(from: preprocessorInput)
        guard let mel = preprocessorOutput.featureValue(for: "mel")?.multiArrayValue,
            let melLength = preprocessorOutput.featureValue(for: "mel_length")?.multiArrayValue
        else { throw ASRError.processingFailed("Parakeet preprocessor returned invalid output") }

        let encoderInput = try MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": MLFeatureValue(multiArray: mel),
            "length": MLFeatureValue(multiArray: melLength),
        ])
        let encoderOutput = try models.encoder.prediction(from: encoderInput)
        guard let encoded = encoderOutput.featureValue(for: "encoder_output")?.multiArrayValue else {
            throw ASRError.processingFailed("Parakeet encoder returned invalid output")
        }

        let decoderInput = try MLDictionaryFeatureProvider(dictionary: [
            "encoder_output": MLFeatureValue(multiArray: encoded)
        ])
        let decoderOutput = try models.decoder.prediction(from: decoderInput)
        guard let logits = decoderOutput.featureValue(for: "ctc_logits")?.multiArrayValue else {
            throw ASRError.processingFailed("Parakeet decoder returned invalid output")
        }

        let timeSteps = logits.shape[1].intValue
        let vocabularySize = logits.shape[2].intValue
        var result = ""
        var previous = -1
        for time in 0..<timeSteps {
            var best = 0
            var bestValue = -Float.infinity
            for token in 0..<vocabularySize {
                let value = logits[[0, time as NSNumber, token as NSNumber]].floatValue
                if value > bestValue {
                    bestValue = value
                    best = token
                }
            }
            if best != ParakeetCtcZhCnModels.blankID, best != previous,
                let token = models.vocabulary[best]
            {
                result += token
            }
            previous = best
        }
        return result.replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
