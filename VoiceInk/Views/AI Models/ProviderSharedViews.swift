import AppKit
import SwiftUI

struct ProviderBrandIcon: View {
    let descriptor: ProviderDescriptor
    let fallbackSystemImage: String
    let isSelected: Bool
    let size: CGFloat
    let iconSize: CGFloat

    private var hasBrandAsset: Bool {
        descriptor.brandAssetName != nil
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(7, size * 0.25))
                .fill(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: max(7, size * 0.25))
                        .stroke(borderColor, lineWidth: 1)
                )

            if let assetName = descriptor.brandAssetName {
                Image(assetName)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .padding(size * 0.24)
            } else {
                Image(systemName: fallbackSystemImage)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(isSelected ? AppTheme.Accent.primary : Color.secondary)
            }
        }
        .frame(width: size, height: size)
    }

    private var backgroundColor: Color {
        if hasBrandAsset {
            return Color.white.opacity(isSelected ? 0.96 : 0.9)
        }
        return AppTheme.Surface.control
    }

    private var borderColor: Color {
        if isSelected {
            return AppTheme.Accent.border
        }
        return AppTheme.Border.control.opacity(hasBrandAsset ? 0.45 : 0.2)
    }
}

struct ProviderSectionHeader: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ProviderConfigurationGroup<Content: View>: View {
    let title: LocalizedStringKey
    let content: () -> Content

    init(title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            content()
        }
    }
}

struct ProviderModelListSection<Content: View>: View {
    let title: LocalizedStringKey
    let content: () -> Content

    init(title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(ProviderSurface(cornerRadius: 10))
        }
    }
}

struct ProviderSurface: View {
    var isActive: Bool = false
    var cornerRadius: CGFloat = 10

    var body: some View {
        AppMaterialCardBackground(isSelected: isActive, cornerRadius: cornerRadius)
    }
}

struct ProviderStatusBadge: View {
    let title: LocalizedStringKey
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct ModelRealtimeCapabilityBadge: View {
    let model: any TranscriptionModel

    private var mode: TranscriptionRealtimeMode {
        TranscriptionRealtimeSupport.mode(for: model)
    }

    private var title: LocalizedStringKey {
        switch mode {
        case .nativeStreaming:
            return "Native streaming"
        case .slidingWindow:
            return "Realtime · sliding window"
        case .batchOnly:
            return "Batch transcription"
        }
    }

    private var systemImage: String {
        switch mode {
        case .nativeStreaming:
            return "waveform"
        case .slidingWindow:
            return "rectangle.stack"
        case .batchOnly:
            return "doc.text"
        }
    }

    private var color: Color {
        switch mode {
        case .nativeStreaming:
            return AppTheme.Status.positive
        case .slidingWindow:
            return .orange
        case .batchOnly:
            return .secondary
        }
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().stroke(color.opacity(0.25), lineWidth: 0.5))
            .fixedSize(horizontal: true, vertical: false)
            .help(helpText)
    }

    private var helpText: String {
        switch mode {
        case .nativeStreaming:
            return String(localized: "Consumes audio incrementally through the model runtime's streaming path.")
        case .slidingWindow:
            return String(localized: "Shows realtime previews by repeatedly transcribing a bounded audio window; encoder state is not preserved between updates.")
        case .batchOnly:
            return String(localized: "Transcribes the complete recording after recording stops.")
        }
    }
}
