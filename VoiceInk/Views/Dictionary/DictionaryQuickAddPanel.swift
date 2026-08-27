import AppKit
import os
import SwiftData
import SwiftUI

// MARK: - Manager

@MainActor
final class DictionaryQuickAddManager {
    static let shared = DictionaryQuickAddManager()
    private init() {}

    private var panel: DictionaryQuickAddPanel?
    private var hostingController: NSHostingController<AnyView>?
    private var previousApp: NSRunningApplication?
    private var protectedEditorWorkID: UUID?

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(modelContainer: ModelContainer) {
        isVisible ? hide() : show(modelContainer: modelContainer)
    }

    func show(modelContainer: ModelContainer) {
        guard !isVisible else { return }

        previousApp = NSWorkspace.shared.frontmostApplication
        let usageContext = VocabularyUsageContext(
            bundleIdentifier: previousApp?.bundleIdentifier,
            applicationName: previousApp?.localizedName,
            domain: nil
        )

        let initialSize = NSSize(width: 500, height: DictionaryQuickAddView.Mode.vocabulary.panelHeight)
        let newPanel = DictionaryQuickAddPanel(manager: self, size: initialSize)

        let view = DictionaryQuickAddView(
            initialUsageContext: usageContext,
            onDismiss: { [weak self] in self?.hide() },
            onResize: { [weak self] height in
                self?.panel?.resize(to: NSSize(width: 500, height: height))
            }
        )
        .modelContainer(modelContainer)

        let controller = NSHostingController(rootView: AnyView(view))
        newPanel.contentView = controller.view
        hostingController = controller
        panel = newPanel
        protectedEditorWorkID = RuntimeProtectedWorkActivity.shared.begin()
        newPanel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard panel != nil || protectedEditorWorkID != nil else { return }
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
        if let protectedEditorWorkID {
            RuntimeProtectedWorkActivity.shared.end(protectedEditorWorkID)
            self.protectedEditorWorkID = nil
        }
        previousApp?.activate(options: .activateIgnoringOtherApps)
        previousApp = nil
    }
}

// MARK: - Panel

class DictionaryQuickAddPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private weak var manager: DictionaryQuickAddManager?

    init(manager: DictionaryQuickAddManager, size: NSSize) {
        self.manager = manager
        let origin = DictionaryQuickAddPanel.centeredOrigin(for: size)
        super.init(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovable = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Escape
            manager?.hide()
        } else {
            super.keyDown(with: event)
        }
    }

    override func resignKey() {
        super.resignKey()
        DispatchQueue.main.async { [weak self] in
            self?.manager?.hide()
        }
    }

    func resize(to size: NSSize) {
        let currentFrame = frame
        let x = currentFrame.midX - size.width / 2
        let y = currentFrame.maxY - size.height
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        }
    }

    private static func centeredOrigin(for size: NSSize) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let x = screen.visibleFrame.midX - size.width / 2
        let y = screen.visibleFrame.midY - size.height / 2 + 60
        return NSPoint(x: x, y: y)
    }
}

struct DictionaryQuickAddScopeState: Equatable {
    private(set) var applicationScope: VocabularyScopeSelection?
    private(set) var domainScope: VocabularyScopeSelection?
    private(set) var selectedScope: VocabularyScopeSelection?
    private(set) var hasUserSelection = false

    init(usageContext: VocabularyUsageContext) {
        applicationScope = usageContext.bundleIdentifier.flatMap {
            VocabularyScopeSelection(
                kind: .application,
                identifier: $0,
                displayName: usageContext.applicationName
            )
        }
        domainScope = usageContext.domain.flatMap {
            VocabularyScopeSelection(kind: .domain, identifier: $0)
        }
        selectedScope = domainScope ?? applicationScope
    }

    mutating func select(_ scope: VocabularyScopeSelection?) {
        selectedScope = scope
        hasUserSelection = true
    }

    mutating func applyDetectedDomain(_ value: String?) {
        domainScope = value.flatMap {
            VocabularyScopeSelection(kind: .domain, identifier: $0)
        }
        guard !hasUserSelection else { return }
        selectedScope = domainScope ?? applicationScope
    }
}

struct DictionaryQuickAddPendingSubmissionState: Equatable {
    private(set) var input: String?

    mutating func queue(_ input: String) {
        self.input = input
    }

    mutating func take(isReady: Bool) -> String? {
        guard isReady, let input else { return nil }
        self.input = nil
        return input
    }

    mutating func cancel() {
        input = nil
    }
}

struct DictionaryQuickAddWebsiteLookupState: Equatable {
    private(set) var requestID = 0
    private(set) var isResolving: Bool

    init(isResolving: Bool) {
        self.isResolving = isResolving
    }

    mutating func retry() {
        requestID += 1
        isResolving = true
    }

    func isCurrent(_ requestID: Int) -> Bool {
        isResolving && self.requestID == requestID
    }

    mutating func complete(_ requestID: Int) -> Bool {
        guard isCurrent(requestID) else { return false }
        isResolving = false
        return true
    }

    mutating func cancel() {
        requestID += 1
        isResolving = false
    }
}

// MARK: - View

struct DictionaryQuickAddView: View {
    private static let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "DictionaryQuickAdd"
    )

    enum Mode: CaseIterable {
        case vocabulary, replacement

        var label: LocalizedStringKey {
            switch self {
            case .vocabulary: return "Vocabulary"
            case .replacement: return "Word Replacement"
            }
        }

        var icon: String {
            switch self {
            case .vocabulary: return "character.book.closed.fill"
            case .replacement: return "arrow.2.squarepath"
            }
        }

        var panelHeight: CGFloat {
            switch self {
            case .vocabulary: return 164
            case .replacement: return 164
            }
        }
    }

    @Environment(\.modelContext) private var modelContext
    @Query private var vocabularyWords: [VocabularyWord]
    @Query private var scopedVocabularyWords: [ScopedVocabularyWord]
    @Query private var wordReplacements: [WordReplacement]

    @State private var mode: Mode = .vocabulary
    @State private var wordInput = ""
    @State private var originalInput = ""
    @State private var replacementInput = ""
    @State private var errorMessage: String?
    @State private var scopeState: DictionaryQuickAddScopeState
    @State private var pendingSubmission = DictionaryQuickAddPendingSubmissionState()
    @State private var websiteLookupFailure: BrowserURLFailureGuidance?
    @State private var websiteLookupState: DictionaryQuickAddWebsiteLookupState
    @FocusState private var focusedField: Field?

    enum Field: Hashable { case word, original, replacement }

    let initialUsageContext: VocabularyUsageContext
    let onDismiss: () -> Void
    let onResize: (CGFloat) -> Void

    init(
        initialUsageContext: VocabularyUsageContext,
        onDismiss: @escaping () -> Void,
        onResize: @escaping (CGFloat) -> Void
    ) {
        self.initialUsageContext = initialUsageContext
        self.onDismiss = onDismiss
        self.onResize = onResize
        _scopeState = State(
            initialValue: DictionaryQuickAddScopeState(usageContext: initialUsageContext)
        )
        let waitsForWebsite = initialUsageContext.bundleIdentifier.map { bundleIdentifier in
            BrowserType.allCases.contains {
                $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
            }
        } ?? false
        _websiteLookupState = State(
            initialValue: DictionaryQuickAddWebsiteLookupState(isResolving: waitsForWebsite)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            modeBar
            Divider().opacity(0.4)
            inputArea
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(AppTheme.Status.error)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            Divider().opacity(0.4)
            hintBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AppTheme.Border.tint, lineWidth: 0.5)
        )
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .onAppear {
            DispatchQueue.main.async { focusedField = .word }
        }
        .task(id: websiteLookupState.requestID) {
            await captureCurrentWebsite(requestID: websiteLookupState.requestID)
        }
        .onDisappear {
            websiteLookupState.cancel()
            pendingSubmission.cancel()
        }
        .onChange(of: mode) { _, newMode in
            wordInput = ""
            originalInput = ""
            replacementInput = ""
            pendingSubmission.cancel()
            errorMessage = nil
            DispatchQueue.main.async {
                focusedField = newMode == .vocabulary ? .word : .original
            }
            resizeForCurrentState(mode: newMode)
        }
        .onChange(of: errorMessage) { _, _ in
            resizeForCurrentState()
        }
        .onChange(of: websiteLookupFailure) { _, _ in
            resizeForCurrentState()
        }
    }

    // MARK: - Mode Bar

    private var modeBar: some View {
        HStack(spacing: 4) {
            ForEach(Mode.allCases, id: \.self) { m in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { mode = m }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: m.icon)
                            .font(.system(size: 10, weight: .medium))
                        Text(m.label)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(mode == m ? .primary : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(mode == m ? AppTheme.Selection.fill : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .accessibilityIdentifier("dictionary.quickAdd.entryType")
    }

    // MARK: - Input Area

    @ViewBuilder
    private var inputArea: some View {
        if mode == .vocabulary {
            vocabularyInput
        } else {
            replacementInputView
        }
    }

    private var vocabularyInput: some View {
        VStack(spacing: 8) {
            HStack(spacing: 11) {
                Image(systemName: mode.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                TextField("", text: $wordInput, prompt: Text("e.g. Prakash, VoiceInk").foregroundColor(.secondary))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                    .focused($focusedField, equals: .word)
                    .onSubmit { submitVocabulary() }
            }

            HStack(spacing: 8) {
                Text("Scope")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Menu {
                    Button("Global") { selectVocabularyScope(nil) }
                    if let appScope = currentApplicationScope {
                        Button("Current App · \(appScope.displayName)") {
                            selectVocabularyScope(appScope)
                        }
                    }
                    if let domainScope = currentDomainScope {
                        Button("Current Website · \(domainScope.displayName)") {
                            selectVocabularyScope(domainScope)
                        }
                    }
                    if !existingScopes.isEmpty {
                        Divider()
                        ForEach(existingScopes) { scope in
                            Button(scope.displayName) { selectVocabularyScope(scope) }
                        }
                    }
                } label: {
                    Text(scopeState.selectedScope?.displayName ?? String(localized: "Global"))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .accessibilityIdentifier("dictionary.quickAdd.scope")
                if websiteLookupState.isResolving {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Detecting current website")
                }
            }

            if let websiteLookupFailure {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppTheme.Status.warning)
                    Text(websiteLookupFailure.message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if websiteLookupFailure.shouldOfferAutomationSettings {
                        Button("Settings") {
                            NSWorkspace.shared.open(BrowserURLFailureGuidance.automationSettingsURL)
                        }
                        .buttonStyle(.link)
                    }
                    Button("Retry") {
                        websiteLookupState.retry()
                    }
                    .buttonStyle(.link)
                    .disabled(websiteLookupState.isResolving)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var replacementInputView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text("Replace")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
                TextField("", text: $originalInput, prompt: Text("e.g. my email, my mail").foregroundColor(.secondary))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                    .focused($focusedField, equals: .original)
                    .onSubmit { focusedField = .replacement }
            }

            HStack(spacing: 10) {
                Text("With")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
                TextField(
                    "", text: $replacementInput,
                    prompt: Text("e.g. name@example.com").foregroundColor(.secondary)
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
                .focused($focusedField, equals: .replacement)
                .onSubmit { submitReplacement() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Hint Bar

    private var hintBar: some View {
        HStack {
            Spacer()
            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    KeyHint("↵")
                    Text("Add")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 4) {
                    KeyHint("esc")
                    Text("Dismiss")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func submitVocabulary() {
        let input = wordInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        guard !websiteLookupState.isResolving || scopeState.hasUserSelection else {
            pendingSubmission.queue(input)
            return
        }
        persistVocabulary(input)
    }

    private func persistVocabulary(_ input: String) {
        let scopeKind = scopeState.selectedScope?.kind.rawValue ?? "global"
        Self.logger.notice("Quick add vocabulary submitting scope=\(scopeKind, privacy: .public)")
        let error: String?
        if let selectedVocabularyScope = scopeState.selectedScope {
            error = DictionaryService.addScopedVocabularyWords(
                input,
                scope: selectedVocabularyScope,
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
            errorMessage = error
            return
        }
        onDismiss()
    }

    private func selectVocabularyScope(_ scope: VocabularyScopeSelection?) {
        scopeState.select(scope)
        submitPendingVocabularyIfPossible()
    }

    private func submitPendingVocabularyIfPossible() {
        let isReady = !websiteLookupState.isResolving || scopeState.hasUserSelection
        guard let input = pendingSubmission.take(isReady: isReady) else { return }
        persistVocabulary(input)
    }

    private func captureCurrentWebsite(requestID: Int) async {
        guard let bundleIdentifier = initialUsageContext.bundleIdentifier,
            let browser = BrowserType.allCases.first(where: {
                $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
            })
        else { return }

        guard websiteLookupState.isCurrent(requestID) else { return }
        websiteLookupFailure = nil

        do {
            let url = try await BrowserURLService.shared.getCurrentURL(from: browser)
            guard !Task.isCancelled, websiteLookupState.isCurrent(requestID) else { return }
            let domain = VocabularyDomain.normalizedHost(from: url)
            scopeState.applyDetectedDomain(domain)
            let scopeKind = domain == nil ? "application" : "domain"
            Self.logger.notice("Quick add automatic scope resolved scope=\(scopeKind, privacy: .public)")
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, websiteLookupState.isCurrent(requestID) else { return }
            scopeState.applyDetectedDomain(nil)
            Self.logger.notice("Quick add automatic scope fell back scope=application")
            websiteLookupFailure = BrowserURLFailureGuidance.make(error: error, browser: browser)
        }
        guard websiteLookupState.complete(requestID) else { return }
        submitPendingVocabularyIfPossible()
    }

    private func resizeForCurrentState(mode selectedMode: Mode? = nil) {
        let selectedMode = selectedMode ?? mode
        let validationHeight: CGFloat = errorMessage == nil ? 0 : 24
        let websiteFailureHeight: CGFloat = selectedMode == .vocabulary && websiteLookupFailure != nil ? 46 : 0
        onResize(selectedMode.panelHeight + validationHeight + websiteFailureHeight)
    }

    private var currentApplicationScope: VocabularyScopeSelection? {
        scopeState.applicationScope
    }

    private var currentDomainScope: VocabularyScopeSelection? {
        scopeState.domainScope
    }

    private var existingScopes: [VocabularyScopeSelection] {
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
        return values.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func submitReplacement() {
        let original = originalInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacementInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, !replacement.isEmpty else { return }
        if let error = DictionaryService.addWordReplacement(
            original: original, replacement: replacement, existing: Array(wordReplacements), context: modelContext)
        {
            errorMessage = error
            return
        }
        onDismiss()
    }
}

// MARK: - Key Hint

private struct KeyHint: View {
    let label: LocalizedStringKey
    init(_ label: LocalizedStringKey) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppTheme.Surface.control.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(AppTheme.Border.subtle, lineWidth: 0.5)
                    )
            )
    }
}
