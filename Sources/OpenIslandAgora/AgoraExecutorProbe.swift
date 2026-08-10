import Foundation
import OpenIslandCore

/// A tiny real-world driver for `AgoraCommandExecutor`, used by the
/// cross-repo end-to-end check (Agora's `e2e_l3_injection.py`).
///
/// It is **not** a mock: it runs the shipping executor against a real Agora
/// server and injects into a real terminal multiplexer pane. The only thing it
/// stands in for is the app's own session registry, which needs a running
/// island; here the session under control is described on the command line.
///
/// Invoked as: `OpenIslandAgoraProbe <base-url> <agent-kind> <session-id> <tmux-target>`
public enum AgoraExecutorProbe {
    public static func run(arguments: [String]) -> Int32 {
        guard arguments.count >= 4,
              let baseURL = URL(string: arguments[0])
        else {
            FileHandle.standardError.write(Data(
                "usage: probe <base-url> <agent-kind> <session-id> <tmux-target>\n".utf8))
            return 64
        }
        let agentKind = arguments[1]
        let sessionID = arguments[2]
        let tmuxTarget = arguments[3]

        let session = makeSession(
            id: sessionID,
            title: "probe",
            tool: agentKind == "codex" ? .codex : .claudeCode,
            phase: .running,
            summary: "probe",
            updatedAt: Date(timeIntervalSince1970: 0),
            tmuxTarget: tmuxTarget
        )

        let executor = AgoraCommandExecutor(
            baseURL: baseURL,
            lookup: { kind, id in
                (kind == agentKind && id == sessionID) ? session : nil
            },
            inject: { text, target in
                TerminalTextInjector.send(text, to: target)
            }
        )
        executor.pollOnce()
        return 0
    }
}

private func makeSession(
    id: String,
    title: String,
    tool: AgentTool,
    phase: SessionPhase,
    summary: String,
    updatedAt: Date,
    tmuxTarget: String
) -> AgentSession {
    var session = AgentSession(
        id: id, title: title, tool: tool, phase: phase,
        summary: summary, updatedAt: updatedAt
    )
    session.jumpTarget = JumpTarget(
        terminalApp: "tmux",
        workspaceName: "probe",
        paneTitle: "probe",
        tmuxTarget: tmuxTarget
    )
    return session
}

/// The injection primitive, kept in this target so the executor does not have
/// to depend on the app target. Mirrors `TerminalTextSender`'s tmux path — the
/// one path that needs no Accessibility grant, which is exactly why the
/// end-to-end check uses it.
public enum TerminalTextInjector {
    public static func send(_ text: String, to session: AgentSession) -> Bool {
        guard let target = session.jumpTarget?.tmuxTarget,
              let tmux = resolveTmux()
        else { return false }
        guard run(tmux, ["send-keys", "-t", target, "-l", text]) else { return false }
        return run(tmux, ["send-keys", "-t", target, "Enter"])
    }

    private static func resolveTmux() -> String? {
        for candidate in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    private static func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
