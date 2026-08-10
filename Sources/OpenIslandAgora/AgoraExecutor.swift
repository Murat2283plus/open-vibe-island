import Foundation
import OpenIslandCore

/// One control command Agora wants carried out on a local terminal session.
public struct AgoraCommand: Codable, Sendable, Equatable {
    public var id: String
    public var agentKind: String
    public var sessionID: String
    public var kind: String      // inject_text | interrupt
    public var text: String
    public var reason: String

    enum CodingKeys: String, CodingKey {
        case id
        case agentKind = "agent_kind"
        case sessionID = "session_id"
        case kind
        case text
        case reason
    }
}

private struct CommandEnvelope: Codable {
    let commands: [AgoraCommand]
}

/// Executes Agora's control commands against real terminal sessions.
///
/// The hard boundary, mirrored from the Agora side: Agora never touches an
/// external process. The most it can do is ask this executor to type into a
/// terminal — physically the same thing the owner would do by hand. Nothing
/// here sends signals or kills PIDs.
///
/// Fail-open like everything else in this target: no Agora, no token, no
/// matching session → the command is reported as failed with a reason and the
/// island behaves exactly as before.
public final class AgoraCommandExecutor: @unchecked Sendable {
    public typealias SessionLookup = @Sendable (_ agentKind: String, _ sessionID: String) -> AgentSession?
    public typealias Injector = @Sendable (_ text: String, _ session: AgentSession) -> Bool

    private let baseURL: URL
    private let urlSession: URLSession
    private let tokenProvider: @Sendable () -> String?
    private let lookup: SessionLookup
    private let inject: Injector
    private let queue = DispatchQueue(label: "openisland.agora.executor")
    private var timer: DispatchSourceTimer?
    private var inFlight = Set<String>()

    public init(
        baseURL: URL? = nil,
        urlSession: URLSession = .shared,
        tokenProvider: (@Sendable () -> String?)? = nil,
        lookup: @escaping SessionLookup,
        inject: @escaping Injector
    ) {
        let base = baseURL
            ?? ProcessInfo.processInfo.environment["AGORA_ISLAND_BASE_URL"].flatMap(URL.init(string:))
            ?? URL(string: "http://127.0.0.1:4577")!
        self.baseURL = base
        self.urlSession = urlSession
        self.tokenProvider = tokenProvider ?? AgoraSentinelForwarder.keychainTokenProvider
        self.lookup = lookup
        self.inject = inject
    }

    /// Polling, not a push channel: Agora deliberately does not fake background
    /// push, and an idle session produces no hook events to piggyback on.
    public func start(pollInterval: TimeInterval = 2.0) {
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: pollInterval)
            source.setEventHandler { [weak self] in self?.poll() }
            timer = source
            source.resume()
        }
    }

    public func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    /// Runs one poll cycle synchronously. Exposed so an end-to-end test can
    /// drive the executor deterministically instead of waiting on a timer.
    public func pollOnce() {
        queue.sync { poll() }
    }

    private func poll() {
        guard let token = tokenProvider() else { return }
        var request = URLRequest(
            url: baseURL.appendingPathComponent("api/island/sentinel/commands"),
            timeoutInterval: 5
        )
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        urlSession.dataTask(with: request) { data, _, _ in
            payload = data
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 6)

        guard let payload,
              let envelope = try? JSONDecoder().decode(CommandEnvelope.self, from: payload)
        else { return }

        for command in envelope.commands where !inFlight.contains(command.id) {
            inFlight.insert(command.id)
            let (ok, detail) = execute(command)
            report(command.id, ok: ok, detail: detail, token: token)
            inFlight.remove(command.id)
        }
    }

    private func execute(_ command: AgoraCommand) -> (Bool, String) {
        guard let session = lookup(command.agentKind, command.sessionID) else {
            return (false, "no tracked session for \(command.agentKind):\(command.sessionID)")
        }
        switch command.kind {
        case "inject_text":
            let ok = inject(command.text, session)
            return (ok, ok ? "typed into \(session.jumpTarget?.terminalApp ?? "terminal")"
                          : "terminal did not accept the text")
        case "interrupt":
            // Esc is what the owner presses to take a run back. Same keystroke,
            // same effect — no signals, no PID guessing.
            let ok = inject("\u{1B}", session)
            return (ok, ok ? "sent Esc" : "terminal did not accept Esc")
        default:
            return (false, "unknown command kind \(command.kind)")
        }
    }

    private func report(_ id: String, ok: Bool, detail: String, token: String) {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("api/island/sentinel/commands/\(id)/result"),
            timeoutInterval: 5
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["ok": ok, "detail": detail])
        let semaphore = DispatchSemaphore(value: 0)
        urlSession.dataTask(with: request) { _, _, _ in semaphore.signal() }.resume()
        _ = semaphore.wait(timeout: .now() + 6)
    }
}
