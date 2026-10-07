import Foundation

/// 学习统计：最近一周查了多少、收了多少、复习得怎么样，以及反复查却还没收藏的词。
struct LearningStats: Equatable, Sendable {
    struct Day: Equatable, Sendable {
        let date: Date
        let lookups: Int
        let reviews: Int
    }

    struct Repeated: Equatable, Sendable {
        let key: String
        let text: String
        let count: Int
        let saved: Bool
    }

    var days: [Day] = []
    var weekLookups = 0
    var weekNewKeys = 0
    var weekSaved = 0
    var weekReviews = 0
    /// 最近一周自评「记住」的比例；一周没有复习则为 nil。
    var weekRecallRate: Double?
    var words = 0
    var patterns = 0
    var due = 0
    /// 间隔已经拉到三周以上，基本记牢了。
    var mastered = 0
    var repeated: [Repeated] = []

    static let masteredInterval = 21.0

    static func compute(lookups: [LookupRecord],
                        entries: [NotebookEntry],
                        now: Date,
                        calendar: Calendar = .current) -> LearningStats {
        var stats = LearningStats()
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let monthStart = calendar.date(byAdding: .day, value: -29, to: today) ?? today

        var lookupsPerDay: [Date: Int] = [:]
        var reviewsPerDay: [Date: Int] = [:]
        var weekKeys: Set<String> = []
        var earlierKeys: Set<String> = []
        var monthCounts: [String: (text: String, count: Int, latest: Date)] = [:]

        for record in lookups {
            let day = calendar.startOfDay(for: record.date)
            if day >= weekStart {
                stats.weekLookups += 1
                lookupsPerDay[day, default: 0] += 1
                weekKeys.insert(record.key)
            } else {
                earlierKeys.insert(record.key)
            }
            if day >= monthStart {
                var item = monthCounts[record.key] ?? (record.text, 0, .distantPast)
                item.count += 1
                if record.date > item.latest { item.latest = record.date; item.text = record.text }
                monthCounts[record.key] = item
            }
        }
        stats.weekNewKeys = weekKeys.subtracting(earlierKeys).count

        var good = 0
        for entry in entries {
            if entry.kind == .word { stats.words += 1 } else { stats.patterns += 1 }
            if entry.review.due <= now { stats.due += 1 }
            if entry.review.interval >= masteredInterval { stats.mastered += 1 }
            if calendar.startOfDay(for: entry.createdAt) >= weekStart { stats.weekSaved += 1 }
            for event in entry.reviews {
                let day = calendar.startOfDay(for: event.date)
                guard day >= weekStart else { continue }
                stats.weekReviews += 1
                reviewsPerDay[day, default: 0] += 1
                if event.grade == .good { good += 1 }
            }
        }
        if stats.weekReviews > 0 {
            stats.weekRecallRate = Double(good) / Double(stats.weekReviews)
        }

        stats.days = (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
            return Day(date: date, lookups: lookupsPerDay[date] ?? 0, reviews: reviewsPerDay[date] ?? 0)
        }

        let savedKeys = Set(entries.map(\.key))
        stats.repeated = monthCounts
            .filter { $0.value.count >= 2 }
            .map { Repeated(key: $0.key, text: $0.value.text, count: $0.value.count, saved: savedKeys.contains($0.key)) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.text < $1.text }
            .prefix(8)
            .map { $0 }
        return stats
    }
}
