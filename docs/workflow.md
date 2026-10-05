# RC1 工作流

[交互流程图](https://qq2743759880.github.io/project-bath/) · [Typed JSON](../assets/diagram-source/workflow.json) · [PNG](../assets/workflow.png) · [Trace WebM](../assets/workflow.webm)

范围与 baseline → 候选证据判断。证据不足或只读审计 → 暂留 / NoOp；授权且证据充分 → Prepare → BackedUp → Apply → Applied → Check → Finalize → Completed。

Check FAIL 时先核对条件，再 Restore → Restored。Finalize 需要最新回执和当前状态继续匹配。Check 在 D 盘隔离副本中执行受信任检查，不是 OS sandbox。完整条件见 [protocol](../references/protocol.md)。

中断、取消与 Completed historical Restore 见 [恢复指南](./recovery.md)。图中操作来自本仓 RC1 Runtime，不是额外自动化承诺。
