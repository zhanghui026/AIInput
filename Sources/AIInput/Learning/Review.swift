import Foundation

enum ReviewGrade: String, Codable, CaseIterable, Sendable {
    case forgot
    case fuzzy
    case good

    var displayName: String {
        switch self {
        case .forgot: return "忘了"
        case .fuzzy: return "模糊"
        case .good: return "记住"
        }
    }
}

struct ReviewState: Codable, Equatable, Sendable {
    var due: Date
    /// 当前间隔（天）。
    var interval: Double
    var ease: Double
    var repetitions: Int
    var lapses: Int

    /// 新收进来的条目：第二天开始复习，刚看过不必马上再考。
    static func initial(now: Date, calendar: Calendar = .current) -> ReviewState {
        ReviewState(due: ReviewScheduler.day(after: 1, from: now, calendar: calendar),
                    interval: 0, ease: 2.5, repetitions: 0, lapses: 0)
    }
}

struct ReviewEvent: Codable, Equatable, Sendable {
    var date: Date
    var grade: ReviewGrade
}

/// 简化的 SM-2：三档自评，到期时间落在当天 0 点，晚上复习也算「明天」的。
enum ReviewScheduler {
    static let minimumEase = 1.3

    static func next(_ state: ReviewState,
                     grade: ReviewGrade,
                     now: Date,
                     calendar: Calendar = .current) -> ReviewState {
        var next = state
        switch grade {
        case .forgot:
            next.repetitions = 0
            next.lapses += 1
            next.ease = max(minimumEase, state.ease - 0.2)
            next.interval = 1
        case .fuzzy:
            next.ease = max(minimumEase, state.ease - 0.15)
            next.interval = max(1, (state.interval * 1.2).rounded(.up))
        case .good:
            next.repetitions = state.repetitions + 1
            switch next.repetitions {
            case 1: next.interval = 1
            case 2: next.interval = 3
            default: next.interval = max(state.interval + 1, (state.interval * state.ease).rounded())
            }
        }
        next.due = day(after: Int(next.interval), from: now, calendar: calendar)
        return next
    }

    static func day(after days: Int, from date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: max(days, 0), to: start) ?? date
    }
}
