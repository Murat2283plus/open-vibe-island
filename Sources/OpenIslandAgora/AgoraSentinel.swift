import Foundation
import OpenIslandCore

/// Wire format for one observation sent to Agora's sentinel endpoint
/// (`POST /api/island/sentinel/events`). Field names follow the server's
/// presence registry contract; see the Agora repo,
/// `docs/superpowers/specs/2026-08-10-agent-operator-platform-design.md`.
public struct AgoraSentinelEvent: Codable, Sendable, Equatable {
    public var agentKind: String
    public var sessionID: String
    public var state: String
    public var activity: String
    public var cwd: String
    public var transcriptPath: String

    enum CodingKeys: String, CodingKey {
        case agentKind = "agent_kind"
        case sessionID = "session_id"
        case state
        case activity
        case cwd
        case transcriptPath = "transcript_path"
    }

    public static func from(_ session: AgentSession) -> AgoraSentinelEvent {
        AgoraSentinelEvent(
            agentKind: agentKind(for: session.tool),
            sessionID: session.id,
            state: state(for: session),
            activity: activity(for: session),
            cwd: session.jumpTarget?.workingDirectory ?? "",
            transcriptPath: session.codexMetadata?.transcriptPath
                ?? session.claudeMetadata?.transcriptPath
                ?? session.geminiMetadata?.transcriptPath
                ?? ""
        )
    }

    /// Agora identifies agents by these lowercase kind strings (the same ones
    /// its stop hook reports); only claude/codex participate in member binding
    /// today, but every kind is forwarded so presence stays complete.
    public static func agentKind(for tool: AgentTool) -> String {
        switch tool {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .geminiCLI: "gemini"
        case .openCode: "opencode"
        case .cursor: "cursor"
        case .kimiCLI: "kimi"
        case .qoder: "qoder"
        case .qwenCode: "qwen"
        case .factory: "factory"
        case .codebuddy: "codebuddy"
        }
    }

    public static func state(for session: AgentSession) -> String {
        switch session.phase {
        case .waitingForApproval: return "waiting_permission"
        case .waitingForAnswer: return "waiting_input"
        case .completed: return "idle"
        case .running: return currentTool(of: session) == nil ? "running" : "tool_running"
        }
    }

    public static func activity(for session: AgentSession) -> String {
        if let tool = currentTool(of: session) {
            let preview = session.codexMetadata?.currentCommandPreview
                ?? session.claudeMetadata?.currentToolInputPreview
                ?? session.openCodeMetadata?.currentToolInputPreview
                ?? session.cursorMetadata?.currentToolInputPreview
            if let preview, !preview.isEmpty {
                return "\(tool): \(preview)"
            }
            return tool
        }
        return session.summary
    }

    private static func currentTool(of session: AgentSession) -> String? {
        session.codexMetadata?.currentTool
            ?? session.claudeMetadata?.currentTool
            ?? session.openCodeMetadata?.currentTool
            ?? session.cursorMetadata?.currentTool
    }
}

extension AgentEvent {
    /// The session an event belongs to, for post-apply presence forwarding.
    public var agoraSessionID: String? {
        switch self {
        case let .sessionStarted(p): p.sessionID
        case let .activityUpdated(p): p.sessionID
        case let .permissionRequested(p): p.sessionID
        case let .questionAsked(p): p.sessionID
        case let .sessionCompleted(p): p.sessionID
        case let .jumpTargetUpdated(p): p.sessionID
        case let .sessionMetadataUpdated(p): p.sessionID
        case let .claudeSessionMetadataUpdated(p): p.sessionID
        case let .geminiSessionMetadataUpdated(p): p.sessionID
        case let .openCodeSessionMetadataUpdated(p): p.sessionID
        case let .cursorSessionMetadataUpdated(p): p.sessionID
        case let .actionableStateResolved(p): p.sessionID
        }
    }
}

/// Forwards session snapshots to the local Agora server, turning Open Island
/// into Agora's passive presence sensor. Strictly fail-open: no Agora, no
/// token, or any transport error → the island behaves exactly as before.
public final class AgoraSentinelForwarder: @unchecked Sendable {
    public static let keychainService = "xyz.ccaicc.agora-island"
    public static let keychainAccount = "agora-server"

    private let endpoint: URL
    private let urlSession: URLSession
    private let tokenProvider: @Sendable () -> String?
    private let queue = DispatchQueue(label: "openisland.agora.sentinel")
    private var resolvedToken: String??

    public init(
        baseURL: URL? = nil,
        urlSession: URLSession = .shared,
        tokenProvider: (@Sendable () -> String?)? = nil
    ) {
        let base = baseURL
            ?? ProcessInfo.processInfo.environment["AGORA_ISLAND_BASE_URL"].flatMap(URL.init(string:))
            ?? URL(string: "http://127.0.0.1:4577")!
        self.endpoint = base.appendingPathComponent("api/island/sentinel/events")
        self.urlSession = urlSession
        self.tokenProvider = tokenProvider ?? Self.defaultTokenProvider
    }

    /// Fire-and-forget. Never throws, never blocks the caller thread on IO.
    public func ingest(_ session: AgentSession) {
        let event = AgoraSentinelEvent.from(session)
        queue.async { [self] in
            guard let token = cachedToken() else {
                logOnce("sentinel dormant: no Agora capability token")
                return
            }
            post(events: [event], token: token)
        }
    }

    private var loggedMessages = Set<String>()

    private func logOnce(_ message: String) {
        guard !loggedMessages.contains(message) else { return }
        loggedMessages.insert(message)
        FileHandle.standardError.write(Data("[AgoraSentinel] \(message)\n".utf8))
    }

    private func cachedToken() -> String? {
        if let resolved = resolvedToken { return resolved }
        let token = tokenProvider()
        resolvedToken = .some(token)
        return token
    }

    private func post(events: [AgoraSentinelEvent], token: String) {
        guard let body = try? JSONEncoder().encode(["events": events]) else { return }
        var request = URLRequest(url: endpoint, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = urlSession.dataTask(with: request) { [self] _, response, error in
            if let error {
                queue.async { self.logOnce("sentinel post failed: \(error.localizedDescription)") }
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                queue.async { self.logOnce("sentinel post rejected: HTTP \(http.statusCode)") }
            }
        }
        task.resume()
    }

    /// Token sources, in order: `AGORA_ISLAND_TOKEN` env (tests / dev), then
    /// the Keychain capability Agora provisions for its island clients. Both
    /// missing → sensor stays dormant.
    private static let defaultTokenProvider: @Sendable () -> String? = {
        if let env = ProcessInfo.processInfo.environment["AGORA_ISLAND_TOKEN"],
           !env.isEmpty {
            return env
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password", "-w",
            "-s", keychainService,
            "-a", keychainAccount,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let token = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (token?.isEmpty ?? true) ? nil : token
    }
}
