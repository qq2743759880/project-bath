# 架构与流程图源

先读[系统边界](c4-context.md)，再读[运行单元](c4-containers.md)。[流程说明](workflow.md)包含正常清理、拒绝过期检查及冲突保留三个视图。

这些 HTML 是可下载后本地打开的交互文件。GitHub 文件页面不运行它们，当前没有公开在线交互地址。

| 视图 | 本地交互文件 | 可编辑图源 | C4 兼容语义源 |
|---|---|---|---|
| 系统上下文 | [HTML](../../assets/diagrams/c4-context.html) | [JSON](../../assets/diagrams/c4-context.json) | [Mermaid](../../assets/diagrams/c4-context.mmd) |
| 本地执行与保存 | [HTML](../../assets/diagrams/c4-containers.html) | [JSON](../../assets/diagrams/c4-containers.json) | [Mermaid](../../assets/diagrams/c4-containers.mmd) |
| 正常清理与拒绝 | [HTML](../../assets/diagrams/workflow-normal.html) | [JSON](../../assets/diagrams/workflow-normal.json) | — |
| 中断后先看现状 | [HTML](../../assets/diagrams/workflow-interruption.html) | [JSON](../../assets/diagrams/workflow-interruption.json) | — |
| 回退与冲突保留 | [HTML](../../assets/diagrams/workflow-recovery.html) | [JSON](../../assets/diagrams/workflow-recovery.json) | — |

## 静态图与阅读细节

这些是从通过原生检查的 HTML 内完整 SVG 离线生成的说明图，不是 GUI Export 回执或界面截图。图与解释在首页直接显示。

- 系统上下文：[PNG](../../assets/diagrams/c4-context.png) · [SVG](../../assets/diagrams/c4-context.svg)。
- 本地运行单元：[PNG](../../assets/diagrams/c4-containers.png) · [SVG](../../assets/diagrams/c4-containers.svg)。
- 正常清理：[PNG](../../assets/diagrams/workflow-normal.png) · [SVG](../../assets/diagrams/workflow-normal.svg)。
- 中断判断：[PNG](../../assets/diagrams/workflow-interruption.png) · [SVG](../../assets/diagrams/workflow-interruption.svg)。
- 恢复与保留：[PNG](../../assets/diagrams/workflow-recovery.png) · [SVG](../../assets/diagrams/workflow-recovery.svg)。
- 保存步骤细节：[PNG](../../assets/diagrams/workflow-normal-detail-save.png) · [SVG](../../assets/diagrams/workflow-normal-detail-save.svg)。
- 完成步骤细节：[PNG](../../assets/diagrams/workflow-normal-detail-complete.png) · [SVG](../../assets/diagrams/workflow-normal-detail-complete.svg)。
