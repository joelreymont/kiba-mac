import Foundation

/// How a saved account's row reads at a glance.
public enum RowState: Sendable {
    /// At least half of every deciding window is left.
    case ok
    /// Under half of the session (or of a long model window) is left.
    case tight
    /// A window is used up.
    case blocked
    /// The saved login no longer works.
    case dead
    /// The organization has no plan the CLI may use.
    case unsubscribed
    /// No usage data.
    case unknown
}

/// One right-hand figure: a window and the whole percent of it left.
public struct Figure: Equatable, Sendable {
    public var label: String
    public var left: Int

    public init(label: String, left: Int) {
        self.label = label
        self.left = left
    }
}

/// Row logic of the panel (port of kiba `Panel.qml`): pure functions of
/// usage records and the clock.
public enum Rows {
    /// A weekly or monthly window; anything else is a session.
    public static func isLong(_ label: String) -> Bool {
        Mark.long.contains { label.range(of: $0, options: .caseInsensitive) != nil }
    }

    public static func session(_ u: UsageRecord?) -> Limit? {
        guard let u, let i = first(u, long: false) else { return nil }
        return u.limits[i]
    }

    public static func weekly(_ u: UsageRecord?) -> Limit? {
        guard let u, let i = first(u, long: true) else { return nil }
        return u.limits[i]
    }

    /// The used-up window that reopens last; the first used-up one when no
    /// later reset parses.
    public static func blocking(_ u: UsageRecord?) -> Limit? {
        guard let u else { return nil }
        var worst: Limit?
        var worstAt: Date?
        for l in u.limits where l.percent >= Level.full {
            let at = parseISO(l.resetsAt)
            guard worst != nil else {
                (worst, worstAt) = (l, at)
                continue
            }
            if let at, worstAt.map({ at > $0 }) ?? true { (worst, worstAt) = (l, at) }
        }
        return worst
    }

    /// The window that decides the color: the session, else the long one.
    public static func headline(_ u: UsageRecord?) -> Limit? {
        session(u) ?? weekly(u)
    }

    /// The saved login no longer works. An expired live token is the CLI's
    /// to refresh, so only a saved one counts.
    public static func dead(_ u: UsageRecord?, active: Bool) -> Bool {
        guard let u else { return false }
        return u.state == .revoked || (u.state == .expired && !active)
    }

    /// A dead Claude row: it reads "free?", a guess that the plan lapsed,
    /// and a probe counts it as answered. A dead Codex row asks to log in
    /// again.
    public static func maybeFree(_ p: Provider, _ u: UsageRecord?, active: Bool) -> Bool {
        p == .claude && dead(u, active: active)
    }

    public static func state(_ u: UsageRecord?, active: Bool) -> RowState {
        if dead(u, active: active) { return .dead }
        if u?.state == .unsubscribed { return .unsubscribed }
        guard let u, !u.limits.isEmpty else { return .unknown }
        if u.limits.contains(where: { $0.percent >= Level.full }) { return .blocked }
        if let h = headline(u), Level.full - h.percent < Level.half { return .tight }
        let week = first(u, long: true)
        for (i, l) in u.limits.enumerated()
        where i != week && isLong(l.label) && Level.full - l.percent < Level.half {
            return .tight
        }
        return .ok
    }

    /// Room first, then running low, then used up, dead or without a plan,
    /// then unknown.
    public static func rank(_ s: RowState) -> Int {
        switch s {
        case .ok: return Rank.ok
        case .tight: return Rank.tight
        case .blocked, .dead, .unsubscribed: return Rank.out
        case .unknown: return Rank.unknown
        }
    }

    /// By rank; used-up and dead rows by when they reopen, soonest first and
    /// the ones with no parseable reset last; otherwise the input order.
    public static func sorted(_ a: [Account]) -> [Account] {
        let keyed = a.enumerated().map { (i, acc) -> (rank: Int, at: Double, idx: Int) in
            let r = rank(state(acc.usage, active: acc.active))
            guard r == Rank.out, let b = blocking(acc.usage), let at = parseISO(b.resetsAt) else {
                return (r, .infinity, i)
            }
            return (r, at.timeIntervalSince1970, i)
        }
        return keyed.sorted { ($0.rank, $0.at, $0.idx) < ($1.rank, $1.at, $1.idx) }.map { a[$0.idx] }
    }

    /// Session, weekly, then every other window with a reading, in order.
    public static func figures(_ u: UsageRecord?) -> [Figure] {
        guard let u else { return [] }
        let s = first(u, long: false), w = first(u, long: true)
        var out: [Figure] = []
        for i in [s, w].compactMap({ $0 }) { out.append(figure(u.limits[i])) }
        for (i, l) in u.limits.enumerated() where i != s && i != w && l.percent >= 0 {
            out.append(figure(l))
        }
        return out
    }

    /// Under half of the window is left: the segment draws in `low`.
    public static func isLow(_ f: Figure) -> Bool {
        f.left < Level.half
    }

    /// Whether the account can take work now; nil while its usage is unknown.
    /// The status dot's verdict.
    public static func usable(_ s: RowState) -> Bool? {
        switch s {
        case .ok, .tight: return true
        case .blocked, .dead, .unsubscribed: return false
        case .unknown: return nil
        }
    }

    /// The bar shows every window empty: the login is gone or has no plan,
    /// so no window holds anything usable. A limited account keeps its
    /// windows' levels, since one used-up window leaves the others open.
    public static func drained(_ s: RowState) -> Bool {
        s == .dead || s == .unsubscribed
    }

    /// `"72% · 40% · 9%"`, or `"limit"` while a window is used up.
    public static func figuresText(_ u: UsageRecord?) -> String {
        if state(u, active: false) == .blocked { return Copy.limit }
        return figures(u).map { "\($0.left)%" }.joined(separator: Copy.figureSep)
    }

    /// The saved plan, or "no plan" for an unsubscribed row: the token
    /// document still claims the plan the organization no longer has.
    public static func plan(_ a: Account) -> String {
        a.usage?.state == .unsubscribed ? Copy.noPlan : a.plan
    }

    /// `"(pro)"`, `"(pro, 5d)"` while blocked, `"(pro, log in again)"` when
    /// dead, `"(free?)"` in its place on Claude, `"(no plan)"` when
    /// unsubscribed, or "".
    public static func planText(_ p: Provider, _ a: Account, now: Date) -> String {
        if maybeFree(p, a.usage, active: a.active) { return "(" + Copy.free + ")" }
        var parts: [String] = []
        let label = plan(a)
        if !label.isEmpty { parts.append(label) }
        if let b = blocking(a.usage) {
            let when = resetShort(b.resetsAt, now: now)
            if !when.isEmpty { parts.append(when) }
        }
        if dead(a.usage, active: a.active) { parts.append(Copy.again) }
        return parts.isEmpty ? "" : "(" + parts.joined(separator: Copy.planSep) + ")"
    }

    /// Hover lines: identity, one line per window, the limit resets on offer,
    /// probe age, what a click does.
    public static func tooltip(_ p: Provider, _ a: Account, now: Date) -> [String] {
        var head = a.name.raw
        let label = plan(a)
        if !label.isEmpty { head += Copy.lineSep + label }
        if a.active { head += Copy.lineSep + Copy.current }
        var lines = [head]
        if let u = a.usage {
            if u.limits.isEmpty {
                lines.append(u.note.isEmpty ? Copy.noLimits : u.note)
            } else {
                for l in u.limits {
                    let left = l.percent >= Level.full ? Copy.reached : "\(Level.full - l.percent)% left"
                    let when = l.resetsAt.isEmpty ? "" : " · resets in " + resetLong(l.resetsAt, now: now)
                    lines.append("\(l.label): \(left)\(when)")
                }
            }
            let n = resets(u)
            if n > 0 { lines.append(resetsText(n) + Copy.available) }
            if u.fetchedAt > 0 { lines.append("Probed " + age(u.fetchedAt, now: now)) }
        } else {
            lines.append(Copy.unprobed)
        }
        if dead(a.usage, active: a.active) {
            lines.append(Copy.relogin)
        } else if !a.active {
            lines.append("Click to switch \(p.title) to this account")
        }
        return lines
    }

    /// Limit resets the account can spend now; 0 without an offer.
    public static func resets(_ u: UsageRecord?) -> Int {
        u?.resets?.count ?? 0
    }

    /// `"1 limit reset"` or `"2 limit resets"`.
    public static func resetsText(_ n: Int) -> String {
        "\(n) " + (n == 1 ? Copy.reset : Copy.resets)
    }

    /// `"20m"`, `"5h"` under 36 hours, else `"2d"`; "" when unparseable.
    public static func resetShort(_ iso: String, now: Date) -> String {
        guard let at = parseISO(iso) else { return "" }
        let min = minutes(from: now, to: at)
        if min < Time.hourMinutes { return "\(min)m" }
        let h = rounded(Double(min) / Double(Time.hourMinutes))
        if h < Time.shortHours { return "\(h)h" }
        return "\(rounded(Double(h) / Double(Time.dayHours)))d"
    }

    /// `"20 min"`, `"5 h 12 min"` under 48 hours, else `"3 days"`; "" when unparseable.
    public static func resetLong(_ iso: String, now: Date) -> String {
        guard let at = parseISO(iso) else { return "" }
        let min = minutes(from: now, to: at)
        if min < Time.hourMinutes { return "\(min) min" }
        let h = min / Time.hourMinutes
        if h < Time.longHours { return "\(h) h \(min % Time.hourMinutes) min" }
        return "\(rounded(Double(h) / Double(Time.dayHours))) days"
    }

    /// `"just now"` or `"12 min ago"`.
    public static func age(_ epoch: Int, now: Date) -> String {
        let min = max(0, rounded((now.timeIntervalSince1970 - Double(epoch)) / Time.minute))
        return min < 1 ? Copy.justNow : "\(min) min ago"
    }

    /// `YYYY-MM-DDTHH:MM[:SS[.fraction]]` then `Z` or `±HH[:MM]`; nil for
    /// anything else, including a missing zone.
    public static func parseISO(_ s: String) -> Date? {
        var p = Scan(s)
        guard let y = p.digits(4), p.take(Char.dash), let mo = p.digits(2), p.take(Char.dash),
              let d = p.digits(2), p.take(Char.t), let h = p.digits(2), p.take(Char.colon),
              let mi = p.digits(2) else { return nil }
        var sec = 0
        var frac = 0.0
        if p.take(Char.colon) {
            guard let v = p.digits(2) else { return nil }
            sec = v
            if p.take(Char.dot) {
                guard let f = p.fraction() else { return nil }
                frac = f
            }
        }
        guard let off = p.zone(), p.done,
              (1...Time.months).contains(mo), (1...Time.days(mo, y)).contains(d),
              h < Time.dayHours, mi < Time.hourMinutes, sec < Time.minuteSeconds else { return nil }
        let clock = (h * Time.hourMinutes + mi) * Time.minuteSeconds + sec
        let epoch = Time.civil(y, mo, d) * Time.daySeconds + clock - off
        return Date(timeIntervalSince1970: Double(epoch) + frac)
    }

    private static func first(_ u: UsageRecord, long: Bool) -> Int? {
        u.limits.firstIndex { isLong($0.label) == long && $0.percent >= 0 }
    }

    private static func figure(_ l: Limit) -> Figure {
        Figure(label: l.label, left: Level.full - l.percent)
    }

    private static func minutes(from now: Date, to at: Date) -> Int {
        max(0, rounded(at.timeIntervalSince(now) / Time.minute))
    }

    /// Half away from zero, as the panel's figures always were.
    private static func rounded(_ v: Double) -> Int {
        Int(v.rounded(.toNearestOrAwayFromZero))
    }

    private enum Level {
        static let full = 100
        static let half = 50
    }

    private enum Rank {
        static let ok = 0
        static let tight = 1
        static let out = 2
        static let unknown = 3
    }

    private enum Mark {
        static let long = ["week", "7-day", "month", "30-day"]
    }

    private enum Copy {
        static let limit = "limit"
        static let again = "log in again"
        static let free = "free?"
        static let noPlan = "no plan"
        static let current = "current"
        static let unprobed = "Usage not probed yet"
        static let noLimits = "No limits reported"
        static let reached = "limit reached"
        static let reset = "limit reset"
        static let resets = "limit resets"
        static let available = " available"
        static let relogin = "Click to log in to this account again"
        static let justNow = "just now"
        static let figureSep = " · "
        static let lineSep = " · "
        static let planSep = ", "
    }

    private enum Char {
        static let dash = UInt8(ascii: "-")
        static let colon = UInt8(ascii: ":")
        static let dot = UInt8(ascii: ".")
        static let t = UInt8(ascii: "T")
        static let z = UInt8(ascii: "Z")
        static let plus = UInt8(ascii: "+")
        static let zero = UInt8(ascii: "0")
        static let nine = UInt8(ascii: "9")
    }

    private enum Time {
        static let minute = 60.0
        static let minuteSeconds = 60
        static let hourMinutes = 60
        static let dayHours = 24
        static let daySeconds = 86_400
        static let shortHours = 36
        static let longHours = 48
        static let months = 12
        static let february = 2
        static let monthDays = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

        static func days(_ month: Int, _ year: Int) -> Int {
            guard (1...months).contains(month) else { return 0 }
            let leap = year % leapEvery == 0 && (year % centuryYears != 0 || year % eraYears == 0)
            return monthDays[month - 1] + (month == february && leap ? 1 : 0)
        }

        /// Days from 1970-01-01 to a proleptic Gregorian date: Howard
        /// Hinnant's `days_from_civil`, which counts years from March so the
        /// leap day ends each year.
        static func civil(_ year: Int, _ month: Int, _ day: Int) -> Int {
            let y = month <= february ? year - 1 : year
            let era = (y >= 0 ? y : y - (eraYears - 1)) / eraYears
            let yoe = y - era * eraYears
            let mp = (month + marchShift) % months
            let doy = (monthSpan * mp + monthRound) / monthCycle + day - 1
            let doe = yoe * yearDays + yoe / leapEvery - yoe / centuryYears + doy
            return era * eraDays + doe - epochDays
        }

        /// A Gregorian cycle: 400 years, 146 097 days.
        static let eraYears = 400
        static let eraDays = 146_097
        static let yearDays = 365
        static let leapEvery = 4
        static let centuryYears = 100
        /// Month index counted from March.
        static let marchShift = 9
        /// Days before month `mp` (from March) are `(153 * mp + 2) / 5`.
        static let monthSpan = 153
        static let monthRound = 2
        static let monthCycle = 5
        /// Days from 0000-03-01 to 1970-01-01.
        static let epochDays = 719_468
    }

    /// Byte cursor over an ISO 8601 string.
    private struct Scan {
        let b: String.UTF8View
        var i: String.UTF8View.Index

        init(_ s: String) {
            b = s.utf8
            i = b.startIndex
        }

        private static let radix = 10

        var done: Bool { i == b.endIndex }

        mutating func take(_ c: UInt8) -> Bool {
            guard i != b.endIndex, b[i] == c else { return false }
            b.formIndex(after: &i)
            return true
        }

        mutating func digit() -> Int? {
            guard i != b.endIndex, (Char.zero...Char.nine).contains(b[i]) else { return nil }
            defer { b.formIndex(after: &i) }
            return Int(b[i] - Char.zero)
        }

        mutating func digits(_ n: Int) -> Int? {
            var v = 0
            for _ in 0..<n {
                guard let d = digit() else { return nil }
                v = v * Self.radix + d
            }
            return v
        }

        /// One or more digits after the decimal point.
        mutating func fraction() -> Double? {
            var v = 0.0
            var scale = 0.1
            var any = false
            while let d = digit() {
                v += Double(d) * scale
                scale /= Double(Self.radix)
                any = true
            }
            return any ? v : nil
        }

        /// Seconds east of UTC.
        mutating func zone() -> Int? {
            if take(Char.z) { return 0 }
            let sign: Int
            if take(Char.plus) {
                sign = 1
            } else if take(Char.dash) {
                sign = -1
            } else {
                return nil
            }
            guard let h = digits(2), h < Time.dayHours else { return nil }
            var m = 0
            if take(Char.colon) {
                guard let v = digits(2) else { return nil }
                m = v
            } else if !done {
                guard let v = digits(2) else { return nil }
                m = v
            }
            guard m < Time.hourMinutes else { return nil }
            return sign * (h * Time.hourMinutes + m) * Time.minuteSeconds
        }
    }
}
