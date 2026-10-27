import Foundation

/// « 12:34 » ou « 1:02:03 ».
func timecode(_ seconds: Double) -> String {
    let total = max(Int(seconds), 0)
    let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// « 21:00 », précédé du jour quand ce n'est pas aujourd'hui.
func airTime(_ date: Date) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    guard !Calendar.current.isDateInToday(date) else { return time }
    return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
}
