import Foundation

/// "1 server", "3 servers".
func counted(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}

extension Date {
    /// "3 min. ago", measured from `now` so every caption on screen ages together.
    func relativeDescription(from now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: now)
    }
}
