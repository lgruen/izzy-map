import Foundation

/// The words a pin and a project go by (docs/PINS_PLAN.md §5). One title
/// rule for every place a pin is named — list rows, the card's empty title
/// field, the map's label (folded to Latin-1 there, `PinPresenter.label`).
nonisolated enum PinText {
    /// Longest first line of a note used as a name (a paragraph is no title).
    static let noteTitleLimit = 40

    /// The title if it has one; else the note's first line; else "Pin ·
    /// 24 Nov" (with the year when it isn't this year's).
    static func title(title: String, note: String, createdAt: Date, now: Date = Date()) -> String {
        name(title: title, note: note) ?? "Pin · \(shortDate(createdAt, now: now))"
    }

    /// The words a pin has of its own: its title, else its note's first
    /// line (clipped); nil for neither. The map labels a pin with this —
    /// never with the date stand-in, which would clutter (decided by the
    /// user, 2026-11-24).
    static func name(title: String, note: String) -> String? {
        let own = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { return own }
        return firstLine(note).map { clipped($0, to: noteTitleLimit) }
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
    /// What this pin is called everywhere (`PinText.title`).
    nonisolated var displayTitle: String { PinText.title(title: title, note: note, createdAt: createdAt) }
}
