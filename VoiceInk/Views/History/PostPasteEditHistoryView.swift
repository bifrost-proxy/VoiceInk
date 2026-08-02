import SwiftUI

struct PostPasteEditHistoryView: View {
    let transcription: Transcription

    private var records: [TranscriptionEditRecord] {
        transcription.postPasteEditRecords
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: records.isEmpty ? "text.cursor" : "pencil.and.list.clipboard")
                    .foregroundColor(records.isEmpty ? .secondary : AppTheme.Selection.foreground)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Post-paste Editing")
                        .font(.system(size: 13, weight: .semibold))

                    if let status = transcription.pasteTrackingStatusValue {
                        Text(status.displayName)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if !records.isEmpty {
                    Text(String(format: String(localized: "%lld changes"), Int64(records.count)))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(AppTheme.Surface.control))
                }
            }

            destinationSummary

            ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                editRecord(record, number: index + 1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                .fill(AppTheme.Surface.materialCard)
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                        .strokeBorder(AppTheme.Border.card, lineWidth: 1)
                }
        )
    }

    @ViewBuilder
    private var destinationSummary: some View {
        if transcription.pasteTargetApplicationName != nil || transcription.pasteTargetWindowTitle != nil {
            VStack(alignment: .leading, spacing: 3) {
                if let appName = transcription.pasteTargetApplicationName {
                    Label(appName, systemImage: "macwindow")
                }
                if let windowTitle = transcription.pasteTargetWindowTitle, !windowTitle.isEmpty {
                    Label(windowTitle, systemImage: "rectangle.topthird.inset.filled")
                }
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .textSelection(.enabled)
        }
    }

    private func editRecord(_ record: TranscriptionEditRecord, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(format: String(localized: "Edit %lld"), Int64(number)))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(record.timestamp, format: .dateTime.hour().minute().second())
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            if !record.removedText.isEmpty {
                changeLine(
                    title: "Removed",
                    text: record.removedText,
                    systemImage: "minus.circle.fill",
                    color: AppTheme.Status.error
                )
            }

            if !record.insertedText.isEmpty {
                changeLine(
                    title: "Added",
                    text: record.insertedText,
                    systemImage: "plus.circle.fill",
                    color: AppTheme.Status.success
                )
            }

            DisclosureGroup("Text after this edit") {
                Text(record.resultingText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.secondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                .fill(AppTheme.Surface.subtle)
        )
    }

    private func changeLine(
        title: LocalizedStringKey,
        text: String,
        systemImage: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10))
                .foregroundColor(color)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }
}
