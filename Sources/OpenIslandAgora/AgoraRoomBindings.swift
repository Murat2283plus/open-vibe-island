import Foundation

/// Where a local agent session sits inside Agora's collaboration graph.
public struct AgoraRoomBinding: Codable, Sendable, Equatable {
    public var agentKind: String
    public var sessionID: String
    public var room: String
    public var roomName: String
    public var displayName: String
    public var isModerator: Bool
    public var canSpeak: Bool
    public var memberCount: Int

    enum CodingKeys: String, CodingKey {
        case agentKind = "agent_kind"
        case sessionID = "session_id"
        case room
        case roomName = "room_name"
        case displayName = "display_name"
        case isModerator = "is_moderator"
        case canSpeak = "can_speak"
        case memberCount = "member_count"
    }

    /// What the island shows on the session row, e.g. `#5314 claude-220`.
    public var badgeText: String {
        "#\(room) \(displayName)"
    }
}

private struct BindingEnvelope: Codable {
    let bindings: [AgoraRoomBinding]
}

/// Pulls the session → room mapping so the island can show which agents are
/// collaborating and which are working alone.
///
/// Without this the two views never meet: Open Island lists local sessions,
/// Agora lists room members, and nothing tells you they are the same agents.
/// The mapping itself lives in Agora — it owns membership and already computes
/// the sensor binding — so this is a read-only mirror, never a second source
/// of truth.
///
/// Fail-open: no Agora, no token, or a transport error leaves the map empty and
/// the island renders exactly as it did before.
public final class AgoraRoomBindingStore: @unchecked Sendable {
    private let endpoint: URL
    private let urlSession: URLSession
    private let tokenProvider: @Sendable () -> String?
    private let queue = DispatchQueue(label: "openisland.agora.bindings")
    private var timer: DispatchSourceTimer?
    private var bindings: [String: AgoraRoomBinding] = [:]   // keyed by session id

    /// Called on the main queue whenever the mapping changes.
    public var onChange: (@Sendable () -> Void)?

    public init(
        baseURL: URL? = nil,
        urlSession: URLSession = .shared,
        tokenProvider: (@Sendable () -> String?)? = nil
    ) {
        let base = baseURL
            ?? ProcessInfo.processInfo.environment["AGORA_ISLAND_BASE_URL"].flatMap(URL.init(string:))
            ?? URL(string: "http://127.0.0.1:4577")!
        self.endpoint = base.appendingPathComponent("api/island/sentinel/bindings")
        self.urlSession = urlSession
        self.tokenProvider = tokenProvider ?? AgoraSentinelForwarder.keychainTokenProvider
    }

    public func binding(forSessionID sessionID: String) -> AgoraRoomBinding? {
        queue.sync { bindings[sessionID] }
    }

    public func snapshot() -> [String: AgoraRoomBinding] {
        queue.sync { bindings }
    }

    public func start(pollInterval: TimeInterval = 5.0) {
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: pollInterval)
            source.setEventHandler { [weak self] in self?.refresh() }
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

    /// One synchronous refresh. Exposed so an end-to-end check can drive it
    /// deterministically instead of waiting on the timer.
    public func refreshNow() {
        queue.sync { refresh() }
    }

    private func refresh() {
        guard let token = tokenProvider() else { return }
        var request = URLRequest(url: endpoint, timeoutInterval: 5)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        urlSession.dataTask(with: request) { data, _, _ in
            payload = data
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 6)

        guard let payload,
              let envelope = try? JSONDecoder().decode(BindingEnvelope.self, from: payload)
        else { return }

        var next: [String: AgoraRoomBinding] = [:]
        for binding in envelope.bindings {
            next[binding.sessionID] = binding
        }
        guard next != bindings else { return }
        bindings = next
        if let onChange {
            DispatchQueue.main.async(execute: onChange)
        }
    }
}
