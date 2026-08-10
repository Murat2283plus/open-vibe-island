import Foundation
import OpenIslandAgora

// 跨仓库端到端验收用的最小驱动：跑的是出货版执行器，注入的是真实 tmux pane。
exit(AgoraExecutorProbe.run(arguments: Array(CommandLine.arguments.dropFirst())))
