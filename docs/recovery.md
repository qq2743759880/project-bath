# RC1 恢复、取消与安全终止

[交互恢复图](https://qq2743759880.github.io/project-bath/recovery/) · [Typed JSON](../assets/diagram-source/recovery.json)

![恢复控制面](../assets/recovery.png)

先给 Agent 项目根路径与原交接的 D 盘批次路径，让它通过 Status 只读核对真实状态。完整参数见 [protocol](../references/protocol.md)。不要手改备份记录、删除 lease 或直接覆盖目标。

| 现场 | 合法路径与边界 |
|---|---|
| IncompletePrepare | 当前 owner / prepare-intent 完整，且没有 journal 时才 Cancel；Cancelled 保留文件并释放自己的 lease。已准备或已应用批次不能用 Cancel。 |
| BackedUp / Applied | 工具再次核验 root、parent、备份与目标；条件匹配才 Restore。 |
| Applying / Restoring 未确认，或 Conflict / Ambiguous | 先 Status。没有安全自动路径且 owner / intent 证据有效时才能 Close。InterruptedRestore 不自动重试覆盖。健康批次走正常 Restore / Finalize。 |
| Stopped | 安全终止，保留现场和证据；没有恢复，不支持自动 Restore。 |
| Completed 历史批次 | 无别的活跃 batch，且原 root / parent / 备份 / Apply 后目标仍匹配时可 Historical Restore。归档目标必须空闲；编辑目标字节、身份、mtime 必须匹配。后来改动或新批次则拒绝并保留。 |

归档从 D 盘复制原字节到新建目标；编辑恢复在受保护句柄中进行。验证原字节后进入 Restored 并释放自己的 lease。历史恢复保留旧 completion receipt，但当前状态不再是 Completed。

备份位于 `D:/project-bath/<项目名-根路径hash>/<唯一批次>/`。工具不自动清理历史归档，不承诺恢复完整 ACL / owner / 时间元数据。工具拒绝时，交接诊断与保留证据，由用户与 Agent 决定后续处理。
