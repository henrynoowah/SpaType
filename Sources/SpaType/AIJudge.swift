import Foundation
#if canImport(FoundationModels) && arch(arm64)
import FoundationModels
#endif

/// Second opinion from Apple's on-device model (macOS 26+, Apple Intelligence). Given the same keystrokes read
/// through different input sources, it picks the reading a person meant. Nothing leaves the device.
/// Built without the macOS 26 SDK, for Intel, or run on an older system, it is simply unavailable.
enum AIJudge {
    static var isAvailable: Bool { unavailableReason.isEmpty }

    /// Empty when available; otherwise a short Korean reason for the Settings window.
    static var unavailableReason: String {
        #if canImport(FoundationModels) && arch(arm64)
        if #available(macOS 26, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                let korean = model.supportedLanguages.contains { $0.languageCode?.identifier == "ko" }
                return korean ? "" : "Apple 모델이 한국어를 지원하지 않아요"
            case .unavailable(.deviceNotEligible):
                return "Apple Intelligence를 지원하는 Mac이 필요해요"
            case .unavailable(.appleIntelligenceNotEnabled):
                return "시스템 설정에서 Apple Intelligence를 켜 주세요"
            case .unavailable(.modelNotReady):
                return "Apple 모델을 내려받는 중이에요"
            case .unavailable:
                return "Apple 모델을 쓸 수 없어요"
            }
        }
        #endif
        return "macOS 26 이상과 Apple Intelligence가 필요해요"
    }

    /// Loads the model ahead of the first question so the first answer isn't slow.
    static func prewarm() {
        #if canImport(FoundationModels) && arch(arm64)
        if #available(macOS 26, *), isAvailable { LanguageModelSession().prewarm() }
        #endif
    }

    /// Index into `readings` of the intended text, or nil when the model is unsure, unavailable or fails.
    /// `readings[0]` is the text as typed.
    static func pick(_ readings: [String]) async -> Int? {
        #if canImport(FoundationModels) && arch(arm64)
        if #available(macOS 26, *), isAvailable, readings.count > 1 {
            let session = LanguageModelSession(instructions: """
                Each option is the same keystrokes read through a different keyboard input source \
                (for example English QWERTY vs Korean 2-set). Exactly one is usually what the person meant; \
                the others are gibberish. Pick the option that reads as natural text a person would type. \
                Set confident to false if more than one option, or none, reads naturally.
                """)
            let prompt = readings.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n")
            guard let choice = try? await session.respond(to: prompt, generating: AIChoice.self).content,
                  choice.confident, readings.indices.contains(choice.index)
            else { return nil }
            return choice.index
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels) && arch(arm64)
@available(macOS 26, *)
@Generable
struct AIChoice {
    @Guide(description: "Index of the option the person meant to type", .range(0...3))
    var index: Int
    @Guide(description: "True only if exactly that option reads as natural text")
    var confident: Bool
}
#endif
