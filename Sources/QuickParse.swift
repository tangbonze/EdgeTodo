import Foundation

/// 极简自然语言时间解析：把「明天 9:00 交报告」拆成 标题 + 提醒时间
enum QuickParse {
    struct Result {
        let title: String
        let due: Date?
        var hasDue: Bool { due != nil }
    }

    static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> Result {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return Result(title: "", due: nil) }

        var dayOffset: Int?
        var impliedHour: Int?
        var relativeMinutes: Int?

        // 0. 中文数字小时 → 阿拉伯数字（四点 → 4点）；顺带把「点四十」这种中文分钟也转掉
        text = chineseMinutes(chineseHourToArabic(text))
        // 0.2 「十分钟后 / 两个小时之后」里的中文数字
        text = chineseDurations(text)

        // 0.5 相对时间：十分钟后 / 半小时后 / 一刻钟之后
        for (pattern, mult) in [("(\\d{1,2})\\s*分钟\\s*之?后", 1),
                                ("(\\d{1,2})\\s*个?\\s*小时\\s*之?后", 60)] {
            if let hit = firstMatch(text, pattern), let n = Int(hit.groups[0]) {
                relativeMinutes = n * mult
                text.removeSubrange(hit.range)
                text = text.trimmingCharacters(in: .whitespaces)
                break
            }
        }
        if relativeMinutes == nil,
           let hit = firstMatch(text, "半\\s*个?\\s*小时\\s*之?后") {
            relativeMinutes = 30
            text.removeSubrange(hit.range)
            text = text.trimmingCharacters(in: .whitespaces)
        }
        if relativeMinutes == nil,
           let hit = firstMatch(text, "一刻钟\\s*之?后") {
            relativeMinutes = 15
            text.removeSubrange(hit.range)
            text = text.trimmingCharacters(in: .whitespaces)
        }

        // 1. 日期词：出现在任意位置（长词优先）
        let dayWords: [(String, Int, Int?)] = [
            ("大后天", 3, nil), ("后天", 2, nil), ("明天", 1, nil), ("今天", 0, nil),
            ("明晚", 1, 20), ("今晚", 0, 20), ("明早", 1, 9), ("明晨", 1, 9)
        ]
        for (word, offset, hour) in dayWords {
            if let range = text.range(of: word) {
                dayOffset = offset
                impliedHour = hour
                text.removeSubrange(range)
                text = text.trimmingCharacters(in: .whitespaces)
                break
            }
        }

        // 1.5 星期：周一 / 下周三 / 星期五
        if dayOffset == nil,
           let hit = firstMatch(text, #"(下周|下星期|周|星期|礼拜)([一二三四五六日天])"#),
           let ch = hit.groups[1].first {
            let map: [Character: Int] = ["一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7, "日": 1, "天": 1]
            if let target = map[ch] {
                let todayWeekday = calendar.component(.weekday, from: now)
                var delta = (target - todayWeekday + 7) % 7
                if delta == 0 { delta = 7 }
                dayOffset = delta
                text.removeSubrange(hit.range)
                text = text.trimmingCharacters(in: .whitespaces)
            }
        }

        // 2. 时段词
        var periodHour: Int?
        for (word, hour) in [("上午", 9), ("早上", 9), ("中午", 12), ("下午", 15), ("傍晚", 18), ("晚上", 20)] {
            if let range = text.range(of: word) {
                periodHour = hour
                text.removeSubrange(range)
                text = text.trimmingCharacters(in: .whitespaces)
            }
        }

        // 3. 具体时间 HH:MM / X点 / X点半
        var hour: Int?
        var minute: Int?

        if let hit = firstMatch(text, #"(\d{1,2})\s*[:：]\s*(\d{1,2})"#) {
            hour = Int(hit.groups[0])
            minute = Int(hit.groups[1]) ?? 0
            text.removeSubrange(hit.range)
        } else if let hit = firstMatch(text, #"(\d{1,2})\s*点\s*半"#) {
            hour = Int(hit.groups[0])
            minute = 30
            text.removeSubrange(hit.range)
        } else if let hit = firstMatch(text, #"(\d{1,2})\s*点\s*(\d{1,2})?\s*分?"#) {
            hour = Int(hit.groups[0])
            minute = hit.groups.count > 1 ? (Int(hit.groups[1]) ?? 0) : 0
            text.removeSubrange(hit.range)
        }

        // 下午 3:00 → 15:00；今晚 8点 → 20:00
        if let h = hour, h < 12, let p = periodHour ?? impliedHour, p >= 12 {
            hour = (h + 12 > 23) ? h : h + 12
        }

        let title = stripFillers(text
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t,，、。;；-—")))

        guard dayOffset != nil || hour != nil || impliedHour != nil || relativeMinutes != nil else {
            return Result(title: raw.trimmingCharacters(in: .whitespacesAndNewlines), due: nil)
        }

        let fallbackTitle = title.isEmpty ? "新提醒" : title

        // 相对时间直接按「现在 + N 分钟」算
        if let minutes = relativeMinutes {
            return Result(title: fallbackTitle, due: now.addingTimeInterval(Double(minutes) * 60))
        }

        let base = calendar.startOfDay(for: now)
        guard let day = calendar.date(byAdding: .day, value: dayOffset ?? 0, to: base) else {
            return Result(title: fallbackTitle, due: nil)
        }
        let h = hour ?? impliedHour ?? 9
        let m = minute ?? 0
        guard var due = calendar.date(bySettingHour: h, minute: m, second: 0, of: day) else {
            return Result(title: fallbackTitle, due: nil)
        }
        // 只给了时间且已经过了 → 顺延到明天
        if dayOffset == nil, due < now {
            due = due.addingTimeInterval(24 * 3600)
        }

        return Result(title: fallbackTitle, due: due)
    }

    // MARK: 中文数字

    /// 把「四点」「十一点」「两点」里的中文数字转成阿拉伯数字
    private static func chineseHourToArabic(_ input: String) -> String {
        let table: [String: String] = [
            "一": "1", "二": "2", "两": "2", "三": "3", "四": "4", "五": "5",
            "六": "6", "七": "7", "八": "8", "九": "9", "十": "10",
            "十一": "11", "十二": "12"
        ]
        // 长词优先，避免「十一」被拆成「十」+「一」
        let keys = ["十二", "十一", "十", "两", "一", "二", "三", "四", "五", "六", "七", "八", "九"]

        var out = ""
        var i = input.startIndex
        while i < input.endIndex {
            var replaced = false
            for key in keys {
                guard input[i...].hasPrefix(key) else { continue }
                let after = input.index(i, offsetBy: key.count)
                // 只有紧跟「点」的才当小时数，避免动到普通文字
                if after < input.endIndex, input[after] == "点" {
                    out += table[key] ?? key
                    i = after
                    replaced = true
                    break
                }
            }
            if !replaced {
                out.append(input[i])
                i = input.index(after: i)
            }
        }
        return out
    }

    /// 「三点四十」→「3点40」：把紧跟「点」后面的中文分钟数也转成数字
    private static func chineseMinutes(_ input: String) -> String {
        var out = input.replacingOccurrences(of: "点一刻", with: "点15")
        let tens = ["十": "10", "二十": "20", "三十": "30", "四十": "40", "五十": "50"]
        for (k, v) in tens { out = out.replacingOccurrences(of: "点" + k, with: "点" + v) }
        let ones = ["一": "1", "二": "2", "三": "3", "四": "4", "五": "5",
                    "六": "6", "七": "7", "八": "8", "九": "9"]
        for (k, v) in ones { out = out.replacingOccurrences(of: "点" + k, with: "点" + v) }
        return out
    }

    /// 「十分钟后」「两个小时之后」→ 先把中文数字换成阿拉伯数字
    private static func chineseDurations(_ input: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "([一二两三四五六七八九十]{1,3})\\s*(分钟|个?\\s*小时)") else { return input }
        let ns = input as NSString
        let matches = re.matches(in: input, range: NSRange(location: 0, length: ns.length))
        var out = input
        for m in matches.reversed() {
            guard let r = Range(m.range, in: out) else { continue }
            let numStr = ns.substring(with: m.range(at: 1))
            guard let n = chineseNumber(numStr) else { continue }
            let unit = ns.substring(with: m.range(at: 2)).replacingOccurrences(of: " ", with: "")
            out.replaceSubrange(r, with: "\(n)\(unit)")
        }
        return out
    }

    /// 支持 一 ~ 九十九 这类中文数字
    private static func chineseNumber(_ s: String) -> Int? {
        if s == "两" { return 2 }
        if s == "十" { return 10 }
        if s.hasPrefix("十") { return 10 + (chineseNumber(String(s.dropFirst())) ?? 0) }
        if s.hasSuffix("十") { return (chineseNumber(String(s.dropLast())) ?? 0) * 10 }
        if let i = s.firstIndex(of: "十") {
            let a = chineseNumber(String(s[s.startIndex..<i])) ?? 0
            let b = chineseNumber(String(s[s.index(after: i)...])) ?? 0
            return a * 10 + b
        }
        let digits: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4,
                                        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        guard s.count == 1, let c = s.first, let d = digits[c] else { return nil }
        return d
    }

    // MARK: 口语填充词
    /// 语音转出来的句子常带「提醒我」「帮我记一下」这类口头语，去掉它们才像一条待办
    private static let fillers = [
        "提醒我一下", "提醒我", "提醒下", "提醒", "帮我记一下", "帮我记", "帮我",
        "麻烦", "请", "记一下", "记录一下", "记个", "记得", "别忘了", "别忘",
        "添加一个", "添加", "新建一个", "新建", "创建一个", "创建", "安排一下", "安排"
    ]

    private static func stripFillers(_ input: String) -> String {
        let trimSet = CharacterSet(charactersIn: " \t,，、。：:；;")
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed, !text.isEmpty {
            changed = false
            for f in fillers {
                if text.hasPrefix(f), text.count > f.count {
                    text.removeFirst(f.count)
                    text = text.trimmingCharacters(in: trimSet)
                    changed = true
                    break
                }
                if text.hasSuffix(f), text.count > f.count {
                    text.removeLast(f.count)
                    text = text.trimmingCharacters(in: trimSet)
                    changed = true
                    break
                }
            }
        }
        return text
    }

    // MARK: 正则辅助

    private struct Match {
        let range: Range<String.Index>
        let groups: [String]
    }

    private static func firstMatch(_ string: String, _ pattern: String) -> Match? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = string as NSString
        guard let m = re.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var groups: [String] = []
        for i in 1..<m.numberOfRanges {
            let r = m.range(at: i)
            groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        guard let range = Range(m.range, in: string) else { return nil }
        return Match(range: range, groups: groups)
    }
}
