@preconcurrency import CoreML
import Foundation

/// Core ML runtime for FluidInference's Mandarin Parakeet CTC model.
///
/// The exported model has a fixed 15-second tensor shape. Short previews do not
/// wait for 15 seconds: the samples available now are zero-padded and decoded
/// immediately. Longer recordings are handled by VoiceInk's sliding-window
/// provider rather than by a stateful decoder cache.
actor ParakeetCtcZhCnManager {
    static let modelName = "parakeet-ctc-0.6b-zh-cn"
    static let repositoryFolderName = "parakeet-ctc-0.6b-zh-cn-coreml"

    private static let maximumAudioSamples = 240_000
    private static let blankID = 7_000
    private static let sentencePieceBoundary = "▁"

    private let preprocessor: MLModel
    private let encoder: MLModel
    private let decoder: MLModel
    private let vocabulary: [Int: String]

    private init(
        preprocessor: MLModel,
        encoder: MLModel,
        decoder: MLModel,
        vocabulary: [Int: String]
    ) {
        self.preprocessor = preprocessor
        self.encoder = encoder
        self.decoder = decoder
        self.vocabulary = vocabulary
    }

    static func load(from directory: URL) throws -> ParakeetCtcZhCnManager {
        guard ParakeetCtcZhCnModelStore.modelsExist(at: directory) else {
            throw ParakeetCtcZhCnError.incompleteModel(directory)
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        configuration.allowLowPrecisionAccumulationOnGPU = true

        let preprocessor = try MLModel(
            contentsOf: directory.appendingPathComponent("Preprocessor.mlmodelc", isDirectory: true),
            configuration: configuration
        )
        let encoder = try MLModel(
            contentsOf: directory.appendingPathComponent("Encoder-v2-int8.mlmodelc", isDirectory: true),
            configuration: configuration
        )
        let decoder = try MLModel(
            contentsOf: directory.appendingPathComponent("Decoder.mlmodelc", isDirectory: true),
            configuration: configuration
        )
        let vocabulary = try loadVocabulary(
            from: directory.appendingPathComponent("vocab.json")
        )

        return ParakeetCtcZhCnManager(
            preprocessor: preprocessor,
            encoder: encoder,
            decoder: decoder,
            vocabulary: vocabulary
        )
    }

    func transcribe(audio: [Float]) throws -> String {
        guard !audio.isEmpty else { return "" }

        let actualLength = min(audio.count, Self.maximumAudioSamples)
        let audioArray = try MLMultiArray(
            shape: [1, NSNumber(value: Self.maximumAudioSamples)],
            dataType: .float32
        )
        let audioPointer = audioArray.dataPointer.bindMemory(
            to: Float32.self,
            capacity: Self.maximumAudioSamples
        )
        audioPointer.initialize(repeating: 0, count: Self.maximumAudioSamples)
        audio.withUnsafeBufferPointer { source in
            guard let sourceBase = source.baseAddress else { return }
            audioPointer.update(from: sourceBase, count: actualLength)
        }

        let audioLengthArray = try MLMultiArray(shape: [1], dataType: .int32)
        audioLengthArray[0] = NSNumber(value: actualLength)

        let preprocessorInput = try MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": MLFeatureValue(multiArray: audioArray),
            "audio_length": MLFeatureValue(multiArray: audioLengthArray),
        ])
        let preprocessorOutput = try preprocessor.prediction(from: preprocessorInput)
        guard let mel = preprocessorOutput.featureValue(for: "mel")?.multiArrayValue,
            let melLength = preprocessorOutput.featureValue(for: "mel_length")?.multiArrayValue
        else {
            throw ParakeetCtcZhCnError.invalidModelOutput("preprocessor")
        }

        let encoderInput = try MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": MLFeatureValue(multiArray: mel),
            "length": MLFeatureValue(multiArray: melLength),
        ])
        let encoderOutputProvider = try encoder.prediction(from: encoderInput)
        guard let encoderOutput = encoderOutputProvider.featureValue(for: "encoder_output")?.multiArrayValue else {
            throw ParakeetCtcZhCnError.invalidModelOutput("encoder")
        }

        let decoderInput = try MLDictionaryFeatureProvider(dictionary: [
            "encoder_output": MLFeatureValue(multiArray: encoderOutput)
        ])
        let decoderOutput = try decoder.prediction(from: decoderInput)
        guard let logits = decoderOutput.featureValue(for: "ctc_logits")?.multiArrayValue else {
            throw ParakeetCtcZhCnError.invalidModelOutput("decoder")
        }

        return greedyDecode(logits: logits)
    }

    private func greedyDecode(logits: MLMultiArray) -> String {
        guard logits.shape.count == 3 else { return "" }

        let timeSteps = logits.shape[1].intValue
        let vocabularySize = logits.shape[2].intValue
        var previousLabel: Int?
        var text = ""

        for time in 0..<timeSteps {
            var bestValue = -Float.infinity
            var bestLabel = 0

            for label in 0..<vocabularySize {
                let value = logits[[0, NSNumber(value: time), NSNumber(value: label)]].floatValue
                if value > bestValue {
                    bestValue = value
                    bestLabel = label
                }
            }

            if bestLabel != Self.blankID,
                bestLabel != previousLabel,
                let token = vocabulary[bestLabel]
            {
                text += token
            }
            previousLabel = bestLabel
        }

        return Self.detokenize(
            text.replacingOccurrences(of: Self.sentencePieceBoundary, with: " ")
        )
    }

    static func detokenize(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"(?<=[\p{Han}])\s+(?=[\p{Han}])"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s+([，。！？；：、,.!?;:])"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"([，。！？；：、])\s+"#,
                with: "$1",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func loadVocabulary(from url: URL) throws -> [Int: String] {
        let data = try Data(contentsOf: url)

        if let tokens = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return Dictionary(uniqueKeysWithValues: tokens.enumerated().map { ($0.offset, $0.element) })
        }

        if let tokens = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            return Dictionary(uniqueKeysWithValues: tokens.compactMap { key, value in
                Int(key).map { ($0, value) }
            })
        }

        throw ParakeetCtcZhCnError.invalidVocabulary
    }
}

enum ParakeetCtcZhCnModelStore {
    struct Asset: Sendable {
        let path: String
        let byteCount: Int64
    }

    typealias ProgressHandler = @Sendable (_ fraction: Double, _ currentAsset: String) -> Void

    /// Pin the converted artifacts so a future repository update cannot mix
    /// incompatible Core ML bundle files in an existing installation.
    private static let repositoryRevision = "ad0da3a453ce93ae53263f9a757ad365ce90bd58"
    private static let repository = "FluidInference/parakeet-ctc-0.6b-zh-cn-coreml"

    static let assets: [Asset] = [
        Asset(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", byteCount: 243),
        Asset(path: "Preprocessor.mlmodelc/coremldata.bin", byteCount: 502),
        Asset(path: "Preprocessor.mlmodelc/metadata.json", byteCount: 2_827),
        Asset(path: "Preprocessor.mlmodelc/model.mil", byteCount: 27_134),
        Asset(path: "Preprocessor.mlmodelc/weights/weight.bin", byteCount: 807_968),
        Asset(path: "Encoder-v2-int8.mlmodelc/analytics/coremldata.bin", byteCount: 243),
        Asset(path: "Encoder-v2-int8.mlmodelc/coremldata.bin", byteCount: 513),
        Asset(path: "Encoder-v2-int8.mlmodelc/metadata.json", byteCount: 2_943),
        Asset(path: "Encoder-v2-int8.mlmodelc/model.mil", byteCount: 1_098_426),
        Asset(path: "Encoder-v2-int8.mlmodelc/weights/weight.bin", byteCount: 593_429_888),
        Asset(path: "Decoder.mlmodelc/analytics/coremldata.bin", byteCount: 243),
        Asset(path: "Decoder.mlmodelc/coremldata.bin", byteCount: 471),
        Asset(path: "Decoder.mlmodelc/metadata.json", byteCount: 1_850),
        Asset(path: "Decoder.mlmodelc/model.mil", byteCount: 3_610),
        Asset(path: "Decoder.mlmodelc/weights/weight.bin", byteCount: 14_352_242),
        Asset(path: "vocab.json", byteCount: 67_395),
    ]

    static func modelsExist(at directory: URL) -> Bool {
        assets.allSatisfy { asset in
            fileSize(at: directory.appendingPathComponent(asset.path)) == asset.byteCount
        }
    }

    static func download(to directory: URL, progress: ProgressHandler? = nil) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let totalBytes = assets.reduce(Int64.zero) { $0 + $1.byteCount }
        var completedBytes = assets.reduce(Int64.zero) { partial, asset in
            let destination = directory.appendingPathComponent(asset.path)
            return partial + (fileSize(at: destination) == asset.byteCount ? asset.byteCount : 0)
        }
        progress?(Double(completedBytes) / Double(totalBytes), "")

        for asset in assets {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(asset.path)
            if fileSize(at: destination) == asset.byteCount { continue }

            let parent = destination.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            let partial = destination.appendingPathExtension("partial")
            try? fileManager.removeItem(at: partial)

            guard let encodedPath = asset.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                let url = URL(
                    string: "https://huggingface.co/\(repository)/resolve/\(repositoryRevision)/\(encodedPath)"
                )
            else {
                throw ParakeetCtcZhCnError.invalidDownloadURL(asset.path)
            }

            progress?(Double(completedBytes) / Double(totalBytes), asset.path)
            var request = URLRequest(url: url)
            request.timeoutInterval = 300
            let (temporaryURL, response) = try await downloadWithRetry(request: request, asset: asset)
            guard let response = response as? HTTPURLResponse,
                (200..<300).contains(response.statusCode)
            else {
                throw ParakeetCtcZhCnError.invalidDownloadResponse(asset.path)
            }

            try fileManager.moveItem(at: temporaryURL, to: partial)
            guard fileSize(at: partial) == asset.byteCount else {
                try? fileManager.removeItem(at: partial)
                throw ParakeetCtcZhCnError.invalidAssetSize(asset.path)
            }

            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: partial, to: destination)
            completedBytes += asset.byteCount
            progress?(Double(completedBytes) / Double(totalBytes), asset.path)
        }

        guard modelsExist(at: directory) else {
            throw ParakeetCtcZhCnError.incompleteModel(directory)
        }
    }

    private static func downloadWithRetry(
        request: URLRequest,
        asset: Asset,
        attempts: Int = 3
    ) async throws -> (URL, URLResponse) {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                return try await URLSession.shared.download(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard attempt < attempts else { break }
                try await Task.sleep(for: .seconds(attempt))
            }
        }
        throw ParakeetCtcZhCnError.downloadFailed(asset.path, lastError)
    }

    private static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    }
}

enum ParakeetCtcZhCnError: LocalizedError {
    case incompleteModel(URL)
    case invalidModelOutput(String)
    case invalidVocabulary
    case invalidDownloadURL(String)
    case invalidDownloadResponse(String)
    case invalidAssetSize(String)
    case downloadFailed(String, Error?)

    var errorDescription: String? {
        switch self {
        case .incompleteModel(let directory):
            return "Parakeet CTC zh-CN model files are incomplete at \(directory.path)."
        case .invalidModelOutput(let stage):
            return "Parakeet CTC zh-CN returned an invalid \(stage) output."
        case .invalidVocabulary:
            return "Parakeet CTC zh-CN vocabulary is invalid."
        case .invalidDownloadURL(let path):
            return "Could not create the model download URL for \(path)."
        case .invalidDownloadResponse(let path):
            return "The model server returned an invalid response for \(path)."
        case .invalidAssetSize(let path):
            return "The downloaded model file has an unexpected size: \(path)."
        case .downloadFailed(let path, let underlying):
            return "Failed to download \(path): \(underlying?.localizedDescription ?? "unknown error")"
        }
    }
}
