import Foundation

/// 生成一张卡片的原始输出（生产环境是 `TranslationService`，测试里可替换）。
/// `onPartial` 收到截至目前的完整文本，返回值是最终的完整文本。
protocol CardGenerating: Sendable {
    func generate(_ request: CardRequest,
                  onPartial: TranslationService.PartialHandler?) async throws -> String
}

extension TranslationService: CardGenerating {
    func generate(_ request: CardRequest,
                  onPartial: PartialHandler?) async throws -> String {
        try await performRaw(CardPromptBuilder.make(for: request), onPartial: onPartial)
    }
}
