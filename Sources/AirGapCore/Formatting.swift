import Foundation

public enum Formatting {
    /// "2h 05m", "12m", "45s" — for usage totals.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total % 60)s"
    }

    /// "8:00:00" or "59:59" — for the focus countdown.
    public static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded(.up)), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// "15m", "1h" — for session length pickers.
    public static func length(minutes: Int) -> String {
        minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
    }
}

public enum HTML {
    /// Escapes text for safe insertion into the block page.
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
