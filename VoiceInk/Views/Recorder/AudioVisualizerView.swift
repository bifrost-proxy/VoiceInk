import SwiftUI

struct AudioVisualizer: View {
    let audioMeter: AudioMeter
    let color: Color
    let isActive: Bool

    init(audioMeter: AudioMeter, color: Color, isActive: Bool) {
        self.audioMeter = audioMeter
        self.color = color
        self.isActive = isActive
    }

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            let heights = AudioVisualizerLayout.barHeights(for: audioMeter, isActive: isActive)
            for (index, height) in heights.enumerated() {
                let rect = CGRect(
                    x: CGFloat(index) * (AudioVisualizerLayout.barWidth + AudioVisualizerLayout.barSpacing),
                    y: (size.height - height) / 2,
                    width: AudioVisualizerLayout.barWidth,
                    height: height
                )
                let path = Path(
                    roundedRect: rect,
                    cornerRadius: AudioVisualizerLayout.barWidth / 2
                )
                context.fill(path, with: .color(color.opacity(isActive ? 0.85 : 0.5)))
            }
        }
        .frame(width: AudioVisualizerLayout.width, height: AudioVisualizerLayout.maxHeight)
        .accessibilityHidden(true)
    }
}

enum AudioVisualizerLayout {
    static let barCount = 15
    static let barWidth: CGFloat = 3
    static let barSpacing: CGFloat = 2
    static let minHeight: CGFloat = 4
    static let maxHeight: CGFloat = 28
    static let width = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing

    static func barHeights(for audioMeter: AudioMeter, isActive: Bool) -> [CGFloat] {
        guard isActive else { return Array(repeating: minHeight, count: barCount) }

        let average = max(0, min(1, audioMeter.averagePower))
        let peak = max(0, min(1, audioMeter.peakPower))
        let amplitude = pow(average * 0.78 + peak * 0.22, 0.72)
        let phase = peak * 5.0

        return (0..<barCount).map { index in
            let centerDistance = abs(Double(index) - Double(barCount - 1) / 2) / Double(barCount / 2)
            let centerBoost = 1.0 - centerDistance * 0.32
            let wave = 0.38 + (sin(Double(index) * 1.17 + phase) * 0.5 + 0.5) * 0.62
            let normalizedHeight = amplitude * wave * centerBoost
            return minHeight + CGFloat(normalizedHeight) * (maxHeight - minHeight)
        }
    }
}

// Flat bars shown when the recorder is idle (no audio input)
struct StaticVisualizer: View {
    let color: Color

    var body: some View {
        AudioVisualizer(
            audioMeter: AudioMeter(averagePower: 0, peakPower: 0),
            color: color,
            isActive: false
        )
    }
}

// MARK: - Processing Status Display

struct ProcessingStatusDisplay: View {
    enum Mode {
        case transcribing
        case enhancing
    }

    let mode: Mode
    let color: Color

    private var label: LocalizedStringKey {
        switch mode {
        case .transcribing: return "Transcribing"
        case .enhancing: return "Enhancing"
        }
    }

    private var animationSpeed: Double {
        switch mode {
        case .transcribing: return 0.18
        case .enhancing: return 0.22
        }
    }

    private var systemImage: String {
        switch mode {
        case .transcribing: return "waveform"
        case .enhancing: return "sparkles"
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Label(label, systemImage: systemImage)
                .foregroundColor(color)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            ProgressAnimation(color: color, animationSpeed: animationSpeed)
        }
        .frame(height: 28)  // matches AudioVisualizer maxHeight to prevent layout shift
    }
}
