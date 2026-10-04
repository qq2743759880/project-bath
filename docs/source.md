# 来源与分发说明

本仓的 [SKILL.md](../SKILL.md) 与 [references/LICENSE](../references/LICENSE) 按项目维护者提供的 v0.1.3 源文件原字节发布。根 [LICENSE](../LICENSE) 是同一原始许可文本，保留全部版权声明；许可证标识为 `MIT`，不翻译该标识。

## 安装文件与展示文件

**Agent Runtime** 仅需 `project-bath/SKILL.md` 和 `project-bath/references/LICENSE`。获取 [v0.1.3 最小 Skill ZIP](https://raw.githubusercontent.com/qq2743759880/project-bath/main/distributions/project-bath-v0.1.3-skill.zip)，解压整个目录后按宿主规则安装，或让 Agent 直接读取其 SKILL.md。无需安装 Node、Python、浏览器图表工具或包管理器。

**GitHub Showcase** 包括 README、[身份图](../assets/hero.png)、流程/恢复静态预览、[交互 HTML 与 typed JSON](workflow.md)、恢复及本页说明。它们供人理解方法，不是 Agent Runtime 依赖。完整 clone 会获取这个展示面；安装时只选上述两个原始文件。

构建使用的 Snap-X 设计源、依赖锁、Archify 工具包、原生验收日志和审阅证据未作为目标项目使用依赖发布。交互 HTML 自包含其显示所需代码和字体，必要的 [展示许可声明](../references/archify/NOTICE.md) 随仓保留。

## v0.1.3 当前规则

v0.1.3 要求所有备份位于 D:/project-bath/<项目目录>/<批次>/；D 盘不可用或无写权限时保留原件、停止本批次并报告。项目目录以规范化根路径的哈希区分，批次不重名，跨盘先复制核验再移动，manifest 记录项目根归属。恢复先比对本轮后状态，保护后续改动；同名新文件不可覆盖，冲突保留两份。

因此本版 README、两份图源、HTML、静态图、动效、恢复和来源说明均按最新规则重新生成，交互节点来源固定到包含 v0.1.3 原文的真实 Git 提交。
