import LLMkit
import SwiftUI

struct APIKeyManagementView: View {
    @EnvironmentObject private var aiService: AIService
    @ObservedObject private var customAIProviderManager = CustomAIProviderManager.shared
    @State private var apiKey: String = ""
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var isVerifying = false
    @State private var ollamaBaseURL: String =
        UserDefaults.standard.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434"
    @State private var ollamaModels: [OllamaModel] = []
    @State private var selectedOllamaModel: String =
        UserDefaults.standard.string(forKey: "ollamaSelectedModel") ?? "mistral"
    @State private var isCheckingOllama = false
    @State private var isEditingURL = false
    @State private var localCLICommandTemplate: String = ""
    @State private var localCLITimeoutSeconds: Double = LocalCLIService.defaultTimeoutSeconds
    @State private var localCLIExecutionMode: LocalCLIExecutionMode = .command
    @State private var localCLICodexModels: [CodexModelOption] = []
    @State private var localCLICodexModel: String = ""
    @State private var localCLICodexReasoningEffort: String = LocalCLIService.defaultCodexReasoningEffort
    @State private var isRefreshingCodexModels = false
    @State private var codexAppServerError: String?
    @State private var isSyncingLocalCLIState = false
    @State private var arkModel: String =
        UserDefaults.standard.string(forKey: "Volcengine ArkSelectedModel") ?? ""

    private var providerOptions: [AIProvider] {
        AIProvider.allCases.filter { provider in
            guard provider.supportsEnhancement else { return false }
            if provider == .custom {
                return customAIProviderManager.hasConfiguredModels
            }
            return true
        }
    }

    var body: some View {
        Section("AI Provider Integration") {
            HStack {
                Picker("Provider", selection: $aiService.selectedProvider) {
                    ForEach(providerOptions, id: \.self) { provider in
                        Text(providerTitle(provider)).tag(provider)
                    }
                }
                .pickerStyle(.automatic)
                .tint(AppTheme.Status.infoStrong)

                if aiService.selectedProvider == .localCLI && localCLIExecutionMode == .codexAppServer {
                    Spacer()
                    if isRefreshingCodexModels {
                        ProgressView()
                            .controlSize(.small)
                        Text("Connecting")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else if codexAppServerError != nil {
                        Circle()
                            .fill(AppTheme.Status.error)
                            .frame(width: 8, height: 8)
                        Text("Disconnected")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else if !localCLICodexModels.isEmpty {
                        Circle()
                            .fill(AppTheme.Status.positive)
                            .frame(width: 8, height: 8)
                        Text("Connected")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else if aiService.isAPIKeyValid && aiService.selectedProvider != .ollama {
                    Spacer()
                    Circle()
                        .fill(AppTheme.Status.positive)
                        .frame(width: 8, height: 8)
                    Text("Connected")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else if aiService.selectedProvider == .ollama {
                    Spacer()
                    if isCheckingOllama {
                        ProgressView()
                            .controlSize(.small)
                    } else if !ollamaModels.isEmpty {
                        Circle()
                            .fill(AppTheme.Status.positive)
                            .frame(width: 8, height: 8)
                        Text("Connected")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        Circle()
                            .fill(AppTheme.Status.error)
                            .frame(width: 8, height: 8)
                        Text("Disconnected")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .onAppear {
                syncSelectedProviderAvailability()
                syncSelectedCustomModelIfNeeded()
                syncArkModelIfNeeded()
            }
            .onChange(of: aiService.selectedProvider) { oldValue, newValue in
                if aiService.selectedProvider == .ollama {
                    checkOllamaConnection(showError: false)
                }
                if aiService.selectedProvider == .localCLI {
                    syncLocalCLIStateFromService()
                    refreshCodexModelsIfNeeded()
                }
                syncSelectedCustomModelIfNeeded()
                syncArkModelIfNeeded()
            }
            .onChange(of: customAIProviderManager.providers) { _, _ in
                syncSelectedProviderAvailability()
                syncSelectedCustomModelIfNeeded()
            }

            VStack(alignment: .leading, spacing: 12) {
                // Model Selection
                if aiService.selectedProvider == .ark {
                    TextField("Model or endpoint name (for example, ep-20250520154305-lz8cg)", text: $arkModel)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: arkModel) { _, newValue in
                            let model = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !model.isEmpty {
                                aiService.selectModel(model, for: .ark)
                            }
                        }
                } else if aiService.selectedProvider == .openRouter {
                    if aiService.availableModels.isEmpty {
                        HStack {
                            Text("No models loaded")
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: {
                                Task {
                                    await aiService.fetchOpenRouterModels()
                                }
                            }) {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        }
                    } else {
                        HStack {
                            Picker(
                                "Model",
                                selection: Binding(
                                    get: { aiService.currentModel },
                                    set: { aiService.selectModel($0) }
                                )
                            ) {
                                ForEach(aiService.availableModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }

                            Spacer()

                            Button(action: {
                                Task {
                                    await aiService.fetchOpenRouterModels()
                                }
                            }) {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        }
                    }

                } else if !aiService.availableModels.isEmpty && aiService.selectedProvider != .ollama {
                    Picker(
                        "Model",
                        selection: Binding(
                            get: { aiService.currentModel },
                            set: { aiService.selectModel($0) }
                        )
                    ) {
                        ForEach(aiService.availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }

                if aiService.selectedProvider == .ollama {
                    if isEditingURL {
                        HStack {
                            TextField("Base URL", text: $ollamaBaseURL)
                                .textFieldStyle(.roundedBorder)

                            Button("Save") {
                                aiService.updateOllamaBaseURL(ollamaBaseURL)
                                checkOllamaConnection()
                                isEditingURL = false
                            }
                        }
                    } else {
                        HStack {
                            Text(String(format: String(localized: "Server: %@"), ollamaBaseURL))
                            Spacer()
                            Button("Edit") { isEditingURL = true }
                            Button(action: {
                                ollamaBaseURL = "http://localhost:11434"
                                aiService.updateOllamaBaseURL(ollamaBaseURL)
                                checkOllamaConnection()
                            }) {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            .help("Reset to default")
                        }
                    }

                    if !ollamaModels.isEmpty {
                        Divider()

                        Picker("Model", selection: $selectedOllamaModel) {
                            ForEach(ollamaModels) { model in
                                Text(model.name).tag(model.name)
                            }
                        }
                        .onChange(of: selectedOllamaModel) { oldValue, newValue in
                            aiService.updateSelectedOllamaModel(newValue)
                        }
                    }

                } else if aiService.selectedProvider == .localCLI {
                    HStack {
                        Picker("Execution", selection: $localCLIExecutionMode) {
                            ForEach(LocalCLIExecutionMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: localCLIExecutionMode) { _, newValue in
                            guard !isSyncingLocalCLIState else { return }
                            aiService.updateLocalCLIExecutionMode(newValue)
                            if newValue == .codexAppServer {
                                refreshCodexModels()
                            }
                        }

                        Menu("Load Template") {
                            ForEach(LocalCLITemplate.allCases) { template in
                                Button(template.displayName) {
                                    aiService.loadLocalCLITemplate(template)
                                    syncLocalCLIStateFromService()
                                    refreshCodexModelsIfNeeded()
                                }
                            }
                        }
                    }

                    if localCLIExecutionMode == .codexAppServer {
                        HStack {
                            Picker("Model", selection: $localCLICodexModel) {
                                ForEach(localCLICodexModels) { model in
                                    Text(model.title).tag(model.model)
                                }
                            }
                            .disabled(localCLICodexModels.isEmpty)
                            .onChange(of: localCLICodexModel) { _, newValue in
                                guard !isSyncingLocalCLIState, !newValue.isEmpty else { return }
                                aiService.updateLocalCLICodexModel(newValue, availableModels: localCLICodexModels)
                                syncLocalCLIStateFromService()
                            }

                            Button {
                                refreshCodexModels()
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .disabled(isRefreshingCodexModels)
                        }

                        Picker("Reasoning Effort", selection: $localCLICodexReasoningEffort) {
                            ForEach(selectedCodexModel?.supportedReasoningEfforts ?? [], id: \.self) { effort in
                                Text(effort.capitalized).tag(effort)
                            }
                        }
                        .disabled(selectedCodexModel == nil)
                        .onChange(of: localCLICodexReasoningEffort) { _, newValue in
                            guard !isSyncingLocalCLIState, !newValue.isEmpty else { return }
                            aiService.updateLocalCLICodexReasoningEffort(newValue)
                        }

                        Text("VoiceInk keeps one Codex App Server process running and creates an isolated session for each enhancement. Low reasoning effort is recommended for faster polishing.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if let codexAppServerError {
                            Text(codexAppServerError)
                                .font(.caption)
                                .foregroundColor(AppTheme.Status.error)
                                .textSelection(.enabled)
                        } else if localCLICodexModels.isEmpty && !isRefreshingCodexModels {
                            Text("Refresh the model list to check Codex sign-in and availability.")
                                .font(.caption)
                                .foregroundColor(AppTheme.Status.warningStrong)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Command")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }

                            TextEditor(text: $localCLICommandTemplate)
                                .font(.system(.body, design: .monospaced))
                                .multilineTextAlignment(.leading)
                                .frame(minHeight: 100)
                                .padding(4)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(NSColor.textBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(AppTheme.Border.subtle, lineWidth: 1)
                                )
                                .onChange(of: localCLICommandTemplate) { _, newValue in
                                    guard !isSyncingLocalCLIState else { return }
                                    if newValue != aiService.localCLICommandTemplate {
                                        aiService.updateLocalCLICommandTemplate(newValue)
                                    }
                                }
                        }

                        Text(
                            "Environment variables available: VOICEINK_SYSTEM_PROMPT, VOICEINK_USER_PROMPT, VOICEINK_FULL_PROMPT. VoiceInk also writes VOICEINK_FULL_PROMPT to stdin for every command."
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }

                    Picker("Timeout", selection: $localCLITimeoutSeconds) {
                        Text("15s").tag(15.0)
                        Text("30s").tag(30.0)
                        Text("45s").tag(45.0)
                        Text("60s").tag(60.0)
                        Text("90s").tag(90.0)
                        Text("120s").tag(120.0)
                        Text("180s").tag(180.0)
                        Text("300s").tag(300.0)
                    }
                    .onChange(of: localCLITimeoutSeconds) { _, newValue in
                        aiService.updateLocalCLITimeoutSeconds(newValue)
                    }

                    if !aiService.isAPIKeyValid {
                        Text("Load a template or enter a command to enable Local CLI enhancement.")
                            .font(.caption)
                            .foregroundColor(AppTheme.Status.warningStrong)
                    }
                } else if aiService.selectedProvider == .custom {
                    Text("Manage custom enhancement models in the Custom tab.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    if aiService.isAPIKeyValid {
                        HStack {
                            Text("API Key")
                            Spacer()
                            Text("••••••••")
                                .foregroundColor(.secondary)
                            Button("Remove", role: .destructive) {
                                aiService.clearAPIKey()
                            }
                        }
                    } else {
                        SecureField("API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)

                        HStack {
                            if let url = getAPIKeyURL() {
                                Link(destination: url) {
                                    HStack {
                                        Image(systemName: "key.fill")
                                        Text("Get API Key")
                                    }
                                    .font(.caption)
                                    .foregroundColor(AppTheme.Status.infoStrong)
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 8)
                                    .background(AppTheme.Status.infoStrong.opacity(0.10))
                                    .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }

                            Spacer()

                            Button(action: {
                                isVerifying = true
                                aiService.saveAPIKey(apiKey) { success, errorMessage in
                                    isVerifying = false
                                    if !success {
                                        alertMessage =
                                            errorMessage
                                            ?? String(
                                                localized: "Could not verify this API key. Check the key and try again."
                                            )
                                        showAlert = true
                                    }
                                    apiKey = ""
                                }
                            }) {
                                HStack {
                                    if isVerifying {
                                        ProgressView().controlSize(.small)
                                    }
                                    Text("Verify and Save")
                                }
                            }
                            .disabled(
                                apiKey.isEmpty
                                    || (aiService.selectedProvider == .ark
                                        && arkModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            )
                        }
                    }
                }
            }
        }
        .alert("Error", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .onAppear {
            if aiService.selectedProvider == .ollama {
                checkOllamaConnection(showError: false)
            }
            if aiService.selectedProvider == .localCLI {
                syncLocalCLIStateFromService()
                refreshCodexModelsIfNeeded()
            }
        }
    }

    private func providerTitle(_ provider: AIProvider) -> String {
        provider == .custom ? String(localized: "Custom Models") : provider.rawValue
    }

    private func syncSelectedProviderAvailability() {
        guard !providerOptions.contains(aiService.selectedProvider),
            let fallbackProvider = providerOptions.first
        else {
            return
        }

        aiService.selectedProvider = fallbackProvider
    }

    private func syncSelectedCustomModelIfNeeded() {
        guard aiService.selectedProvider == .custom else { return }

        let models = aiService.availableModels
        if models.contains(aiService.currentModel) {
            aiService.selectModel(aiService.currentModel)
        } else if let defaultModel = models.first {
            aiService.selectModel(defaultModel)
        }
    }

    private func syncArkModelIfNeeded() {
        guard aiService.selectedProvider == .ark else { return }
        arkModel = aiService.selectedModel(for: .ark)
    }

    private func syncLocalCLIStateFromService() {
        isSyncingLocalCLIState = true
        localCLICommandTemplate = aiService.localCLICommandTemplate
        localCLITimeoutSeconds = aiService.localCLITimeoutSeconds
        localCLIExecutionMode = aiService.localCLIExecutionMode
        localCLICodexModel = aiService.localCLICodexModel
        localCLICodexReasoningEffort = aiService.localCLICodexReasoningEffort
        DispatchQueue.main.async {
            isSyncingLocalCLIState = false
        }
    }

    private var selectedCodexModel: CodexModelOption? {
        localCLICodexModels.first { $0.model == localCLICodexModel || $0.id == localCLICodexModel }
    }

    private func refreshCodexModelsIfNeeded() {
        guard localCLIExecutionMode == .codexAppServer else { return }
        refreshCodexModels()
    }

    private func refreshCodexModels() {
        guard !isRefreshingCodexModels else { return }
        isRefreshingCodexModels = true
        codexAppServerError = nil
        Task { @MainActor in
            do {
                localCLICodexModels = try await aiService.fetchLocalCLICodexModels()
                syncLocalCLIStateFromService()
            } catch {
                localCLICodexModels = []
                codexAppServerError = error.localizedDescription
            }
            isRefreshingCodexModels = false
        }
    }

    private func checkOllamaConnection(showError: Bool = true) {
        isCheckingOllama = true
        Task { @MainActor in
            let result = await aiService.refreshOllamaAvailability()

            ollamaModels = result.models
            isCheckingOllama = false

            if let errorMessage = result.errorMessage, showError {
                alertMessage = errorMessage
                showAlert = true
            }
        }
    }

    private func getAPIKeyURL() -> URL? {
        switch aiService.selectedProvider {
        case .groq: return URL(string: "https://console.groq.com/keys")
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .gemini: return URL(string: "https://makersuite.google.com/app/apikey")
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        case .mistral: return URL(string: "https://console.mistral.ai/api-keys")
        case .elevenLabs: return URL(string: "https://elevenlabs.io/speech-synthesis")
        case .deepgram: return URL(string: "https://console.deepgram.com/api-keys")
        case .soniox: return URL(string: "https://console.soniox.com/")
        case .speechmatics: return URL(string: "https://portal.speechmatics.com/manage-access/")
        case .assemblyAI: return URL(string: "https://www.assemblyai.com/dashboard/api-keys")
        case .openRouter: return URL(string: "https://openrouter.ai/keys")
        case .ark: return URL(string: "https://console.volcengine.com/ark/region:ark+cn-beijing/apikey")
        case .cerebras: return URL(string: "https://cloud.cerebras.ai/")
        default: return nil
        }
    }
}
