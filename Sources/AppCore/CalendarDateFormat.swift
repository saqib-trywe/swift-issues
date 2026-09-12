import Core
import Foundation

/// Renders a `CivilDate` without ever converting a timezone.
///
/// A due date is a calendar day, not an instant. Put through an ordinary date
/// formatter it shifts: 1 January in London renders as 31 December for a reader in
/// Los Angeles, so a task due on the first appears overdue. Ticket 10 requires a
/// calendar-date formatter for exactly this reason.
///
/// The trick is to be explicit rather than careful: the components are anchored at
/// **midday GMT** and formatted in **GMT**, so there is no zone left for anything
/// to shift into. Midday rather than midnight so no daylight-saving transition can
/// move the day either.
public struct CalendarDateFormat: Sendable {
    private let locale: Locale

    public init(locale: Locale = .autoupdatingCurrent) {
        self.locale = locale
    }

    /// A date a person reads, like "25 December 2026".
    public func string(for date: CivilDate) -> String {
        format(date, style: .long)
    }

    /// A date that has to fit in a table column, like "25 Dec 2026".
    public func short(for date: CivilDate) -> String {
        format(date, style: .medium)
    }

    private func format(_ date: CivilDate, style: DateFormatter.Style) -> String {
        var calendar = Calendar(identifier: .gregorian)
        let gmt = TimeZone(secondsFromGMT: 0)!
        calendar.timeZone = gmt

        var components = DateComponents()
        components.year = date.year
        components.month = date.month
        components.day = date.day
        // Midday, so no daylight-saving transition can land on this instant and
        // move the day.
        components.hour = 12

        guard let instant = calendar.date(from: components) else { return date.wireValue }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = gmt
        formatter.dateStyle = style
        formatter.timeStyle = .none
        return formatter.string(from: instant)
    }
}
