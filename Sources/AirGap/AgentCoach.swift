import Foundation
import AirGapCore

/// Runs the user's own assistant CLI headless, with no tools, to plan and reflect on focus sessions:
/// Claude Code (`claude -p`) or Codex (`codex exec`).
enum AgentCoach {
    private static let timeout: TimeInterval = 120

    /// Each installed CLI, filled in by `locate()`. Empty until then.
    @MainActor private static var executables: [CoachAgent: URL] = [:]

    @MainActor static func executable(for agent: CoachAgent) -> URL? { executables[agent] }

    /// Looks for the CLIs off the main thread, since that may start a login shell, and returns the agents found.
    @MainActor static func locate() async -> Set<CoachAgent> {
        executables = await Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let claude = find("claude", in: ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                                             "/usr/local/bin/claude"])
            let codex = find("codex", in: ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex",
                                           "\(home)/.npm-global/bin/codex", "/Applications/Codex.app/Contents/Resources/codex"])
            return [CoachAgent.claude: claude, .codex: codex].compactMapValues { $0 }
        }.value
        return Set(executables.keys)
    }

    /// Apps launched from Finder don't inherit the shell PATH, so look in the usual install locations first.
    private static func find(_ name: String, in candidates: [String]) -> URL? {
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return URL(fileURLWithPath: path) }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        shell.waitUntilExit()
        let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// Asks `agent` for an answer of type `T`, shaped by the JSON `schema` from `Coach`.
    static func ask<T: Decodable>(_ prompt: String, schema: String, with agent: CoachAgent) async throws -> T {
        guard let executable = await executable(for: agent) else { throw CoachError.notInstalled }
        let model = Preferences.claudeModel
        return try await Task.detached(priority: .userInitiated) {
            switch agent {
            case .none: throw CoachError.notInstalled
            case .claude: return try runClaude(executable, model: model, prompt: prompt, schema: schema)
            case .codex: return try runCodex(executable, prompt: prompt, schema: schema)
            }
        }.value
    }

    private static func runClaude<T: Decodable>(_ executable: URL, model: String, prompt: String, schema: String) throws -> T {
        let arguments = [
            "-p", "--model", model, "--tools", "", "--strict-mcp-config", "--no-session-persistence", "--setting-sources", "",
            "--output-format", "json", "--system-prompt", Coach.systemPrompt, "--json-schema", schema, prompt,
        ]
        // Run outside any project so no CLAUDE.md or project settings leak into the coach.
        let (out, err) = try execute(executable, arguments, in: FileManager.default.temporaryDirectory, name: "Claude")
        if out.isEmpty { throw CoachError.failed(err.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return try Coach.decode(T.self, from: out)
    }

    private static func runCodex<T: Decodable>(_ executable: URL, prompt: String, schema: String) throws -> T {
        // A fresh empty folder per run, so no AGENTS.md or project files leak into the coach.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AirGap-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("schema.json"), answerURL = dir.appendingPathComponent("answer.txt")
        try Data(schema.utf8).write(to: schemaURL)
        // Codex has no system prompt flag, so it leads the prompt. MCP servers, hooks, plugins and tools stay off.
        let arguments = [
            "exec", "--ephemeral", "--skip-git-repo-check", "--ignore-rules", "--sandbox", "read-only", "--color", "never",
            "-c", "mcp_servers={}", "-c", "project_doc_max_bytes=0",
            "--disable", "hooks", "--disable", "apps", "--disable", "plugins", "--disable", "shell_tool", "--disable", "multi_agent",
            "--disable", "browser_use", "--disable", "computer_use", "--disable", "image_generation",
            "--output-schema", schemaURL.path, "--output-last-message", answerURL.path, "-C", dir.path,
            Coach.systemPrompt + "\n\n" + prompt,
        ]
        let (_, err) = try execute(executable, arguments, in: dir, name: "Codex")
        guard let answer = try? String(contentsOf: answerURL, encoding: .utf8),
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoachError.failed(Coach.codexError(err))
        }
        return try Coach.decode(T.self, fromText: answer)
    }

    /// Runs the CLI to completion and returns its stdout and stderr. Stops it after `timeout`.
    private static func execute(_ executable: URL, _ arguments: [String], in directory: URL, name: String) throws -> (Data, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        // Read stderr alongside stdout so neither pipe fills up and stalls the CLI.
        var errData = Data()
        let errReader = DispatchWorkItem { errData = err.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async(execute: errReader)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        errReader.wait()
        process.waitUntilExit()
        killer.cancel()
        if process.terminationReason == .uncaughtSignal { throw CoachError.failed("\(name) took too long to answer. Try again.") }
        return (data, String(decoding: errData, as: UTF8.self))
    }
}
