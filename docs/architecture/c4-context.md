# 项目洗澡的系统边界

这张系统上下文图面向项目维护者。project-bath 是交给有文件能力的 Agent 执行的方法；本地执行系统包含 Agent 判断和批次工具。项目工作区与 D 盘保存区提供文件存储，不包含远程服务。

[查看本地交互图](../../assets/diagrams/c4-context.html) · [可编辑图源](../../assets/diagrams/c4-context.json) · [C4 Mermaid 源码](../../assets/diagrams/c4-context.mmd)

| 来源 → 目标 | 真实动作与技术 | 实现证据 | 状态 |
|---|---|---|---|
| 项目维护者 → 本地执行系统 | 提交清理范围、保留项和已有修改；宿主对话 | `SKILL.md` 第 11–15 行 | 已实现的方法入口；宿主产品不限定 |
| 本地执行系统 → 项目工作区 | 先核验字节与身份，再经本地文件 API 修改或恢复 | `scripts/bath.ps1` 的 Prepare / Apply / Restore；`references/protocol.md` 的 D 保存、恢复与停止 | 已实现 |
| 本地执行系统 → D 批次保存区 | 在项目首个写入前保存并回读核验原字节；保存检查视图与证据 | `scripts/bath.ps1` 第 519–573 行；`references/protocol.md` 的范围与检查 | 已实现 |

图中的人形角色是用户；系统节点表示 Agent 与工具协作；文件存储节点表示本地普通文件。所有关系都是单向动作。D 保存区只保存修改文件原字节；更名目录的其他子项记录 namespace 证据，不承诺整树字节备份。

证据不足的候选暂留。检查充分性及业务语义由 Agent 判断，工具通过不等于业务正确。没有远程 API、后台服务或发布服务。
