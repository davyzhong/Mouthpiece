import Foundation

enum UILanguage: String, Codable, CaseIterable, Sendable {
    case simplifiedChinese = "zh-CN"
    case traditionalChinese = "zh-TW"
    case english = "en"
    case system = "system"
}

enum AppTheme: String, Codable, CaseIterable, Sendable {
    case light
    case dark
    case system = "auto"
}

enum LocalTranscriptionProvider: String, Codable, CaseIterable, Sendable {
    case whisper
    case parakeet = "nvidia"
    case qwen
}

enum HotkeyBehavior: String, Codable, CaseIterable, Sendable {
    case automatic
    case toggle
    case pushToTalk
}

struct TerminologyProfile: Codable, Equatable, Sendable {
    var preferredTerms: [String] = []
    var avoidedTerms: [String] = []
    var replacementRules: [String: String] = [:]

    mutating func normalize() {
        preferredTerms = Self.uniqueTrimmed(preferredTerms)
        avoidedTerms = Self.uniqueTrimmed(avoidedTerms)
        var normalizedRules: [String: String] = [:]
        let sortedRules = replacementRules.sorted { left, right in
            let leftIsTrimmed = left.key == left.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let rightIsTrimmed = right.key == right.key.trimmingCharacters(in: .whitespacesAndNewlines)
            if leftIsTrimmed != rightIsTrimmed { return leftIsTrimmed }
            return left.key.localizedStandardCompare(right.key) == .orderedAscending
        }
        for (key, value) in sortedRules {
            let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanKey.isEmpty, !cleanValue.isEmpty, normalizedRules[cleanKey] == nil else { continue }
            normalizedRules[cleanKey] = cleanValue
        }
        replacementRules = normalizedRules
    }

    private static func uniqueTrimmed(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, seen.insert(clean.lowercased()).inserted else { return nil }
            return clean
        }
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var uiLanguage: UILanguage = .simplifiedChinese
    var theme: AppTheme = .system

    var dictationKey = "RightCommand"
    var hotkeyBehavior: HotkeyBehavior = .automatic
    var translationHotkeySuffix = TranslationHotkey.defaultSuffix
    var selectedMicrophoneUID = ""
    var launchAtLogin = false
    var showInDock = true
    var showInMenuBar = true
    var escapeCancelsRecording = true
    var pauseOtherMediaDuringDictation = false
    var automaticallyPasteTranscription = true
    var keepTranscriptionInClipboard = false
    var audioCuesEnabled = true
    var soundPreset = "classic"

    var useLocalTranscription = false
    var localTranscriptionProvider: LocalTranscriptionProvider = .whisper
    var whisperModel = "base"
    var parakeetModel = ""
    var qwenASRModel = "qwen3-asr-0.6b-mlx"
    var allowCloudFallback = false
    var allowLocalFallback = false
    var fallbackWhisperModel = "base"

    var preferredLanguage = "auto"
    var cloudTranscriptionProvider = "openai"
    var cloudTranscriptionModel = "gpt-4o-mini-transcribe"
    var bailianTranscriptionModel = BailianRealtimeProvider.defaultModel
    var cloudTranscriptionBaseURL = "https://api.openai.com/v1"
    var assemblyAIStreaming = true
    var deepgramStreamingEnabled = false
    var sonioxRealtimeEnabled = true

    var useReasoningModel = true
    var reasoningProvider = "openai"
    var reasoningModel = ""
    var reasoningBaseURL = "https://api.openai.com/v1"
    var bailianReasoningEnableThinking = false
    var customReasoningEnableThinking = false
    var translationEnabled = false
    var translationTargetLanguage = ""

    var terminologyProfile = TerminologyProfile()
    var correctionLearningEnabled = false
    var correctionLearningSchedule = "count"
    var correctionLearningBatchSize = 50
    var customPrompt = ""
    var sensitiveAppProtectionEnabled = true
    var sensitiveAppBlockInsertion = true
    var allowSensitiveAppCloudReasoning = false
    var debugLoggingEnabled = false
    var onboardingCompleted = false

    mutating func normalize() {
        dictationKey = dictationKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !HotkeyDescriptor.isValid(dictationKey) {
            dictationKey = "RightCommand"
        }
        translationHotkeySuffix = TranslationHotkey.normalizedSuffix(translationHotkeySuffix)
            ?? TranslationHotkey.defaultSuffix
        if reasoningProvider == "local" {
            reasoningProvider = "openai"
            reasoningModel = "gpt-4o-mini"
            reasoningBaseURL = "https://api.openai.com/v1"
        }
        if cloudTranscriptionProvider == "bailian" {
            let current = BailianASRModel(rawValue: cloudTranscriptionModel)
            let remembered = BailianASRModel(rawValue: bailianTranscriptionModel)
            let model = current ?? remembered ?? .defaultModel
            cloudTranscriptionModel = model.rawValue
            bailianTranscriptionModel = model.rawValue
        } else if cloudTranscriptionProvider == "volcengine" {
            cloudTranscriptionModel = VolcengineRealtimeProvider.model
        }
        if BailianASRModel(rawValue: bailianTranscriptionModel) == nil {
            bailianTranscriptionModel = BailianASRModel.defaultModel.rawValue
        }
        cloudTranscriptionBaseURL = Self.normalizedURL(
            cloudTranscriptionBaseURL,
            fallback: "https://api.openai.com/v1"
        )
        reasoningBaseURL = Self.normalizedURL(
            reasoningBaseURL,
            fallback: "https://api.openai.com/v1"
        )
        // 翻译结果由文字整理管线产出；历史配置可能残留“翻译开、文字整理关”
        // 的失效组合，归一化为关闭翻译。
        if translationEnabled, !useReasoningModel {
            translationEnabled = false
        }
        terminologyProfile.normalize()
        if !["count", "daily"].contains(correctionLearningSchedule) {
            correctionLearningSchedule = "count"
        }
        correctionLearningBatchSize = max(10, min(100, correctionLearningBatchSize))
    }

    private static func normalizedURL(_ value: String, fallback: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: clean),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.query == nil,
              components.fragment == nil,
              scheme == "https" || (scheme == "http" && Self.isLoopbackHost(host)) else {
            return fallback
        }
        return clean.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

enum CredentialAccount: String, CaseIterable, Sendable {
    case openAI = "openai-api-key"
    case anthropic = "anthropic-api-key"
    case deepgram = "deepgram-api-key"
    case gemini = "gemini-api-key"
    case groq = "groq-api-key"
    case mistral = "mistral-api-key"
    case soniox = "soniox-api-key"
    case bailian = "bailian-api-key"
    case volcengine = "volcengine-api-key"
    case assemblyAI = "assemblyai-api-key"
    case customTranscription = "custom-transcription-api-key"
    case customReasoning = "custom-reasoning-api-key"
}
