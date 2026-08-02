import SwiftUI

struct SherpaOnnxModelCardView: View {
    let model: SherpaOnnxModel
    @ObservedObject private var manager = SherpaOnnxModelManager.shared

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text(model.displayName)
                    .font(.system(size: 13, weight: .semibold))

                HStack(spacing: 12) {
                    ModelLanguageSupportButton(model: model)
                    Label(model.size, systemImage: "internaldrive")
                    Text("本地 · sherpa-onnx")
                }
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabelColor))

                Text(model.description)
                    .font(.system(size: 11))
                    .foregroundColor(Color(.secondaryLabelColor))

                if let status = manager.downloadStatuses[model.name] {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(status.message)
                            Spacer()
                            Text(status.fractionCompleted, format: .percent.precision(.fractionLength(0)))
                                .fontDesign(.monospaced)
                        }
                        ProgressView(value: status.fractionCompleted)
                    }
                    .font(.system(size: 11))
                    .padding(.top, 5)
                }

                if let error = manager.errors[model.name] {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actions
        }
        .padding(16)
        .background(AppMaterialCardBackground())
    }

    @ViewBuilder
    private var actions: some View {
        let downloaded = manager.isDownloaded(model)
        let downloading = manager.isDownloading(model)
        HStack(spacing: 8) {
            if downloaded && !downloading {
                modelStatusPill("Downloaded", systemImage: "checkmark.circle")
                Menu {
                    Button(role: .destructive) { manager.delete(model) } label: {
                        Label("Delete Model", systemImage: "trash")
                    }
                    Button { manager.showInFinder(model) } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20, height: 20)
            } else {
                Button {
                    Task { await manager.download(model) }
                } label: {
                    Label(downloading ? "Downloading..." : "Download", systemImage: "arrow.down.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(AppTheme.Accent.primary))
                }
                .buttonStyle(.plain)
                .disabled(downloading)
            }
        }
    }
}
