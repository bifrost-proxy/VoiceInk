import SwiftData
import SwiftUI

enum VocabularySortMode: String {
    case wordAsc = "wordAsc"
    case wordDesc = "wordDesc"
}

private enum VocabularySection: String, CaseIterable {
    case global
    case scoped

    var title: LocalizedStringKey {
        switch self {
        case .global: "Global"
        case .scoped: "Apps & Websites"
        }
    }
}

struct VocabularyView: View {
    @Query private var vocabularyWords: [VocabularyWord]
    @Query private var scopedVocabularyWords: [ScopedVocabularyWord]
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @ObservedObject private var warmupStore = ModeFormWarmupStore.shared

    @State private var section: VocabularySection = .global
    @State private var newWord = ""
    @State private var selectedScope: VocabularyScopeSelection?
    @State private var domainInput = ""
    @State private var isAddingDomain = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var sortMode: VocabularySortMode = .wordAsc

    init() {
        if let savedSort = UserDefaults.standard.string(forKey: "vocabularySortMode"),
            let mode = VocabularySortMode(rawValue: savedSort)
        {
            _sortMode = State(initialValue: mode)
        }
    }

    private var sortedGlobalItems: [VocabularyWord] {
        vocabularyWords.sorted { lhs, rhs in
            let result = lhs.word.localizedCaseInsensitiveCompare(rhs.word)
            return sortMode == .wordAsc ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private var scopes: [VocabularyScopeSelection] {
        var values: [String: VocabularyScopeSelection] = [:]
        for item in scopedVocabularyWords {
            guard let kind = item.scopeKind,
                let scope = VocabularyScopeSelection(
                    kind: kind,
                    identifier: item.scopeIdentifier,
                    displayName: item.scopeDisplayName
                )
            else { continue }
            values[scope.id] = scope
        }
        if let selectedScope { values[selectedScope.id] = selectedScope }
        return values.values.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .application }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private var selectedScopedItems: [ScopedVocabularyWord] {
        guard let selectedScope else { return [] }
        return scopedVocabularyWords.filter {
            $0.scopeKind == selectedScope.kind
                && DictionaryService.normalizedScopeIdentifier(
                    $0.scopeIdentifier,
                    kind: selectedScope.kind
                ) == selectedScope.identifier
        }
        .sorted { $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Vocabulary Scope", selection: $section) {
                ForEach(VocabularySection.allCases, id: \.self) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)

            switch section {
            case .global:
                globalContent
            case .scoped:
                scopedContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("Vocabulary", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .onAppear {
            warmupStore.loadInstalledAppsIfNeeded()
            if selectedScope == nil { selectedScope = scopes.first }
        }
    }

    private var globalContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            vocabularyInput(scope: nil)

            if !vocabularyWords.isEmpty {
                Button(action: toggleSort) {
                    HStack(spacing: 4) {
                        Text(String(localized: "Vocabulary Words (\(vocabularyWords.count))"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        Image(systemName: sortMode == .wordAsc ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)

                FlowLayout(spacing: 8) {
                    ForEach(sortedGlobalItems) { item in
                        VocabularyTermChip(term: item.word) { removeGlobalWord(item) }
                    }
                }
            }
        }
    }

    private var scopedContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                scopeMenu

                if selectedScope != nil, !selectedScopedItems.isEmpty {
                    Menu {
                        Button("Move Words to Global") { moveSelectedScopeToGlobal() }
                        Button("Delete Scope", role: .destructive) { deleteSelectedScope() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .help("Scope actions")
                }
            }

            if isAddingDomain { domainInputRow }

            if let selectedScope {
                vocabularyInput(scope: selectedScope)
                vocabularyPreview(for: selectedScope)

                if selectedScopedItems.isEmpty {
                    Text("No dedicated vocabulary for this scope yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    FlowLayout(spacing: 8) {
                        ForEach(selectedScopedItems) { item in
                            VocabularyTermChip(term: item.word) { removeScopedWord(item) }
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Scoped Vocabulary",
                    systemImage: "app.badge",
                    description: Text("Choose an application or website, then add its dedicated words.")
                )
                .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
    }

    private var scopeMenu: some View {
        Menu {
            if !scopes.isEmpty {
                ForEach(scopes) { scope in
                    Button {
                        selectedScope = scope
                    } label: {
                        Label(scope.displayName, systemImage: scope.kind == .application ? "app" : "globe")
                    }
                }
                Divider()
            }

            Menu("Add Application") {
                if warmupStore.isLoadingInstalledApps && warmupStore.installedApps.isEmpty {
                    Text("Loading applications…")
                }
                ForEach(warmupStore.installedApps, id: \.bundleId) { app in
                    Button(app.name) {
                        selectedScope = VocabularyScopeSelection(
                            kind: .application,
                            identifier: app.bundleId,
                            displayName: app.name
                        )
                    }
                }
            }
            Button("Add Website…") { isAddingDomain = true }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: selectedScope?.kind == .application ? "app" : "globe")
                Text(selectedScope?.displayName ?? String(localized: "Choose an app or website"))
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: 360)
            .background(AppCardBackground(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var domainInputRow: some View {
        HStack(spacing: 8) {
            TextField("example.com", text: $domainInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addDomainScope)
            Button("Add", action: addDomainScope)
                .disabled(VocabularyDomain.normalizedHost(from: domainInput) == nil)
            Button("Cancel") {
                isAddingDomain = false
                domainInput = ""
            }
        }
        .frame(maxWidth: 520)
    }

    private func vocabularyInput(scope: VocabularyScopeSelection?) -> some View {
        HStack(spacing: 8) {
            TextField(
                "",
                text: $newWord,
                prompt: Text(scope == nil ? "Add global vocabulary" : "Add dedicated vocabulary")
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13))
            .onSubmit { addWords(scope: scope) }

            if !newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                AddIconButton(
                    helpText: "Add word",
                    isDisabled: false,
                    action: { addWords(scope: scope) }
                )
            }
        }
        .frame(maxWidth: 620)
    }

    @ViewBuilder
    private func vocabularyPreview(for scope: VocabularyScopeSelection) -> some View {
        if let configuration = ModeRuntimeResolver.transcriptionConfiguration(
            mode: previewMode(for: scope),
            transcriptionModelManager: transcriptionModelManager
        ) {
            let usageContext = VocabularyUsageContext(
                bundleIdentifier: scope.kind == .application ? scope.identifier : nil,
                applicationName: scope.kind == .application ? scope.displayName : nil,
                domain: scope.kind == .domain ? scope.identifier : nil
            )
            let resolved = TranscriptionVocabularyContext.resolve(
                from: modelContext,
                usageContext: usageContext,
                model: configuration.model
            )
            HStack(spacing: 6) {
                Image(systemName: resolved.omittedCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(resolved.omittedCount > 0 ? AppTheme.Status.warning : AppTheme.Status.success)
                if !TranscriptionVocabularyCapability.supportsVocabulary(for: configuration.model) {
                    Text("\(configuration.model.displayName) does not accept vocabulary directly")
                } else if let maximumCount = resolved.maximumCount {
                    Text("\(configuration.model.displayName): \(resolved.terms.count)/\(maximumCount) words used")
                } else {
                    Text("\(configuration.model.displayName): \(resolved.terms.count) words used")
                }
                if resolved.omittedCount > 0 {
                    Text("· \(resolved.omittedCount) lower-priority words omitted")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func previewMode(for scope: VocabularyScopeSelection) -> ModeConfig? {
        let matchedMode: ModeConfig?
        switch scope.kind {
        case .application:
            matchedMode = ModeManager.shared.getConfigurationForApp(scope.identifier)
        case .domain:
            matchedMode = ModeManager.shared.getConfigurationForURL(scope.identifier)
        }
        return matchedMode
            ?? ModeManager.shared.getDefaultConfiguration()
            ?? ModeManager.shared.currentEffectiveConfiguration
    }

    private func addWords(scope: VocabularyScopeSelection?) {
        let input = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        let error: String?
        if let scope {
            error = DictionaryService.addScopedVocabularyWords(
                input,
                scope: scope,
                existing: Array(scopedVocabularyWords),
                context: modelContext
            )
        } else {
            error = DictionaryService.addVocabularyWords(
                input,
                existing: Array(vocabularyWords),
                context: modelContext
            )
        }
        if let error {
            alertMessage = error
            showAlert = true
        } else {
            newWord = ""
        }
    }

    private func addDomainScope() {
        guard let host = VocabularyDomain.normalizedHost(from: domainInput),
            let scope = VocabularyScopeSelection(kind: .domain, identifier: host, displayName: host)
        else { return }
        selectedScope = scope
        domainInput = ""
        isAddingDomain = false
    }

    private func toggleSort() {
        sortMode = (sortMode == .wordAsc) ? .wordDesc : .wordAsc
        UserDefaults.standard.set(sortMode.rawValue, forKey: "vocabularySortMode")
    }

    private func removeGlobalWord(_ word: VocabularyWord) {
        deleteAndSave(word, failureMessage: "Failed to remove word")
    }

    private func removeScopedWord(_ word: ScopedVocabularyWord) {
        deleteAndSave(word, failureMessage: "Failed to remove scoped word")
    }

    private func deleteAndSave<T: PersistentModel>(_ item: T, failureMessage: String) {
        modelContext.delete(item)
        saveOrRollback(failureMessage: failureMessage)
    }

    private func deleteSelectedScope() {
        selectedScopedItems.forEach { modelContext.delete($0) }
        if saveOrRollback(failureMessage: "Failed to delete vocabulary scope") {
            selectedScope = scopes.first { $0.id != selectedScope?.id }
        }
    }

    private func moveSelectedScopeToGlobal() {
        var existingKeys = Set(vocabularyWords.map { TranscriptionVocabularyContext.normalizedKey($0.word) })
        for item in selectedScopedItems {
            let key = TranscriptionVocabularyContext.normalizedKey(item.word)
            if existingKeys.insert(key).inserted {
                modelContext.insert(VocabularyWord(word: item.word, dateAdded: item.dateAdded))
            }
            modelContext.delete(item)
        }
        if saveOrRollback(failureMessage: "Failed to move vocabulary") {
            selectedScope = scopes.first { $0.id != selectedScope?.id }
        }
    }

    @discardableResult
    private func saveOrRollback(failureMessage: String) -> Bool {
        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .portableConfigurationDidChange, object: nil)
            return true
        } catch {
            modelContext.rollback()
            alertMessage = "\(failureMessage): \(error.localizedDescription)"
            showAlert = true
            return false
        }
    }
}

private struct VocabularyTermChip: View {
    let term: String
    let onDelete: () -> Void
    @State private var isDeleteHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(term)
                .font(.system(size: 13))
                .lineLimit(1)
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isDeleteHovered ? AppTheme.Status.error : .secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove word")
            .onHover { isDeleteHovered = $0 }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(AppCardBackground(cornerRadius: 6))
    }
}
