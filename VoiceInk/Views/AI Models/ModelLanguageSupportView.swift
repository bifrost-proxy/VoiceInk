import Foundation
import SwiftUI

struct ModelLanguageSupportEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let code: String?
}

struct ModelLanguageSupportSection: Identifiable, Equatable {
    let id: String
    let title: String?
    let entries: [ModelLanguageSupportEntry]
}

enum ModelLanguageSupportCatalog {
    static func sections(for model: any TranscriptionModel) -> [ModelLanguageSupportSection] {
        let languageEntries = model.supportedLanguages
            .filter { $0.key != "auto" }
            .map { code, fallbackName in
                ModelLanguageSupportEntry(
                    id: "language-\(code)",
                    name: localizedLanguageName(code: code, fallback: fallbackName),
                    code: code
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        var sections = [
            ModelLanguageSupportSection(
                id: "languages",
                title: model.name == "qwen3-asr-0.6b-int8" ? String(localized: "Languages") : nil,
                entries: languageEntries
            )
        ]

        if model.name == "qwen3-asr-0.6b-int8" {
            sections.append(
                ModelLanguageSupportSection(
                    id: "dialects",
                    title: String(localized: "Chinese Dialects"),
                    entries: qwen3DialectEntries
                )
            )
        }

        return sections.filter { !$0.entries.isEmpty }
    }

    static func languageCount(for model: any TranscriptionModel) -> Int {
        sections(for: model).reduce(0) { $0 + $1.entries.count }
    }

    private static func localizedLanguageName(code: String, fallback: String) -> String {
        Locale.current.localizedString(forIdentifier: code)
            ?? Locale.current.localizedString(forLanguageCode: code)
            ?? fallback
    }

    private static var qwen3DialectEntries: [ModelLanguageSupportEntry] {
        let usesChinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        let dialects: [(String, String, String)] = [
            ("anhui", "安徽话", "Anhui"),
            ("dongbei", "东北话", "Dongbei"),
            ("fujian", "福建话", "Fujian"),
            ("gansu", "甘肃话", "Gansu"),
            ("guizhou", "贵州话", "Guizhou"),
            ("hebei", "河北话", "Hebei"),
            ("henan", "河南话", "Henan"),
            ("hubei", "湖北话", "Hubei"),
            ("hunan", "湖南话", "Hunan"),
            ("jiangxi", "江西话", "Jiangxi"),
            ("ningxia", "宁夏话", "Ningxia"),
            ("shandong", "山东话", "Shandong"),
            ("shaanxi", "陕西话", "Shaanxi"),
            ("shanxi", "山西话", "Shanxi"),
            ("sichuan", "四川话", "Sichuan"),
            ("tianjin", "天津话", "Tianjin"),
            ("yunnan", "云南话", "Yunnan"),
            ("zhejiang", "浙江话", "Zhejiang"),
            ("cantonese-hk", "香港粤语", "Cantonese (Hong Kong accent)"),
            ("cantonese-gd", "广东粤语", "Cantonese (Guangdong accent)"),
            ("wu", "吴语", "Wu language"),
            ("minnan", "闽南语", "Minnan language"),
        ]
        return dialects.map { id, chineseName, englishName in
            ModelLanguageSupportEntry(
                id: "dialect-\(id)",
                name: usesChinese ? chineseName : englishName,
                code: nil
            )
        }
    }
}

struct ModelLanguageSupportButton: View {
    let model: any TranscriptionModel
    @State private var isPresentingDetails = false

    var body: some View {
        Button {
            isPresentingDetails = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                Text(model.language)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11))
            .foregroundColor(Color(.secondaryLabelColor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "View all supported languages"))
        .accessibilityLabel(
            String(
                format: String(localized: "%@, view all supported languages"),
                model.language
            )
        )
        .sheet(isPresented: $isPresentingDetails) {
            ModelLanguageSupportSheet(model: model)
        }
    }
}

private struct ModelLanguageSupportSheet: View {
    let model: any TranscriptionModel
    @Environment(\.dismiss) private var dismiss

    private var sections: [ModelLanguageSupportSection] {
        ModelLanguageSupportCatalog.sections(for: model)
    }

    private var languageCount: Int {
        ModelLanguageSupportCatalog.languageCount(for: model)
    }

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Supported Languages")
                        .font(.system(size: 18, weight: .semibold))
                    Text(model.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(String(format: String(localized: "%lld languages and dialects"), languageCount))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color(.quaternarySystemFill)))
                }
                .buttonStyle(.plain)
                .help("Done")
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.supportedLanguages["auto"] != nil {
                        Label("Automatic language detection is supported", systemImage: "sparkles")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.accentColor.opacity(0.08))
                            )
                    }

                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            if let title = section.title {
                                Text(title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }

                            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                                ForEach(section.entries) { entry in
                                    HStack(spacing: 8) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.accentColor)
                                        Text(entry.name)
                                            .lineLimit(1)
                                        Spacer(minLength: 4)
                                        if let code = entry.code {
                                            Text(code)
                                                .font(.system(size: 9, design: .monospaced))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .font(.system(size: 11))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 7)
                                            .fill(Color(.quaternarySystemFill))
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 540, height: 560)
    }
}
