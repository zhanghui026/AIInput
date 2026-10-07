import Foundation

/// 生成一张卡片的原始输出（生产环境是 `TranslationService`，测试里可替换）。
/// `onPartial` 收到截至目前的完整文本（只增不减），返回值是最终的完整文本。
protocol CardGenerating: Sendable {
    func generate(_ request: CardRequest,
                  onPartial: TranslationService.PartialHandler?) async throws -> String
}

extension TranslationService: CardGenerating {
    /// 把一张卡片拆成两路并行请求：每路只写一半区块，总耗时接近较慢的那一路。
    /// 两路的区块按完成顺序拼成一份只增不减的 NDJSON 交给调用方，显示顺序由调用方按区块类型排。
    func generate(_ request: CardRequest,
                  onPartial: PartialHandler?) async throws -> String {
        let prompts = CardPromptBuilder.makeParts(for: request)
        let merger = await CardPartsMerger(allowed: CardPromptBuilder.partitions(for: request.target.kind), onPartial: onPartial)
        let failures = FailureBox()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, prompt) in prompts.enumerated() {
                group.addTask {
                    do {
                        let raw = try await self.performRaw(prompt) { partial in
                            merger.feed(partial, from: index)
                        }
                        await merger.feed(raw, from: index)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        await failures.record(error)
                    }
                }
            }
            try await group.waitForAll()
        }
        try Task.checkCancellation()

        let text = await merger.text
        // 只有一路失败时保留另一路已经拿到的区块；全都没有才算失败。
        if await merger.blockCount == 0, let error = await failures.first {
            throw error
        }
        return text
    }
}

private actor FailureBox {
    private(set) var first: Error?
    func record(_ error: Error) {
        if first == nil { first = error }
    }
}

/// 把几路各自的流式输出合成一份只增不减的 NDJSON。
@MainActor
private final class CardPartsMerger {
    private var parsers: [CardStreamParser]
    private let allowed: [Set<String>]
    private var seen: Set<String> = []
    private let onPartial: TranslationService.PartialHandler?
    private(set) var text = ""
    private(set) var blockCount = 0

    /// `allowed[i]` 是第 i 路该写的区块类型。模型偶尔会多写别的路的区块，或把同一类型写两遍，这里丢掉。
    init(allowed: [Set<String>], onPartial: TranslationService.PartialHandler?) {
        parsers = allowed.map { _ in CardStreamParser() }
        self.allowed = allowed
        self.onPartial = onPartial
    }

    func feed(_ partial: String, from part: Int) {
        let blocks = parsers[part].update(with: partial).filter {
            allowed[part].contains($0.typeKey) && seen.insert($0.typeKey).inserted
        }
        guard !blocks.isEmpty else { return }
        let encoder = JSONEncoder()
        for block in blocks {
            guard let data = try? encoder.encode(block), let line = String(data: data, encoding: .utf8) else { continue }
            text += line + "\n"
            blockCount += 1
        }
        onPartial?(text)
    }
}
