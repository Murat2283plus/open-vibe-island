import Foundation
import OpenIslandCore
import Testing

@testable import OpenIslandAgora

private func makeSession(
    tool: AgentTool = .claudeCode,
    phase: SessionPhase = .running,
    summary: String = "Editing files",
    currentTool: String? = nil,
    preview: String? = nil,
    transcriptPath: String? = nil,
    workingDirectory: String? = nil
) -> AgentSession {
    var session = AgentSession(
        id: "sess-1",
        title: "demo",
        tool: tool,
        phase: phase,
        summary: summary,
        updatedAt: Date(timeIntervalSince1970: 1_000)
    )
    if tool == .claudeCode {
        session.claudeMetadata = ClaudeSessionMetadata(
            transcriptPath: transcriptPath,
            currentTool: currentTool,
            currentToolInputPreview: preview
        )
    }
    if let workingDirectory {
        session.jumpTarget = JumpTarget(
            terminalApp: "Terminal",
            workspaceName: "demo",
            paneTitle: "demo",
            workingDirectory: workingDirectory
        )
    }
    return session
}

@Suite struct AgoraSentinelMapperTests {
    @Test func phaseMapping() {
        #expect(AgoraSentinelEvent.state(for: makeSession(phase: .running)) == "running")
        #expect(
            AgoraSentinelEvent.state(for: makeSession(phase: .running, currentTool: "Bash"))
                == "tool_running"
        )
        #expect(
            AgoraSentinelEvent.state(for: makeSession(phase: .waitingForApproval))
                == "waiting_permission"
        )
        #expect(
            AgoraSentinelEvent.state(for: makeSession(phase: .waitingForAnswer))
                == "waiting_input"
        )
        #expect(AgoraSentinelEvent.state(for: makeSession(phase: .completed)) == "idle")
    }

    @Test func agentKindMapping() {
        #expect(AgoraSentinelEvent.agentKind(for: .claudeCode) == "claude")
        #expect(AgoraSentinelEvent.agentKind(for: .codex) == "codex")
        #expect(AgoraSentinelEvent.agentKind(for: .geminiCLI) == "gemini")
        #expect(AgoraSentinelEvent.agentKind(for: .openCode) == "opencode")
        #expect(AgoraSentinelEvent.agentKind(for: .kimiCLI) == "kimi")
    }

    @Test func activityPrefersToolWithPreviewOverSummary() {
        let busy = makeSession(currentTool: "Bash", preview: "swift build")
        #expect(AgoraSentinelEvent.activity(for: busy) == "Bash: swift build")
        let idle = makeSession(summary: "Reading docs")
        #expect(AgoraSentinelEvent.activity(for: idle) == "Reading docs")
    }

    @Test func wireFormatUsesAgoraFieldNames() throws {
        let session = makeSession(
            currentTool: "Bash",
            preview: "swift test",
            transcriptPath: "/tmp/t.jsonl",
            workingDirectory: "/repo"
        )
        let event = AgoraSentinelEvent.from(session)
        #expect(event.sessionID == "sess-1")
        #expect(event.transcriptPath == "/tmp/t.jsonl")
        #expect(event.cwd == "/repo")

        let data = try JSONEncoder().encode(event)
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(json["agent_kind"] as? String == "claude")
        #expect(json["session_id"] as? String == "sess-1")
        #expect(json["state"] as? String == "tool_running")
        #expect(json["transcript_path"] as? String == "/tmp/t.jsonl")
    }

    @Test func eventSessionIDExtraction() {
        let started = AgentEvent.sessionStarted(
            SessionStarted(
                sessionID: "sess-9",
                title: "t",
                tool: .claudeCode,
                summary: "s",
                timestamp: Date(timeIntervalSince1970: 0)
            )
        )
        #expect(started.agoraSessionID == "sess-9")
    }
}
