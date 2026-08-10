# Fork 台账 —— 相对上游 Octane0411/open-vibe-island 的全部改动

给下一个接手的 Agent。**上游更新后要合并，先读这一篇**：哪些文件动了、为什么动、
哪些应该提回上游、冲突了怎么办，都在这里。不要靠 `git diff` 反推意图。

统计口径：`git diff upstream/main...HEAD`（截至 2026-08-10）。

## 一、新增的独立模块（与上游零冲突，合并时不用管）

| 路径 | 作用 |
|---|---|
| `Sources/OpenIslandAgora/AgoraSentinel.swift` | 传感器：把 `AgentEvent` 转发给 Agora |
| `Sources/OpenIslandAgora/AgoraExecutor.swift` | 执行器：拉取 Agora 的控制指令并注入终端 |
| `Sources/OpenIslandAgora/AgoraRoomBindings.swift` | 会话 → Agora 房间身份的只读镜像 |
| `Sources/OpenIslandAgora/AgoraExecutorProbe.swift` | 跨仓库 E2E 用的最小驱动 |
| `Sources/OpenIslandAgoraProbe/main.swift` | 上面那个 probe 的可执行入口 |
| `Tests/OpenIslandAgoraTests/*` | 本 fork 新增能力的测试 |

**设计纪律：新代码一律进 `OpenIslandAgora` target，不散进上游文件。** 这样上游
怎么改都不会与它们冲突。加新能力时继续遵守。

## 二、动过的上游文件（合并时的冲突点）

### 2.1 应当提回上游的（是通用 bug 修复，不是我们的定制）

**`Sources/OpenIslandCore/ClaudeHooks.swift`（+87 行）**
在 `inferTerminalApp` 末尾加了一层进程祖先回溯：向上找第一个 `.app` 宿主。
- **为什么**：不设 `TERM_PROGRAM` 的终端（Termany 是第一个撞上的）一律显示
  `Unknown`，会话也因此拿不到可用的 jumpTarget，L3 注入直接失效。
- **实现要点**：一次性读进程表再在内存里走，不逐层调 `ps`（hook 每次工具调用
  都会跑）。拒绝 `.framework` 内的 bundle —— CPython 自带 `Python.app`，
  否则 python 拉起的 agent 会集体被标成 "Python"。
- **上游价值**：高。任何用小众终端的人都会踩。**建议整理成 PR 提上去。**

**`Sources/OpenIslandApp/TerminalJumpService.swift`（+43 行）**
`resolveTerminalApp` 认不出终端时不再盲选第一个已装终端。
- **为什么**：原代码 `return knownApps.first(where: isInstalled)` 会让"叫得出
  名字但没有跳转配方"的终端跳到 Terminal.app。**这个文件自己的注释就在警告
  这个行为**（"曾导致 Warp 会话打开 Terminal.app"），只是仅防住了字面量
  `"unknown"`。真机复现：Termany 会话点跳转打开了系统「终端」。
- **改法**：认识的走原配方 → 只知道名字的按同名 `.app` 激活 → 都不成立返回
  nil 走 Finder 兜底，**绝不瞎挑**。
- **上游价值**：高。**建议提 PR。**

**`Sources/OpenIslandCore/BridgeServer.swift`（1 行）**
**`Sources/OpenIslandCore/LocalBridgeClient.swift`（1 行）**
两处默认 socket 路径由 `BridgeSocketLocation.defaultURL` 改为 `currentURL()`。
- **为什么**：`BridgeCommandClient`（hooks CLI）本来就用 `currentURL()`（认
  `OPEN_ISLAND_SOCKET_PATH`），另两处却硬编码稳定路径。三者不一致时**隔离的
  端到端测试根本不可能成立** —— hook 写测试 socket，App 却在稳定路径上监听。
- **上游价值**：高，且改动极小。**建议提 PR。**

### 2.2 本 fork 的定制（不适合上游）

**`Sources/OpenIslandApp/AppModel.swift`（+20 行）**
三处挂载点：`agoraSentinel` 属性、`agoraRooms` 绑定轮询、`applyTrackedEvent`
之后调 `agoraSentinel.ingest(observed)`。
- **合并冲突风险**：中。上游若重构 `applyTrackedEvent` 会撞。
- **恢复方法**：冲突时保留上游版本，再把这三处重新插回去（各自只有几行，
  搜 `agora` 即可定位）。

**`Sources/OpenIslandApp/Views/IslandPanelView.swift`（+48 行）**
Agora 房间徽章：`IslandSessionRow` 新增 `agoraBinding` 参数、`agoraRoomBadge`
视图、3 处调用点传参。
- 同时修了两个上游的布局问题：`sideBadge` 与 `agentBadge` 缺
  `lineLimit(1)/fixedSize`，多一个徽章抢宽度就会折行、把胶囊压成球（真机截图
  为证）。**这两行是通用修复，可以单独提回上游。**
- **合并冲突风险**：高。上游改这个 View 的频率不低。
- **恢复方法**：徽章是自包含的（一个 `@ViewBuilder` + 一个参数），冲突时
  以上游为准重新插入。

**`Package.swift`（+13 行）**
注册 `OpenIslandAgora` target、`OpenIslandAgoraProbe` 可执行、
`OpenIslandAgoraTests` 测试 target，并给 App target 加依赖。
- **合并冲突风险**：低，但每次上游动 `Package.swift` 都要手工确认这几段还在。

## 三、合并上游的操作流程

```bash
git fetch upstream
git checkout main && git merge upstream/main    # main 只跟上游，不放我们的东西
git checkout agora-integration
git merge main
```

冲突只会出现在 §2 那几个文件里。按上面每条的"恢复方法"处理，然后**必须重跑**：

```bash
swift build
swift test --filter OpenIslandAgoraTests
# 跨仓库链路（在 agora 仓库里）
./.venv/bin/python e2e_p0_sentinel.py
./.venv/bin/python e2e_l3_injection.py
```

## 四、本机构建环境的两个坑

1. **需要 Swift 6.2**，本机 CLT 只有 6.1（且没装 Xcode）。工具链装在
   `代码/toolchains/swift-6.2.1-RELEASE.xctoolchain`，构建时把它的 `usr/bin`
   放进 PATH 前面。
2. **dev app 装在哪取决于 `$HOME`**。`launch-dev-app.sh` 用 `$HOME/Applications`，
   在沙箱环境里跑会装进沙箱家目录、用户根本看不见（真踩过）。正确姿势：
   `HOME=/Users/dilmuratalim zsh scripts/launch-dev-app.sh`。
3. **发布版 `/Applications/Open Island.app` 会抢同一个 bridge socket 和同一个
   受管 hook 二进制**。两个同时跑，改动看起来"失效"。它在登录项里，开机会自动
   回来。要用 dev 版就得先退出发布版。
