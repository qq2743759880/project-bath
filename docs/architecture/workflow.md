# 从证据到终态

先核对入口、授权范围、保留项和用户修改。有真实过期证据，才按当前工作区字节准备计划和完整替换；证据不足可以零修改。

完整流程分为三个问题：

- [正常清理与拒绝](../../assets/diagrams/workflow-normal.html) · [可编辑图源](../../assets/diagrams/workflow-normal.json)：Prepare 在 D 保存并核验全部所需备份，返回 BackedUp 后才 Apply。D 失败时项目零写入。确认整批 Applied 后 Check；最新检查成功且当前状态匹配，才 Finalize 到 Completed。
- [中断后先看现状](../../assets/diagrams/workflow-interruption.html) · [可编辑图源](../../assets/diagrams/workflow-interruption.json)：失败或中断使旧 PASS 立即失效，Finalize 拒绝过期 receipt；未知写入或冲突先 Status，只读实际状态与确认事件。
- [回退与冲突保留](../../assets/diagrams/workflow-recovery.html) · [可编辑图源](../../assets/diagrams/workflow-recovery.json)：Restore 只恢复自身确认且当前状态匹配的项。全部恢复才 Restored；冲突或未知写入经允许的 Close 保存 Stopped，保留项目内容与证据并释放自己的 lease。Stopped 不代表完整恢复。

检查仍有宿主权限。Agent 判断检查是否覆盖本次风险，工具不证明业务正确性、不提供 OS 沙箱、不自动合并，也不承诺目录事务。schema 4 当前候选开放 Check / Finalize 的能力门不升级旧 manifest。

流程关系来自 `SKILL.md` 与 `references/protocol.md`，以及 `scripts/bath.ps1`、`bath-group.ps1`、`bath-rename.ps1` 的 Prepare、Apply、Check、Finalize、Status、Restore 和 Close 实现。图中的泳道表示阶段，不代表服务。
