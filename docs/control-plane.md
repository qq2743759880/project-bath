# RC1 操作速查

这些操作保护文件与批次绑定，不替 Agent 判断清理的业务语义。

| 操作 | 用户价值 | 条件 / 结果 |
|---|---|---|
| Help | 查看真实接口 | 零项目写入 |
| Status | 观察实际状态 | 零写入；Completed 后目标变化不会继承旧 PASS |
| Prepare | 先保存当前原字节 | 单文件计划；校验备份成功才 BackedUp |
| Apply | 应用已保存的变更 | 再核验目标；实际事件记录为 Applied |
| Check | 检查本批后状态 | 受信任只读脚本，在受限 D 盘副本运行；检测原项目及副本副作用 |
| Finalize | 正常保留成功结果 | 最新回执绑定实际 Apply 与当前两份 inventory；Completed，释放自己的 lease |
| Restore | 回到已保存原字节 | 再核验所有安全条件；Restored，释放自己的 lease |
| Cancel | 取消未完成准备 | 完整 owner / intent、无 journal；Cancelled |
| Close | 无安全自动路径时终止 | 证据与 owner 有效；Stopped，不恢复、不删除现场 |

实际参数与计划字段请直接使用 [Runtime protocol](../references/protocol.md)，避免从这张说明表猜参数。
