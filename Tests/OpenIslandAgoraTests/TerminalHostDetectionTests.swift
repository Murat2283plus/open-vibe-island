import Foundation
import OpenIslandCore
import Testing

/// 终端宿主识别：不设 TERM_PROGRAM 的终端（Termany 是真机上第一个撞上的）
/// 此前一律显示 Unknown，会话也因此拿不到可用的 jumpTarget。
@Suite struct TerminalHostDetectionTests {
    @Test func extractsAppNameFromRealBundlePaths() {
        #expect(ClaudeHookPayload.appBundleName(
            fromExecutablePath: "/Applications/Termany.app/Contents/MacOS/app") == "Termany")
        // Termany 的 shell 实际挂在 Electron 的 node 辅助进程下，路径更深但同样命中
        #expect(ClaudeHookPayload.appBundleName(
            fromExecutablePath: "/Applications/Termany.app/Contents/Resources/resources/server/node")
            == "Termany")
        #expect(ClaudeHookPayload.appBundleName(
            fromExecutablePath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
            == "Terminal")
        #expect(ClaudeHookPayload.appBundleName(
            fromExecutablePath: "/Users/me/Applications/Open Island Dev.app/Contents/MacOS/OpenIslandApp")
            == "Open Island Dev")
    }

    /// 真机踩到：用 Python 触发的 hook 被标成 "Python" —— CPython 自带
    /// Python.framework/.../Python.app。Agora summon 出来的 agent 全由 python
    /// 拉起，会集体中招。假装有终端比老实说 Unknown 更糟，因为跳转会去追它。
    @Test func rejectsBundlesInsideFrameworks() {
        #expect(ClaudeHookPayload.appBundleName(
            fromExecutablePath:
                "/Library/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python")
            == nil)
        #expect(ClaudeHookPayload.appBundleName(
            fromExecutablePath:
                "/System/Library/Frameworks/Foo.framework/Helper.app/Contents/MacOS/Helper") == nil)
        // 真终端不在 framework 里，必须照常识别
        #expect(ClaudeHookPayload.appBundleName(
            fromExecutablePath: "/Applications/Termany.app/Contents/MacOS/app") == "Termany")
    }

    @Test func ignoresPathsOutsideAnAppBundle() {
        #expect(ClaudeHookPayload.appBundleName(fromExecutablePath: "/bin/zsh") == nil)
        #expect(ClaudeHookPayload.appBundleName(fromExecutablePath: "/opt/homebrew/bin/tmux") == nil)
        #expect(ClaudeHookPayload.appBundleName(fromExecutablePath: "") == nil)
    }

    /// 真机上采到的进程表片段：shell → claude → shell → Electron node → Termany。
    @Test func walksAncestryToTheHostingApp() {
        let table = """
        33801 77935 /bin/zsh
        77935 72916 /Users/me/.local/bin/claude
        72916 89956 /bin/zsh
        89956 89944 /Applications/Termany.app/Contents/Resources/resources/server/node
        89944 1 /Applications/Termany.app/Contents/MacOS/app
        """
        #expect(ClaudeHookPayload.hostAppFromProcessAncestry(
            startPID: 33801, tableProvider: { table }) == "Termany")
    }

    @Test func returnsNilWhenNoAncestorLivesInAnApp() {
        // tmux 服务端挂在 launchd 下，链上没有 .app —— 必须老实返回 nil，
        // 不能瞎猜一个终端出来。
        let table = """
        4001 4002 /bin/zsh
        4002 1 /opt/homebrew/bin/tmux
        """
        #expect(ClaudeHookPayload.hostAppFromProcessAncestry(
            startPID: 4001, tableProvider: { table }) == nil)
    }

    @Test func survivesCyclesAndMissingParents() {
        let cyclic = """
        5001 5002 /bin/zsh
        5002 5001 /bin/zsh
        """
        #expect(ClaudeHookPayload.hostAppFromProcessAncestry(
            startPID: 5001, tableProvider: { cyclic }) == nil)
        #expect(ClaudeHookPayload.hostAppFromProcessAncestry(
            startPID: 9999, tableProvider: { "1 0 /sbin/launchd" }) == nil)
    }

    /// 真实进程表：本测试进程自己就跑在某个终端里，链路必须能走通而不崩。
    @Test func readsTheRealProcessTableWithoutCrashing() {
        _ = ClaudeHookPayload.hostAppFromProcessAncestry()
    }
}
