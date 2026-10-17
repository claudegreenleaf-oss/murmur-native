import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum LLMError: Error {
    case unavailable
    case empty
}

/// Thin wrapper over Apple's on-device Foundation Models (macOS 26+, Apple Intelligence enabled).
enum AppleLLM {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    static var unavailableReason: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .unavailable(let r) = SystemLanguageModel.default.availability { return "\(r)" }
            return "available"
        }
        #endif
        return "FoundationModels requires macOS 26"
    }

    /// Greedy decoding, no sampling. A fresh session per call keeps requests independent.
    static func respond(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { throw LLMError.unavailable }
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(sampling: .greedy, temperature: 0, maximumResponseTokens: maxTokens)
            let response = try await session.respond(to: prompt, options: options)
            return response.content
        }
        #endif
        throw LLMError.unavailable
    }

    /// Loads the model into memory in the background so the first dictation is not slow.
    static func warmUp() async {
        guard isAvailable else { return }
        _ = try? await respond(instructions: "Reply with one word.", prompt: "hello", maxTokens: 4)
    }
}
