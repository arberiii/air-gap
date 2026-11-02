import Foundation

/// Preferences kept in UserDefaults, not the state file, so deleting all data keeps them.
/// Read at the moment they're needed, so a change in Settings applies at once.
enum Preferences {
    enum Key {
        static let agent = "agent"
        static let claudeModel = "claudeModel"
        static let idleMinutes = "idleMinutes"
        static let quickAllowMinutes = "quickAllowMinutes"
    }

    static let claudeModels = ["haiku", "sonnet", "opus"]
    static let defaultClaudeModel = "sonnet"
    static let defaultIdleMinutes = 2
    static let defaultQuickAllowMinutes = 5

    /// The assistant picked in Settings, or nil when none was ever picked.
    static var agent: CoachAgent? {
        get { UserDefaults.standard.string(forKey: Key.agent).flatMap(CoachAgent.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: Key.agent) }
    }
    /// Codex uses the model from the user's own Codex config.
    static var claudeModel: String {
        UserDefaults.standard.string(forKey: Key.claudeModel).flatMap { claudeModels.contains($0) ? $0 : nil } ?? defaultClaudeModel
    }
    /// After this long without input, time stops counting.
    static var idleMinutes: Int { positive(Key.idleMinutes) ?? defaultIdleMinutes }
    /// How long a blocked app or site can be let through during focus, once per session.
    static var quickAllowMinutes: Int { positive(Key.quickAllowMinutes) ?? defaultQuickAllowMinutes }

    private static func positive(_ key: String) -> Int? {
        let value = UserDefaults.standard.integer(forKey: key)
        return value > 0 ? value : nil
    }
}
