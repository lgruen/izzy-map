import Foundation

/// The words a pin and a project go by (docs/PINS_PLAN.md §5). One title
/// rule for every place a pin is named — list rows, the Undo pill, the
/// Delete-now dialog, the photo viewer, the export's headings: its own
/// title, else "Untitled pin". A note is never a title (I-20); the map
/// draws a label only for a title (`PinPresenter.label`).
nonisolated enum PinText {
    /// What an untitled pin is called wherever a title is shown.
    static let untitled = "Untitled pin"

    /// The pin's own title, else "Untitled pin".
    static func title(_ title: String) -> String {
        let own = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? untitled : own
    }

    /// The first line of `text` with words in it, trimmed.
    static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// Cut on a word boundary with an ellipsis when longer than `limit`.
    static func clipped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        let cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }

    /// "24 Nov", or "24 Nov 2025" in another year.
    static func shortDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(sameYear ? style : style.year())
    }

    /// "3–24 Nov", "28 Oct – 3 Nov", "24 Nov"; with the year when the range
    /// isn't all in this year. nil for no dates.
    static func dateRange(_ dates: [Date], now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let first = dates.min(), let last = dates.max() else { return nil }
        let end = shortDate(last, now: now, calendar: calendar)
        if calendar.isDate(first, inSameDayAs: last) { return end }
        // built from `shortDate` itself, so a range reads exactly like the
        // single dates beside it ("23 Nov" rows under "11–23 Nov")
        if calendar.isDate(first, equalTo: last, toGranularity: .month), end.first?.isNumber == true {
            return "\(first.formatted(.dateTime.day()))–\(end)"
        }
        return "\(shortDate(first, now: now, calendar: calendar)) – \(end)"
    }

    /// When a pin was placed or a photo taken — "15 Nov 2026, 08:47" (the
    /// time as the device writes it, 12 or 24 hours): the card's Placed
    /// line and the photo viewer say it the same way.
    static func dateTime(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var day = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        day.locale = locale
        day.timeZone = timeZone
        var time = Date.FormatStyle(date: .omitted, time: .shortened)
        time.locale = locale
        time.timeZone = timeZone
        return "\(date.formatted(day)), \(date.formatted(time))"
    }

    /// "1 pin", "12 pins".
    static func count(_ n: Int) -> String { "\(n.formatted()) \(n == 1 ? "pin" : "pins")" }

    /// "1 photo", "12 photos".
    static func photoCount(_ n: Int) -> String { "\(n.formatted()) \(n == 1 ? "photo" : "photos")" }

    /// "12 pins · 5 photos"; just "12 pins" while none has a photo.
    static func count(pins: Int, photos: Int) -> String {
        photos > 0 ? "\(count(pins)) · \(photoCount(photos))" : count(pins)
    }

    /// A project's name, or a stand-in for an empty one.
    static func projectName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled project" : trimmed
    }
}

extension SavedPin {
    /// What this pin is called everywhere: its title, else "Untitled pin"
    /// (`PinText.title`).
    nonisolated var displayTitle: String { PinText.title(title) }
}
