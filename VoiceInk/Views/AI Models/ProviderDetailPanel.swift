import AppKit
import SwiftUI

struct ProviderDetailPanel: View {
    let descriptor: ProviderDescriptor
    let onClose: () -> Void

    @EnvironmentObject private var aiService: AIService
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager

    @State private var apiKey = ""
    @State private var isVerifying = false
    @State private var isRefreshingOpenRouterModels = false
    @State private var verificationMessage: String?
    @State private var verificationDetailMessage: String?
    @State private var verificationSucceeded = false
    @State private var isShowingRemoveAPIKeyConfirmation = false
    @State private var activeDescriptorID = ""
    @State private var arkModel = ""
    @State private var apiKeyDraftWorkID: UUID?
    @AppStorage(DoubaoSpeechSettings.Keys.enableTwoPassRecognition)
    private var doubaoEnableTwoPassRecognition = DoubaoSpeechSettings.defaults.enableTwoPassRecognition
    @AppStorage(DoubaoSpeechSettings.Keys.enableTextNormalization)
    private var doubaoEnableTextNormalization = DoubaoSpeechSettings.defaults.enableTextNormalization
    @AppStorage(DoubaoSpeechSettings.Keys.enablePunctuation)
    private var doubaoEnablePunctuation = DoubaoSpeechSettings.defaults.enablePunctuation
    @AppStorage(DoubaoSpeechSettings.Keys.enableSemanticSmoothing)
    private var doubaoEnableSemanticSmoothing = DoubaoSpeechSettings.defaults.enableSemanticSmoothing
    @AppStorage(DoubaoSpeechSettings.Keys.enableFirstTextAcceleration)
    private var doubaoEnableFirstTextAcceleration = DoubaoSpeechSettings.defaults.enableFirstTextAcceleration
    @AppStorage(DoubaoSpeechSettings.Keys.firstTextAccelerationLevel)
    private var doubaoFirstTextAccelerationLevel = DoubaoSpeechSettings.defaults.firstTextAccelerationLevel
    @AppStorage(DoubaoSpeechSettings.Keys.silenceFinalizationMilliseconds)
    private var doubaoSilenceFinalizationMilliseconds =
        DoubaoSpeechSettings.defaults.silenceFinalizationMilliseconds
    @AppStorage(DoubaoSpeechSettings.Keys.enablePOIFunctionCall)
    private var doubaoEnablePOIFunctionCall = DoubaoSpeechSettings.defaults.enablePOIFunctionCall
    @AppStorage(DoubaoSpeechSettings.Keys.poiCityName)
    private var doubaoPOICityName = DoubaoSpeechSettings.defaults.poiCityName
    @AppStorage(DoubaoSpeechSettings.Keys.enableMusicFunctionCall)
    private var doubaoEnableMusicFunctionCall = DoubaoSpeechSettings.defaults.enableMusicFunctionCall
    @AppStorage(DoubaoSpeechSettings.Keys.contextPrompt)
    private var doubaoContextPrompt = DoubaoSpeechSettings.defaults.contextPrompt
    @AppStorage(DoubaoSpeechSettings.Keys.useSelectedTextContext)
    private var doubaoUseSelectedTextContext = DoubaoSpeechSettings.defaults.useSelectedTextContext
    @AppStorage(DoubaoSpeechSettings.Keys.useClipboardContext)
    private var doubaoUseClipboardContext = DoubaoSpeechSettings.defaults.useClipboardContext
    @AppStorage(DoubaoSpeechSettings.Keys.useApplicationContext)
    private var doubaoUseApplicationContext = DoubaoSpeechSettings.defaults.useApplicationContext
    @AppStorage(DoubaoSpeechSettings.Keys.useWindowTitleContext)
    private var doubaoUseWindowTitleContext = DoubaoSpeechSettings.defaults.useWindowTitleContext
    @AppStorage(DoubaoSpeechSettings.Keys.keepConnectionReady)
    private var doubaoKeepConnectionReady = DoubaoSpeechSettings.defaults.keepConnectionReady
    @AppStorage(AliyunQwenSpeechSettings.Keys.region)
    private var aliyunRegion = AliyunQwenSpeechSettings.defaults.region.rawValue
    @AppStorage(AliyunQwenSpeechSettings.Keys.apiHost)
    private var aliyunAPIHost = AliyunQwenSpeechSettings.defaults.apiHost
    @AppStorage(AliyunQwenSpeechSettings.Keys.semanticPunctuationEnabled)
    private var aliyunSemanticPunctuationEnabled =
        AliyunQwenSpeechSettings.defaults.semanticPunctuationEnabled
    @AppStorage(AliyunQwenSpeechSettings.Keys.maxSentenceSilenceMilliseconds)
    private var aliyunMaxSentenceSilenceMilliseconds =
        AliyunQwenSpeechSettings.defaults.maxSentenceSilenceMilliseconds
    @AppStorage(AliyunQwenSpeechSettings.Keys.multiThresholdModeEnabled)
    private var aliyunMultiThresholdModeEnabled =
        AliyunQwenSpeechSettings.defaults.multiThresholdModeEnabled
    @AppStorage(AliyunQwenSpeechSettings.Keys.heartbeatEnabled)
    private var aliyunHeartbeatEnabled = AliyunQwenSpeechSettings.defaults.heartbeatEnabled
    @AppStorage(AliyunQwenSpeechSettings.Keys.speechNoiseThresholdEnabled)
    private var aliyunSpeechNoiseThresholdEnabled =
        AliyunQwenSpeechSettings.defaults.speechNoiseThresholdEnabled
    @AppStorage(AliyunQwenSpeechSettings.Keys.speechNoiseThreshold)
    private var aliyunSpeechNoiseThreshold = AliyunQwenSpeechSettings.defaults.speechNoiseThreshold
    @AppStorage(AliyunQwenSpeechSettings.Keys.useVoiceInkVocabulary)
    private var aliyunUseVoiceInkVocabulary = AliyunQwenSpeechSettings.defaults.useVoiceInkVocabulary
    @AppStorage(AliyunQwenSpeechSettings.Keys.vocabularyWeight)
    private var aliyunVocabularyWeight = AliyunQwenSpeechSettings.defaults.vocabularyWeight
    @AppStorage(AliyunQwenSpeechSettings.Keys.contextPrompt)
    private var aliyunContextPrompt = AliyunQwenSpeechSettings.defaults.contextPrompt
    @AppStorage(AliyunQwenSpeechSettings.Keys.useSelectedTextContext)
    private var aliyunUseSelectedTextContext = AliyunQwenSpeechSettings.defaults.useSelectedTextContext
    @AppStorage(AliyunQwenSpeechSettings.Keys.useClipboardContext)
    private var aliyunUseClipboardContext = AliyunQwenSpeechSettings.defaults.useClipboardContext
    @AppStorage(AliyunQwenSpeechSettings.Keys.useApplicationContext)
    private var aliyunUseApplicationContext = AliyunQwenSpeechSettings.defaults.useApplicationContext
    @AppStorage(AliyunQwenSpeechSettings.Keys.useWindowTitleContext)
    private var aliyunUseWindowTitleContext = AliyunQwenSpeechSettings.defaults.useWindowTitleContext
    @AppStorage(AliyunQwenSpeechSettings.Keys.keepConnectionReady)
    private var aliyunKeepConnectionReady = AliyunQwenSpeechSettings.defaults.keepConnectionReady

    private var isConfigured: Bool {
        APIKeyManager.shared.hasAPIKey(forProvider: descriptor.providerKey)
    }

    private var isDoubaoSpeech: Bool {
        descriptor.providerKey.caseInsensitiveCompare("Doubao Speech") == .orderedSame
    }

    private var isAliyunQwen: Bool {
        descriptor.providerKey.caseInsensitiveCompare(AliyunQwenSpeechProvider.key) == .orderedSame
    }

    private var aliyunSelectedRegion: AliyunQwenRegion {
        AliyunQwenRegion(rawValue: aliyunRegion) ?? AliyunQwenSpeechSettings.defaults.region
    }

    private var aliyunAPIHostValidationMessage: String? {
        guard isAliyunQwen else { return nil }
        let trimmedHost = aliyunAPIHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHost.isEmpty, trimmedKey.lowercased().hasPrefix("sk-ws-") {
            return String(
                localized:
                    "This dedicated API key requires the API Host shown on the Alibaba Cloud key page."
            )
        }
        guard !trimmedHost.isEmpty else {
            return nil
        }
        do {
            _ = try AliyunQwenSpeechSettings.current().webSocketURL()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var iconName: String {
        if descriptor.hasTranscription && descriptor.hasEnhancement { return "rectangle.2.swap" }
        if descriptor.hasTranscription { return "captions.bubble.fill" }
        return "sparkles"
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    apiKeySection

                    if isDoubaoSpeech {
                        doubaoRecognitionSettingsSection
                    }

                    if isAliyunQwen {
                        aliyunRecognitionSettingsSection
                    }

                    if descriptor.hasTranscription {
                        transcriptionModelsSection
                    }

                    if descriptor.hasEnhancement {
                        enhancementModelsSection
                    }
                }
                .padding(20)
            }
        }
        .onAppear(perform: loadSavedAPIKey)
        .onChange(of: descriptor.id) { _, _ in
            resetProviderState()
        }
        .onChange(of: apiKey) { _, newValue in
            updateAPIKeyDraftProtection(newValue)
        }
        .onDisappear {
            endAPIKeyDraftProtection()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ProviderBrandIcon(
                descriptor: descriptor,
                fallbackSystemImage: iconName,
                isSelected: false,
                size: 38,
                iconSize: 18
            )

            Text(descriptor.displayName)
                .font(.headline)
                .fontWeight(.semibold)

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(AppTheme.Surface.card)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    private var apiKeySection: some View {
        ProviderConfigurationGroup(title: "Connection") {
            VStack(alignment: .leading, spacing: 8) {
                if descriptor.aiProvider == .ark {
                    arkModelInputRow
                }

                if isAliyunQwen {
                    aliyunConnectionSettings
                }

                if isConfigured {
                    verifiedAPIKeyRow
                } else {
                    apiKeyInputRow
                }

                verificationStatusMessage

                if isDoubaoSpeech || isAliyunQwen {
                    Divider()
                    if isDoubaoSpeech {
                        optionToggleRow(
                            title: "Keep a connection ready",
                            detail:
                                "Keeps one authenticated WebSocket ready. After 30 minutes without recognition, preconnection pauses until the next use; no audio is sent while waiting.",
                            isOn: $doubaoKeepConnectionReady
                        )
                        .disabled(!isConfigured)
                        .opacity(isConfigured ? 1 : 0.55)
                        .accessibilityIdentifier("doubao.settings.keepConnectionReady")
                    } else {
                        optionToggleRow(
                            title: "Keep a connection ready",
                            detail:
                                "Keeps one authenticated WebSocket ready. After 30 minutes without recognition, preconnection pauses until the next use; no audio is sent while waiting.",
                            isOn: $aliyunKeepConnectionReady
                        )
                        .disabled(!isConfigured)
                        .opacity(isConfigured ? 1 : 0.55)
                        .accessibilityIdentifier("aliyun.settings.keepConnectionReady")
                    }
                    Text("This device only. May use a small amount of network activity and power.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var aliyunConnectionSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Service region")
                        .font(.system(size: 12, weight: .medium))
                    Text("The API key and endpoint must belong to the same region.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Picker("Service region", selection: $aliyunRegion) {
                    ForEach(AliyunQwenRegion.allCases) { region in
                        Text(region.displayName).tag(region.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
            }
            .padding(.vertical, 10)
            .accessibilityIdentifier("aliyun.settings.region")

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("API host")
                    .font(.system(size: 12, weight: .medium))
                TextField(aliyunSelectedRegion.sharedHost, text: $aliyunAPIHost)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .accessibilityIdentifier("aliyun.settings.apiHost")
                Text(
                    "For a dedicated voice-input key, paste API Host from the same key page. Host, OpenAI-compatible, and DashScope URLs are accepted."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let message = aliyunAPIHostValidationMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Status.error)
                }
            }
            .padding(.vertical, 10)

            Label(
                "The API host stays on this Mac and does not sync through iCloud.",
                systemImage: "lock.shield.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 10)
        }
        .padding(.horizontal, 12)
        .background(ProviderSurface(cornerRadius: 10))
        .accessibilityIdentifier("aliyun.settings.connection")
    }

    private var doubaoRecognitionSettingsSection: some View {
        ProviderConfigurationGroup(title: "Recognition Options") {
            VStack(alignment: .leading, spacing: 0) {
                optionToggleRow(
                    title: "Two-pass recognition",
                    detail: "Uses a second recognition pass for more accurate final text.",
                    isOn: $doubaoEnableTwoPassRecognition
                )
                .accessibilityIdentifier("doubao.settings.twoPassRecognition")
                Divider()
                optionToggleRow(
                    title: "POI recognition assistance",
                    detail: "Uses Doubao's map-domain recommendations for difficult place names.",
                    isOn: $doubaoEnablePOIFunctionCall
                )
                .accessibilityIdentifier("doubao.settings.poiFunctionCall")
                .disabled(!doubaoEnableTwoPassRecognition)
                .opacity(doubaoEnableTwoPassRecognition ? 1 : 0.55)
                Divider()
                optionTextFieldRow(
                    title: "POI city",
                    detail: "Optional. Enter one prefecture-level city only, such as Shenzhen.",
                    placeholder: "One city, e.g. Shenzhen",
                    text: $doubaoPOICityName
                )
                .accessibilityIdentifier("doubao.settings.poiCityName")
                .disabled(!doubaoEnableTwoPassRecognition || !doubaoEnablePOIFunctionCall)
                .opacity(doubaoEnableTwoPassRecognition && doubaoEnablePOIFunctionCall ? 1 : 0.55)
                Divider()
                optionToggleRow(
                    title: "Music recognition assistance",
                    detail: "Uses Doubao's music-domain recommendations for difficult artist, song, and album names.",
                    isOn: $doubaoEnableMusicFunctionCall
                )
                .accessibilityIdentifier("doubao.settings.musicFunctionCall")
                .disabled(!doubaoEnableTwoPassRecognition)
                .opacity(doubaoEnableTwoPassRecognition ? 1 : 0.55)
                Divider()
                optionToggleRow(
                    title: "Text normalization",
                    detail: "Converts spoken numbers, dates, and amounts to written form.",
                    isOn: $doubaoEnableTextNormalization
                )
                .accessibilityIdentifier("doubao.settings.textNormalization")
                Divider()
                optionToggleRow(
                    title: "Automatic punctuation",
                    detail: "Adds punctuation to improve readability.",
                    isOn: $doubaoEnablePunctuation
                )
                .accessibilityIdentifier("doubao.settings.automaticPunctuation")
                Divider()
                optionToggleRow(
                    title: "Semantic smoothing",
                    detail: "Removes filler words and repeated phrases from recognition results.",
                    isOn: $doubaoEnableSemanticSmoothing
                )
                .accessibilityIdentifier("doubao.settings.semanticSmoothing")
                Divider()
                optionToggleRow(
                    title: "Accelerate first text",
                    detail: "Returns initial text sooner, with a possible reduction in early accuracy.",
                    isOn: $doubaoEnableFirstTextAcceleration
                )
                .accessibilityIdentifier("doubao.settings.firstTextAcceleration")
                Divider()
                optionStepperRow(
                    title: "First-text acceleration level",
                    detail: "Higher values return the first text faster (0–20).",
                    value: $doubaoFirstTextAccelerationLevel,
                    range: DoubaoSpeechSettings.accelerationLevelRange,
                    step: 1,
                    suffix: ""
                )
                .accessibilityIdentifier("doubao.settings.firstTextAccelerationLevel")
                .disabled(!doubaoEnableFirstTextAcceleration)
                .opacity(doubaoEnableFirstTextAcceleration ? 1 : 0.55)
                Divider()
                optionStepperRow(
                    title: "Silence finalization threshold",
                    detail: "Lower values finalize sentences sooner but may split speech early.",
                    value: $doubaoSilenceFinalizationMilliseconds,
                    range: DoubaoSpeechSettings.silenceFinalizationRange,
                    step: 100,
                    suffix: " ms"
                )
                .accessibilityIdentifier("doubao.settings.silenceFinalization")
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recognition context")
                        .font(.system(size: 12, weight: .medium))
                    Text("Optional business scenario. Dynamic sources below send extracted features, never their full text.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Optional scenario", text: $doubaoContextPrompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                        .onChange(of: doubaoContextPrompt) { _, value in
                            if value.count > 400 { doubaoContextPrompt = String(value.prefix(400)) }
                        }
                        .accessibilityIdentifier("doubao.settings.contextPrompt")
                }
                .padding(.vertical, 10)
                Divider()
                optionToggleRow(
                    title: "Allow selected-text features",
                    detail: "Requires the active mode's Selected Text setting. Full selected text is not sent to speech recognition.",
                    isOn: $doubaoUseSelectedTextContext
                )
                .accessibilityIdentifier("doubao.settings.selectedTextContext")
                Divider()
                optionToggleRow(
                    title: "Allow clipboard features",
                    detail: "Requires the active mode's Clipboard setting. Full clipboard text is not sent to speech recognition.",
                    isOn: $doubaoUseClipboardContext
                )
                .accessibilityIdentifier("doubao.settings.clipboardContext")
                Divider()
                optionToggleRow(
                    title: "Allow application name",
                    detail: "Requires the active mode's Active Application setting. The bundle identifier stays local.",
                    isOn: $doubaoUseApplicationContext
                )
                .accessibilityIdentifier("doubao.settings.applicationContext")
                Divider()
                optionToggleRow(
                    title: "Allow window title",
                    detail: "Requires the active mode's Window Title setting. Window titles may contain sensitive names.",
                    isOn: $doubaoUseWindowTitleContext
                )
                .accessibilityIdentifier("doubao.settings.windowTitleContext")
            }
            .padding(.horizontal, 12)
            .background(ProviderSurface(cornerRadius: 10))
            .accessibilityIdentifier("doubao.settings.recognitionOptions")

            Label(
                "Recognition options sync through iCloud; POI and recognition-context settings stay on this Mac.",
                systemImage: "icloud"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var aliyunRecognitionSettingsSection: some View {
        ProviderConfigurationGroup(title: "Recognition Options") {
            VStack(alignment: .leading, spacing: 0) {
                optionToggleRow(
                    title: "Semantic sentence segmentation",
                    detail: "Uses semantic boundaries for higher accuracy, with greater final-result latency.",
                    isOn: $aliyunSemanticPunctuationEnabled
                )
                .onChange(of: aliyunSemanticPunctuationEnabled) { _, enabled in
                    if enabled { aliyunMultiThresholdModeEnabled = false }
                }
                .accessibilityIdentifier("aliyun.settings.semanticPunctuation")
                Divider()
                optionStepperRow(
                    title: "VAD silence threshold",
                    detail: "Lower values finalize sentences sooner but may split speech early.",
                    value: $aliyunMaxSentenceSilenceMilliseconds,
                    range: AliyunQwenSpeechSettings.sentenceSilenceRange,
                    step: 100,
                    suffix: " ms"
                )
                .accessibilityIdentifier("aliyun.settings.sentenceSilence")
                Divider()
                optionToggleRow(
                    title: "Multi-threshold VAD",
                    detail: "Prevents VAD from producing excessively long sentences.",
                    isOn: $aliyunMultiThresholdModeEnabled
                )
                .disabled(aliyunSemanticPunctuationEnabled)
                .opacity(aliyunSemanticPunctuationEnabled ? 0.55 : 1)
                .accessibilityIdentifier("aliyun.settings.multiThreshold")
                Divider()
                optionToggleRow(
                    title: "Keep silent sessions alive",
                    detail: "Keeps the server connection active while VoiceInk sends silent audio.",
                    isOn: $aliyunHeartbeatEnabled
                )
                .accessibilityIdentifier("aliyun.settings.heartbeat")
                Divider()
                optionToggleRow(
                    title: "Use VoiceInk vocabulary",
                    detail: "Sends vocabulary as per-session inline hotwords.",
                    isOn: $aliyunUseVoiceInkVocabulary
                )
                .accessibilityIdentifier("aliyun.settings.vocabulary")
                Divider()
                optionStepperRow(
                    title: "Hotword weight",
                    detail: "Higher values make the model more likely to recognize configured terms (1–5).",
                    value: $aliyunVocabularyWeight,
                    range: AliyunQwenSpeechSettings.vocabularyWeightRange,
                    step: 1,
                    suffix: ""
                )
                .disabled(!aliyunUseVoiceInkVocabulary)
                .opacity(aliyunUseVoiceInkVocabulary ? 1 : 0.55)
                .accessibilityIdentifier("aliyun.settings.vocabularyWeight")
                Divider()
                optionToggleRow(
                    title: "Custom noise threshold",
                    detail: "Fine-tunes VAD sensitivity for unusually noisy or quiet environments.",
                    isOn: $aliyunSpeechNoiseThresholdEnabled
                )
                .accessibilityIdentifier("aliyun.settings.noiseThresholdEnabled")
                Divider()
                optionDoubleStepperRow(
                    title: "Speech/noise threshold",
                    detail: "Lower values retain more sound; higher values filter more aggressively (-1.0–1.0).",
                    value: $aliyunSpeechNoiseThreshold,
                    range: AliyunQwenSpeechSettings.speechNoiseThresholdRange,
                    step: 0.1
                )
                .disabled(!aliyunSpeechNoiseThresholdEnabled)
                .opacity(aliyunSpeechNoiseThresholdEnabled ? 1 : 0.55)
                .accessibilityIdentifier("aliyun.settings.noiseThreshold")
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recognition context")
                        .font(.system(size: 12, weight: .medium))
                    Text("Add domain terms or prior context to improve recognition (up to 400 characters).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Optional context", text: $aliyunContextPrompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                        .onChange(of: aliyunContextPrompt) { _, value in
                            if value.count > AliyunQwenSpeechSettings.maximumContextLength {
                                aliyunContextPrompt = String(
                                    value.prefix(AliyunQwenSpeechSettings.maximumContextLength)
                                )
                            }
                        }
                        .accessibilityIdentifier("aliyun.settings.contextPrompt")
                }
                .padding(.vertical, 10)
                Divider()
                optionToggleRow(
                    title: "Allow selected-text features",
                    detail: "Requires the active mode's Selected Text setting. Full selected text is not sent to speech recognition.",
                    isOn: $aliyunUseSelectedTextContext
                )
                .accessibilityIdentifier("aliyun.settings.selectedTextContext")
                Divider()
                optionToggleRow(
                    title: "Allow clipboard features",
                    detail: "Requires the active mode's Clipboard setting. Full clipboard text is not sent to speech recognition.",
                    isOn: $aliyunUseClipboardContext
                )
                .accessibilityIdentifier("aliyun.settings.clipboardContext")
                Divider()
                optionToggleRow(
                    title: "Allow application name",
                    detail: "Requires the active mode's Active Application setting. The bundle identifier stays local.",
                    isOn: $aliyunUseApplicationContext
                )
                .accessibilityIdentifier("aliyun.settings.applicationContext")
                Divider()
                optionToggleRow(
                    title: "Allow window title",
                    detail: "Requires the active mode's Window Title setting. Window titles may contain sensitive names.",
                    isOn: $aliyunUseWindowTitleContext
                )
                .accessibilityIdentifier("aliyun.settings.windowTitleContext")
            }
            .padding(.horizontal, 12)
            .background(ProviderSurface(cornerRadius: 10))
            .accessibilityIdentifier("aliyun.settings.recognitionOptions")

            Label(
                "Recognition options sync through iCloud; recognition context stays on this Mac.",
                systemImage: "icloud"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func optionToggleRow(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .padding(.vertical, 10)
    }

    private func optionStepperRow(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        suffix: String
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Stepper(value: value, in: range, step: step) {
                Text("\(value.wrappedValue)\(suffix)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .frame(minWidth: 52, alignment: .trailing)
            }
        }
        .padding(.vertical, 10)
    }

    private func optionTextFieldRow(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        placeholder: LocalizedStringKey,
        text: Binding<String>
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
        }
        .padding(.vertical, 10)
    }

    private func optionDoubleStepperRow(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Stepper(value: value, in: range, step: step) {
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(1))))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .frame(minWidth: 52, alignment: .trailing)
            }
        }
        .padding(.vertical, 10)
    }

    private var arkModelInputRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                providerDetailIcon("cpu.fill")

                VStack(alignment: .leading, spacing: 3) {
                    Text("Model or endpoint name")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Enter an Ark model ID or inference endpoint ID.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                TextField("ep-20250520154305-lz8cg", text: $arkModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .disabled(isVerifying)
                    .onChange(of: arkModel) { _, _ in
                        verificationMessage = nil
                        verificationDetailMessage = nil
                    }

                if isConfigured {
                    Button {
                        verifyAndSaveArkModel()
                    } label: {
                        HStack(spacing: 5) {
                            if isVerifying {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "checkmark.seal")
                            }
                            Text(isVerifying ? LocalizedStringKey("Verifying") : LocalizedStringKey("Save & Verify"))
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(arkModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isVerifying)
                }
            }
        }
        .padding(12)
        .background(ProviderSurface(cornerRadius: 8))
    }

    @ViewBuilder
    private var verificationStatusMessage: some View {
        if let verificationMessage {
            VStack(alignment: .leading, spacing: 3) {
                Text(verificationMessage)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(verificationSucceeded ? AppTheme.Status.positive : AppTheme.Status.error)
                    .fixedSize(horizontal: false, vertical: true)

                if let verificationDetailMessage, !verificationSucceeded {
                    Text(verificationDetailMessage)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Status.error.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var verifiedAPIKeyRow: some View {
        HStack(spacing: 12) {
            providerDetailIcon("checkmark.seal.fill")

            VStack(alignment: .leading, spacing: 3) {
                Text("Key verified")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                if let obfuscatedKey {
                    Text(obfuscatedKey)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Button {
                isShowingRemoveAPIKeyConfirmation = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .help("Remove API key")
        }
        .padding(12)
        .background(ProviderSurface(cornerRadius: 8))
        .alert("Remove API Key?", isPresented: $isShowingRemoveAPIKeyConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                removeAPIKey()
            }
        } message: {
            Text(
                String(
                    format: String(localized: "This will remove your %@ API key. You can add it again later."),
                    descriptor.displayName))
        }
    }

    private var apiKeyInputRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                providerDetailIcon("key.fill")

                VStack(alignment: .leading, spacing: 3) {
                    Text(descriptor.providerKey == "Doubao Speech" ? "AK (API Key)" : "API Key")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }

            HStack(spacing: 8) {
                SecureField("Paste API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .disabled(isVerifying)
                    .onChange(of: apiKey) { _, newValue in
                        guard !newValue.isEmpty else { return }
                        verificationMessage = nil
                        verificationDetailMessage = nil
                    }

                Button {
                    verifyAndSaveAPIKey()
                } label: {
                    HStack(spacing: 5) {
                        if isVerifying {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.seal")
                        }
                        Text(isVerifying ? LocalizedStringKey("Verifying") : LocalizedStringKey("Verify"))
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canVerifyAPIKey)
                .opacity(canVerifyAPIKey ? 1 : 0.55)
            }

            if let consoleURL = descriptor.apiConsoleURL {
                Link(destination: consoleURL) {
                    HStack(spacing: 7) {
                        Image(systemName: "link")
                            .font(.system(size: 11, weight: .semibold))

                        Text(String(format: String(localized: "Get %@ API Key"), descriptor.displayName))
                            .font(.system(size: 12, weight: .medium))

                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(neutralLinkButtonBackground)
                }
                .buttonStyle(.plain)
                .help(String(format: String(localized: "Open %@ API key page"), descriptor.displayName))
            }

            Label(
                "Stored only in this Mac's Keychain. API keys do not sync between devices.",
                systemImage: "lock.shield.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(ProviderSurface(cornerRadius: 8))
    }

    private func providerDetailIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(AppTheme.Surface.control)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(AppTheme.Border.control.opacity(0.45), lineWidth: 1)
                    )
            )
    }

    private var neutralLinkButtonBackground: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(AppTheme.Surface.control)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(AppTheme.Border.control.opacity(0.45), lineWidth: 1)
            )
    }

    private var transcriptionModelsSection: some View {
        let models = descriptor.transcriptionModels

        return ProviderModelListSection(title: "Available Transcription Models") {
            ForEach(Array(models.prefix(8).enumerated()), id: \.element.id) { index, model in
                modelRow(
                    title: model.displayName,
                    subtitle: nil,
                    trailing: nil,
                    systemImage: "captions.bubble.fill"
                )

                if index < min(models.count, 8) - 1 {
                    Divider()
                }
            }

            if models.count > 8 {
                Divider()
                Text("More transcription models available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private var enhancementModelsSection: some View {
        if let provider = descriptor.aiProvider {
            let models = aiService.availableModels(for: provider)

            ProviderModelListSection(title: "Available Enhancement Models") {
                if provider == .openRouter {
                    HStack(spacing: 12) {
                        Text(openRouterModelAvailabilityText(for: models.count))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(models.isEmpty ? .secondary : .primary)

                        Spacer()

                        Button {
                            refreshOpenRouterModels()
                        } label: {
                            HStack(spacing: 5) {
                                if isRefreshingOpenRouterModels {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text(
                                    isRefreshingOpenRouterModels
                                        ? LocalizedStringKey("Refreshing") : LocalizedStringKey("Refresh"))
                            }
                            .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isRefreshingOpenRouterModels)
                        .opacity(isRefreshingOpenRouterModels ? 0.55 : 1)
                    }
                    .padding(.vertical, 8)
                } else if models.isEmpty {
                    Text("No models listed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(Array(models.prefix(8).enumerated()), id: \.offset) { index, model in
                        modelRow(
                            title: model,
                            subtitle: nil,
                            trailing: nil,
                            systemImage: "sparkles"
                        )

                        if index < min(models.count, 8) - 1 {
                            Divider()
                        }
                    }

                    if models.count > 8 {
                        Divider()
                        Text("More enhancement models available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                }

            }
        }
    }

    private func openRouterModelAvailabilityText(for count: Int) -> String {
        if count == 0 {
            return String(localized: "No models loaded.")
        }

        return String(localized: "\(count) models available")
    }

    private func modelRow(title: String, subtitle: String?, trailing: String?, systemImage: String) -> some View {
        HStack(spacing: 10) {
            modelTypeIcon(systemImage)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private func modelTypeIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(AppTheme.Surface.control)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(AppTheme.Border.control.opacity(0.45), lineWidth: 1)
                    )
            )
    }

    private var obfuscatedKey: String? {
        guard let savedKey = APIKeyManager.shared.getAPIKey(forProvider: descriptor.providerKey) else {
            return nil
        }

        let trimmedKey = savedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }
        if trimmedKey.count <= 8 {
            return String(repeating: "\u{2022}", count: trimmedKey.count)
        }

        return
            "\(trimmedKey.prefix(4))\(String(repeating: "\u{2022}", count: max(4, trimmedKey.count - 8)))\(trimmedKey.suffix(4))"
    }

    private func loadSavedAPIKey() {
        resetProviderState()
    }

    private func resetProviderState() {
        activeDescriptorID = descriptor.id
        verificationSucceeded = isConfigured
        apiKey = ""
        endAPIKeyDraftProtection()
        isVerifying = false
        isRefreshingOpenRouterModels = false
        verificationMessage = nil
        verificationDetailMessage = nil
        isShowingRemoveAPIKeyConfirmation = false
        arkModel = descriptor.aiProvider == .ark ? aiService.selectedModel(for: .ark) : ""
        normalizeDoubaoNumericSettingsIfNeeded()
        normalizeAliyunSettingsIfNeeded()
    }

    private func updateAPIKeyDraftProtection(_ value: String) {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            endAPIKeyDraftProtection()
        } else if apiKeyDraftWorkID == nil {
            apiKeyDraftWorkID = RuntimeProtectedWorkActivity.shared.begin()
        }
    }

    private func endAPIKeyDraftProtection() {
        if let apiKeyDraftWorkID {
            RuntimeProtectedWorkActivity.shared.end(apiKeyDraftWorkID)
            self.apiKeyDraftWorkID = nil
        }
    }

    private func normalizeDoubaoNumericSettingsIfNeeded() {
        guard isDoubaoSpeech else { return }
        let settings = DoubaoSpeechSettings.current()
        if doubaoFirstTextAccelerationLevel != settings.firstTextAccelerationLevel {
            doubaoFirstTextAccelerationLevel = settings.firstTextAccelerationLevel
        }
        if doubaoSilenceFinalizationMilliseconds != settings.silenceFinalizationMilliseconds {
            doubaoSilenceFinalizationMilliseconds = settings.silenceFinalizationMilliseconds
        }
        if doubaoContextPrompt != settings.contextPrompt {
            doubaoContextPrompt = settings.contextPrompt
        }
    }

    private func normalizeAliyunSettingsIfNeeded() {
        guard isAliyunQwen else { return }
        let settings = AliyunQwenSpeechSettings.current()
        if aliyunRegion != settings.region.rawValue {
            aliyunRegion = settings.region.rawValue
        }
        if aliyunMaxSentenceSilenceMilliseconds != settings.maxSentenceSilenceMilliseconds {
            aliyunMaxSentenceSilenceMilliseconds = settings.maxSentenceSilenceMilliseconds
        }
        if aliyunMultiThresholdModeEnabled != settings.multiThresholdModeEnabled {
            aliyunMultiThresholdModeEnabled = settings.multiThresholdModeEnabled
        }
        if aliyunSpeechNoiseThreshold != settings.speechNoiseThreshold {
            aliyunSpeechNoiseThreshold = settings.speechNoiseThreshold
        }
        if aliyunVocabularyWeight != settings.vocabularyWeight {
            aliyunVocabularyWeight = settings.vocabularyWeight
        }
        if aliyunContextPrompt != settings.contextPrompt {
            aliyunContextPrompt = settings.contextPrompt
        }
    }

    private var canVerifyAPIKey: Bool {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isVerifying else {
            return false
        }
        if isAliyunQwen, aliyunAPIHostValidationMessage != nil {
            return false
        }
        return descriptor.aiProvider != .ark
            || !arkModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func verificationModel(for provider: AIProvider) -> String {
        let selectedModel = aiService.selectedModel(for: provider)
        let models = aiService.availableModels(for: provider)

        if models.contains(selectedModel) {
            return selectedModel
        }

        return models.first ?? selectedModel
    }

    private func verifyAndSaveAPIKey() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        let arkVerificationModel = arkModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if descriptor.aiProvider == .ark, arkVerificationModel.isEmpty { return }

        isVerifying = true
        verificationMessage = nil
        verificationDetailMessage = nil
        let providerID = descriptor.id

        Task {
            let result: (isValid: Bool, errorMessage: String?)
            if let cloudProvider = descriptor.cloudProvider {
                result = await cloudProvider.verifyAPIKey(trimmedKey)
            } else if let provider = descriptor.aiProvider {
                let model = provider == .ark ? arkVerificationModel : verificationModel(for: provider)
                result = await aiService.verifyAPIKey(
                    trimmedKey,
                    for: provider,
                    model: model
                )
            } else {
                result = (false, String(localized: "Provider is not supported"))
            }

            await MainActor.run {
                guard activeDescriptorID == providerID else { return }

                isVerifying = false
                verificationSucceeded = result.isValid

                if result.isValid {
                    let didSave = APIKeyManager.shared.saveAPIKey(
                        trimmedKey,
                        forProvider: descriptor.providerKey
                    )
                    guard didSave else {
                        verificationSucceeded = false
                        verificationMessage = String(
                            localized: "The API key is valid, but VoiceInk could not save it to macOS Keychain."
                        )
                        verificationDetailMessage = String(
                            localized: "The key was not cleared. Check Keychain access and try again."
                        )
                        return
                    }

                    if let provider = descriptor.aiProvider {
                        if provider == .ark {
                            aiService.selectModel(arkVerificationModel, for: provider)
                        }
                        if aiService.selectedProvider == provider {
                            aiService.apiKey = trimmedKey
                            aiService.isAPIKeyValid = true
                        }
                    }
                    apiKey = ""
                    verificationMessage = String(localized: "API key verified and saved to macOS Keychain.")
                    verificationDetailMessage = nil
                    transcriptionModelManager.refreshAllAvailableModels()
                    NotificationCenter.default.post(name: .aiProviderKeyChanged, object: nil)
                } else {
                    verificationMessage = String(
                        localized: "Could not verify this API key. Check the key and try again.")
                    verificationDetailMessage = aliyunVerificationDetail(
                        serviceError: result.errorMessage,
                        key: trimmedKey
                    )
                }
            }
        }
    }

    private func aliyunVerificationDetail(serviceError: String?, key: String) -> String? {
        guard isAliyunQwen else { return serviceError }
        let trimmedHost = aliyunAPIHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedHost.isEmpty || key.lowercased().hasPrefix("sk-ws-") else {
            return serviceError
        }

        let guidance = String(
            localized:
                "Dedicated voice-input API keys must use the API Host displayed on the same Alibaba Cloud key page."
        )
        guard let serviceError, !serviceError.isEmpty else { return guidance }
        return "\(serviceError)\n\(guidance)"
    }

    private func verifyAndSaveArkModel() {
        let model = arkModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !model.isEmpty,
            let savedKey = APIKeyManager.shared.getAPIKey(forProvider: AIProvider.ark.rawValue),
            !savedKey.isEmpty
        else { return }

        isVerifying = true
        verificationMessage = nil
        verificationDetailMessage = nil
        let providerID = descriptor.id

        Task {
            let result = await aiService.verifyAPIKey(savedKey, for: .ark, model: model)

            await MainActor.run {
                guard activeDescriptorID == providerID else { return }
                isVerifying = false
                verificationSucceeded = result.isValid

                if result.isValid {
                    aiService.selectModel(model, for: .ark)
                    verificationMessage = String(localized: "Model verified and saved.")
                    verificationDetailMessage = nil
                } else {
                    verificationMessage = String(localized: "Could not verify this model. Check the name and try again.")
                    verificationDetailMessage = result.errorMessage
                }
            }
        }
    }

    private func removeAPIKey() {
        APIKeyManager.shared.deleteAPIKey(forProvider: descriptor.providerKey)
        apiKey = ""
        verificationSucceeded = false
        verificationMessage = nil
        verificationDetailMessage = nil
        transcriptionModelManager.refreshAllAvailableModels()
        NotificationCenter.default.post(name: .aiProviderKeyChanged, object: nil)
    }

    private func refreshOpenRouterModels() {
        guard !isRefreshingOpenRouterModels else { return }
        isRefreshingOpenRouterModels = true

        Task {
            await aiService.fetchOpenRouterModels()
            await MainActor.run {
                isRefreshingOpenRouterModels = false
            }
        }
    }

}
