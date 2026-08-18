import AVFoundation
import Foundation

enum StatefulAudioResamplerError: Error {
    case unsupportedFormat
    case conversionFailed
}

/// A recording-lifetime sample-rate converter. Keeping one AVAudioConverter
/// across callbacks preserves its fractional phase and prevents per-buffer
/// rounding drift.
final class StatefulAudioResampler {
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let inputBuffer: AVAudioPCMBuffer
    private let outputBuffer: AVAudioPCMBuffer

    init(
        inputSampleRate: Double,
        outputSampleRate: Double = 16_000,
        maximumInputFrames: AVAudioFrameCount = 4_096
    ) throws {
        guard inputSampleRate > 0, outputSampleRate > 0,
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputSampleRate,
                channels: 1,
                interleaved: false
            ),
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: outputSampleRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
            let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: maximumInputFrames
            )
        else {
            throw StatefulAudioResamplerError.unsupportedFormat
        }

        let outputCapacity = AVAudioFrameCount(
            ceil(Double(maximumInputFrames) * outputSampleRate / inputSampleRate)
        ) + 256
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: max(outputCapacity, 256)
        ) else {
            throw StatefulAudioResamplerError.unsupportedFormat
        }

        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
        self.inputBuffer = inputBuffer
        self.outputBuffer = outputBuffer
    }

    var inputSampleRate: Double { inputFormat.sampleRate }
    var outputSampleRate: Double { outputFormat.sampleRate }

    func convert(
        interleavedSamples: UnsafePointer<Float32>,
        frameCount: UInt32,
        channelCount: UInt32
    ) throws -> Data {
        guard frameCount > 0, channelCount > 0,
            frameCount <= inputBuffer.frameCapacity,
            let monoSamples = inputBuffer.floatChannelData?[0]
        else {
            throw StatefulAudioResamplerError.unsupportedFormat
        }

        inputBuffer.frameLength = frameCount
        for frame in 0..<Int(frameCount) {
            var mono: Float32 = 0
            for channel in 0..<Int(channelCount) {
                mono += interleavedSamples[frame * Int(channelCount) + channel]
            }
            monoSamples[frame] = mono / Float32(channelCount)
        }

        return try convertBuffer(endOfStream: false)
    }

    /// Drains converter delay at recording stop. The converter must not be
    /// reused after this call.
    func finish() throws -> Data {
        try convertBuffer(endOfStream: true)
    }

    private func convertBuffer(endOfStream: Bool) throws -> Data {
        outputBuffer.frameLength = 0
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) {
            [inputBuffer] _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            suppliedInput = true
            if endOfStream {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        if conversionError != nil || status == .error {
            throw conversionError ?? StatefulAudioResamplerError.conversionFailed
        }
        guard outputBuffer.frameLength > 0,
            let outputSamples = outputBuffer.int16ChannelData?[0]
        else {
            return Data()
        }
        return Data(
            bytes: outputSamples,
            count: Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        )
    }
}
