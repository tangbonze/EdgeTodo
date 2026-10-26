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
        var periodHour: Int?
        var hour: Int?
        var minute: Int?

        // 0. 中文数字小时 → 阿拉伯数字（四点 → 4点）；顺带把「点四十」这种中文分钟也转掉
        text = chineseMinutes(chineseHourToArabic(text))
        // 0.2 「十分钟后 / 两个小时之后」里的中文数字
        text = chineseDurations(text)

        // 0.4 英文：in 10 min / tomorrow 9am / next monday / tonight
        //     只认 ASCII 词，中文句子不会误伤；中英混写时两边都能取到
        let en = extractEnglish(text, now: now, calendar: calendar)
        text = en.rest
        dayOffset = en.hit.dayOffset
        impliedHour = en.hit.impliedHour
        relativeMinutes = en.hit.relativeMinutes
        periodHour = en.hit.periodHour
        hour = en.hit.hour
        minute = en.hit.minute

        // 0.5 相对时间：十分钟后 / 半小时后 / 一刻钟之后
        if relativeMinutes == nil {
            for (pattern, mult) in [("(\\d{1,2})\\s*分钟\\s*之?后", 1),
                                    ("(\\d{1,2})\\s*个?\\s*小时\\s*之?后", 60)] {
                if let hit = firstMatch(text, pattern), let n = Int(hit.groups[0]) {
                    relativeMinutes = n * mult
                    text.removeSubrange(hit.range)
                    text = text.trimmingCharacters(in: .whitespaces)
                    break
                }
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
        if dayOffset == nil {
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
        if periodHour == nil {
            for (word, hour) in [("上午", 9), ("早上", 9), ("中午", 12), ("下午", 15), ("傍晚", 18), ("晚上", 20)] {
                if let range = text.range(of: word) {
                    periodHour = hour
                    text.removeSubrange(range)
                    text = text.trimmingCharacters(in: .whitespaces)
                }
            }
        }

        // 3. 具体时间 HH:MM / X点 / X点半
        if hour == nil {
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
        }

        // 下午 3:00 → 15:00；今晚 8点 → 20:00
        if let h = hour, h < 12, let p = periodHour ?? impliedHour, p >= 12 {
            hour = (h + 12 > 23) ? h : h + 12
        }
        // 只说了「afternoon」没说几点 → 按该时段的常用时刻
        if hour == nil, let p = periodHour ?? impliedHour {
            hour = p
        }

        let title = stripFillers(trimEnglishStops(text
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t,，、。;；-—.:!?"))))

        guard dayOffset != nil || hour != nil || impliedHour != nil || relativeMinutes != nil else {
            return Result(title: raw.trimmingCharacters(in: .whitespacesAndNewlines), due: nil)
        }

        let fallbackTitle = title.isEmpty ? L10n.t("新提醒", "New Reminder") : title

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

    // MARK: 英文
    private struct EnglishHit {
        var dayOffset: Int?
        var impliedHour: Int?
        var periodHour: Int?
        var relativeMinutes: Int?
        var hour: Int?
        var minute: Int?
    }

    /// 英文时间表达：in 10 min / tomorrow 9am / next monday / tonight / noon …
    /// 返回抽出来的时间信息和「剩下的文字」，剩下的继续交给中文规则兜底
    private static func extractEnglish(_ input: String, now: Date, calendar: Calendar)
        -> (hit: EnglishHit, rest: String) {
        var hit = EnglishHit()
        var text = input

        guard text.rangeOfCharacter(from: CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")) != nil else {
            return (hit, text)
        }

        /// 命中即摘掉，返回捕获组
        func take(_ pattern: String) -> [String]? {
            guard let m = firstMatch(text, pattern) else { return nil }
            text.removeSubrange(m.range)
            text = text.trimmingCharacters(in: .whitespaces)
            return m.groups
        }

        // 1. 相对时间：in 10 minutes / in half an hour / in an hour
        if let g = take(#"(?i)\bin\s+(\d{1,3})\s*(minutes?|mins?|hours?|hrs?)\b"#),
           let n = Int(g[0]) {
            hit.relativeMinutes = g[1].lowercased().hasPrefix("h") ? n * 60 : n
        } else if take(#"(?i)\bin\s+half\s+an?\s+hour\b"#) != nil {
            hit.relativeMinutes = 30
        } else if take(#"(?i)\bin\s+an?\s+hour\b"#) != nil {
            hit.relativeMinutes = 60
        } else if let g = take(#"(?i)\bin\s+(\d{1,2})\s*(?:days?)\b"#), let n = Int(g[0]) {
            hit.dayOffset = n
        }

        // 2. this morning / this afternoon / this evening
        if let g = take(#"(?i)\bthis\s+(morning|afternoon|evening|night)\b"#) {
            hit.dayOffset = 0
            hit.impliedHour = englishPeriodHour(g[0])
        }

        // 3. 日期短语，长词优先
        if hit.dayOffset == nil {
            let phrases: [(String, Int, Int?)] = [
                (#"(?i)\bthe\s+day\s+after\s+tomorrow\b"#, 2, nil),
                (#"(?i)\btomorrow\s+night\b"#, 1, 20),
                (#"(?i)\btomorrow\s+morning\b"#, 1, 9),
                (#"(?i)\btomorrow\s+afternoon\b"#, 1, 15),
                (#"(?i)\btomorrow\s+evening\b"#, 1, 18),
                (#"(?i)\b(?:tomorrow|tmrw|tmw|tmr)\b"#, 1, nil),
                (#"(?i)\btonight\b"#, 0, 20),
                (#"(?i)\btoday\b"#, 0, nil),
                (#"(?i)\bnext\s+week\b"#, 7, nil)
            ]
            for (pattern, offset, hour) in phrases where take(pattern) != nil {
                hit.dayOffset = offset
                hit.impliedHour = hour
                break
            }
        }

        // 4. 星期：monday / next friday / sat
        if hit.dayOffset == nil,
           let g = take(#"(?i)\b(?:(?:next|this|on)\s+)?(monday|mon|tuesday|tues|tue|wednesday|weds|wed|thursday|thurs|thur|thu|friday|fri|saturday|sat|sunday|sun)\b"#) {
            let key = String(g[0].lowercased().prefix(3))
            let map: [String: Int] = ["mon": 2, "tue": 3, "wed": 4, "thu": 5,
                                      "fri": 6, "sat": 7, "sun": 1]
            if let target = map[key] {
                let todayWeekday = calendar.component(.weekday, from: now)
                var delta = (target - todayWeekday + 7) % 7
                if delta == 0 { delta = 7 }
                hit.dayOffset = delta
            }
        }

        // 5. noon / midnight 是确切时刻
        if hit.hour == nil, take(#"(?i)\b(?:at\s+)?noon\b"#) != nil {
            hit.hour = 12
            hit.minute = 0
        } else if hit.hour == nil, take(#"(?i)\b(?:at\s+)?midnight\b"#) != nil {
            hit.hour = 0
            hit.minute = 0
        }

        // 6. 时段词
        if hit.periodHour == nil {
            for word in ["morning", "afternoon", "evening", "night"] {
                if take(#"(?i)\b"# + word + #"\b"#) != nil {
                    hit.periodHour = englishPeriodHour(word)
                    break
                }
            }
        }

        // 7. 9am / at 9:30 pm
        if hit.hour == nil,
           let g = take(#"(?i)\b(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#),
           let h = Int(g[0]) {
            hit.minute = g[1].isEmpty ? 0 : (Int(g[1]) ?? 0)
            if g[2].lowercased().hasPrefix("p") {
                hit.hour = (h == 12) ? 12 : (h < 12 ? h + 12 : h)
            } else {
                hit.hour = (h == 12) ? 0 : h
            }
        }

        // 8. 9 o'clock
        if hit.hour == nil,
           let g = take(#"(?i)\b(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*o'?clock\b"#),
           let h = Int(g[0]) {
            hit.hour = h
            hit.minute = g[1].isEmpty ? 0 : (Int(g[1]) ?? 0)
        }

        // 9. at 9 / at 9:30
        if hit.hour == nil,
           let g = take(#"(?i)\bat\s+(\d{1,2})(?::(\d{2}))?\b"#),
           let h = Int(g[0]) {
            hit.hour = h
            hit.minute = g[1].isEmpty ? 0 : (Int(g[1]) ?? 0)
        }

        return (hit, text)
    }

    private static func englishPeriodHour(_ word: String) -> Int {
        switch word.lowercased() {
        case "morning": return 9
        case "noon": return 12
        case "afternoon": return 15
        case "evening": return 18
        case "night": return 20
        default: return 9
        }
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
        "please remind me to", "don't forget to", "dont forget to", "remember to",
        "remind me to", "remind me", "don't forget", "dont forget",
        "add a reminder", "add to my list", "please", "pls", "reminder",
        "提醒我一下", "提醒我", "提醒下", "提醒", "帮我记一下", "帮我记", "帮我",
        "麻烦", "请", "记一下", "记录一下", "记个", "记得", "别忘了", "别忘",
        "添加一个", "添加", "新建一个", "新建", "创建一个", "创建", "安排一下", "安排"
    ]

    /// 英文里摘掉时间词后常剩下孤零零的介词，做标题时要清掉
    private static let englishStops = ["at", "on", "in", "to", "for", "the", "and", "with"]

    private static func trimEnglishStops(_ input: String) -> String {
        let punct = CharacterSet(charactersIn: " \t,，、。;；-—.:!?")
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed, !text.isEmpty {
            changed = false
            let lower = text.lowercased()
            for stop in englishStops {
                if lower.hasPrefix(stop + " ") || lower.hasPrefix(stop + ",") {
                    text.removeFirst(stop.count)
                    text = text.trimmingCharacters(in: punct)
                    changed = true
                    break
                }
            }
        }
        return text
    }

    private static func stripFillers(_ input: String) -> String {
        let trimSet = CharacterSet(charactersIn: " \t,，、。：:；;")
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed, !text.isEmpty {
            changed = false
            let lower = text.lowercased()
            for f in fillers {
                if lower.hasPrefix(f), text.count > f.count {
                    text.removeFirst(f.count)
                    text = text.trimmingCharacters(in: trimSet)
                    changed = true
                    break
                }
                if lower.hasSuffix(f), text.count > f.count {
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
