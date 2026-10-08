# 哪些东西真正运行

这张容器图面向需要了解执行边界的维护者。Agent 宿主、PowerShell 批次工具和可信检查子进程是真实可运行单元。D 批次保存区是文件存储；项目工作区位于清理系统外部。SKILL、协议和脚本模块都不是独立服务。

[查看本地交互图](../../assets/diagrams/c4-containers.html) · [可编辑图源](../../assets/diagrams/c4-containers.json) · [C4 Mermaid 源码](../../assets/diagrams/c4-containers.mmd)

| 来源 → 目标 | 真实动作与技术 | 实现证据 | 状态 |
|---|---|---|---|
| 维护者 → Agent 宿主 | 对话提交范围和保留项 | `SKILL.md` 第 11–15 行 | 已实现的方法入口；宿主型号不限定 |
| Agent 宿主 → 批次工具进程 | PowerShell CLI 调用 `bath.ps1`；JSON 计划与返回 | `references/protocol.md` 的入口、阶段与计划；`scripts/bath.ps1` 第 1–11 行 | 已实现 |
| 批次工具 → 项目工作区 | .NET / Win32 文件 API 核验、守卫修改与恢复 | `scripts/bath.ps1` 的 `BathNative`、Apply、Restore；`scripts/bath-rename.ps1` 的更名核验 | 已实现 |
| 批次工具 → D 保存区 | 本地文件 API 保存 before / after 字节、journal 和视图 | `scripts/bath.ps1` 第 519–573 行；`scripts/bath-group.ps1` 的备份阶段 | 已实现 |
| 批次工具 → 检查子进程 | 启动可信 PowerShell 检查脚本 | `scripts/bath.ps1` 第 318–332 行与 387–408 行 | 已实现 |
| 检查子进程 → D 保存区 | 通过 `ViewRoot` 读取副本；输出仅写声明前缀 | `references/protocol.md` 的范围与检查；`scripts/bath-view.ps1` 的检查子进程 | 已实现 |

批次工具的统一入口通过 `-Group` 支持关联文件及同父目录一次更名加关联文件。内部委派脚本仍属于 PowerShell 工具实现，没有按脚本数量画成微服务。

这套工具依赖 Windows、PowerShell 7.4+ 与固定本地 NTFS 普通对象。ViewRoot 是 D 盘副本，检查仍持有宿主权限；lease 不阻止其他程序写入。绿色表示本地执行，紫色表示文件存储，灰色表示用户；节点副标题保留 C4 类型与技术。

不添加 Component：目前问题是执行和存储边界，脚本内部模块细节不能帮助首用者。复杂时序已经用流程图说明；没有额外 Dynamic 图。没有部署拓扑证据，不创建 Deployment 图。
