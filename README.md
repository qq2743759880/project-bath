<p align="center"><img src="./assets/hero.png" width="800" alt="project-bath Preview：先保存，再修改；受证据约束的清理与恢复"></p>

<h1 align="center">project-bath</h1>

<p align="center">给 Agent 的阶段性项目清理 Skill：先判断证据、保存当前原字节，再清理并验收。</p>

## 少一点项目噪声，多一点可恢复性

迭代后的旧文档、过期上下文或重复实现，容易让 Agent 误读项目。project-bath 帮你限定清理范围、识别有证据的候选，并保护现有行为与用户改动。日期旧、名字像临时文件、文本搜索零引用，都不足以判定可删；证据不够就暂留。

适合阶段性项目清理、清理前只读审计、已记录批次的回退与冲突诊断。普通功能开发、架构重构、单纯代码讲解不会触发；仅出现“洗澡”这个词也不够。

**Stable 为 v0.1.3。下方流程与工具说明面向 Preview v0.2.0-rc1；RC 是候选版，不替换稳定版。**

## 先看它怎样工作

[![RC1 工作流：判断证据、保存、应用、受信任检查、完成或恢复](./assets/workflow.png)](https://qq2743759880.github.io/project-bath/)

**[Open Interactive Diagram](https://qq2743759880.github.io/project-bath/)** · [异常与历史恢复动态图](https://qq2743759880.github.io/project-bath/recovery/) · [Trace 动效预览](./assets/workflow.webm)

Agent 先确认范围、授权、基线和已有改动，再提出一个有证据的清理点。RC1 每批只操作一个普通文件：

1. `Prepare` 保存当前工作区原字节，冻结计划与替换内容，校验成功后进入 `BackedUp`。
2. `Apply` 再核对目标与备份，执行归档或编辑，进入 `Applied`。
3. `Check` 在 D 盘隔离副本中执行受信任的只读检查，同时保护和核对原项目与副本。
4. `Finalize` 核验最新检查回执是否绑定本批实际 Apply 和当前 post-state，通过后进入 `Completed`，保留结果并释放项目 lease。

检查失败时先确认恢复条件，再 `Restore → Restored`。只读审计或证据不足时不修改项目。准备中断用 `Cancel`；没有安全自动恢复路径时先 `Status`，符合条件才用 `Close → Stopped`。**Stopped 只表示安全终止，不表示已经恢复。**

## 安装：选择 Stable 或 Preview

| 通道 | 版本 | 下载与发布说明 |
|---|---|---|
| 默认：Stable | v0.1.3 | [稳定 Runtime ZIP](https://raw.githubusercontent.com/qq2743759880/project-bath/v0.1.3/distributions/project-bath-v0.1.3-skill.zip) · [Stable Release](https://github.com/qq2743759880/project-bath/releases/tag/v0.1.3) |
| 可选：Preview | v0.2.0-rc1 | [候选 Runtime ZIP](https://raw.githubusercontent.com/qq2743759880/project-bath/v0.2.0-rc1/distributions/project-bath-v0.2.0-rc1.zip) · [Pre-release](https://github.com/qq2743759880/project-bath/releases/tag/v0.2.0-rc1) |

下载所选 ZIP，解压后将 `project-bath/` 放到你的 Agent 支持的 Skill 目录。具体目录由宿主决定；如果宿主没有 Skill 自动发现能力，让它读取已解压的 `SKILL.md`。Preview 建议先放到独立试用位置，不覆盖已安装的 Stable。

**实际安装到本机的 Preview Runtime 只有四个文件：**

```text
project-bath/
├─ SKILL.md
├─ references/
│  ├─ protocol.md
│  └─ LICENSE
└─ scripts/
   └─ bath.ps1
```

Stable 的 Runtime 为 `SKILL.md` 与 `references/LICENSE`。仓库 README、图、HTML 和展示文档用于阅读，不是 Agent 运行依赖；clone 整仓不等于应把所有文件装进 Skill 目录。

Preview 工具需要 **Windows、PowerShell 7.4+、本地固定 NTFS 卷，以及可用的 D 盘**。目标必须是普通文件，单文件不超过 16 MiB；目录、hardlink、ADS、reparse point、自定义 ACL、特殊属性、过长路径等会被拒绝。详见 [原生协议](./references/protocol.md)。

## Quick Start：先做只读审计

在 Preview 解压目录的上一级打开 PowerShell，先查看真实工具入口：

```powershell
pwsh -NoProfile -File ./project-bath/scripts/bath.ps1 -Action Help
```

预期得到支持的操作与工具约束，不修改项目。随后让有本地文件能力的 Agent 读取 `project-bath/SKILL.md`，给它一个真实项目路径和任务：

```text
使用 project-bath 只读审计 E:/work/my-app。
重点检查 docs/ 中旧阶段文档和重复实现；保留现有用户改动。
只列出有证据的候选、理由、风险和建议检查。不要修改、归档或恢复文件。
```

结果应是限定范围的候选报告与暂留理由。没有足够证据时得到 NoOp 是正常结果。下面三条路径按你要完成的任务选择。

## 三种真实任务

### 只读审计：先知道哪些值得清理

输入上面的审计请求，指定项目、关注范围和禁止修改。Agent 建立只读基线，核对候选的引用、动态加载与替代实现。它不会仅凭旧日期、名称或零文本引用删文件，也不会运行写入操作。你得到候选、证据、风险、暂留清单及后续验收建议。

### 正式清理：处理一个已确认的过期文档

```text
使用 project-bath 清理 E:/work/my-app 中已被当前部署说明替代的旧阶段文档。
先核对引用和替代内容，保留我的未提交改动。只处理有充分证据的一个文件。
用可信、只读的项目检查验收；如果该检查需要原绝对路径或外部服务，先停下来说明。
保存并校验备份后再应用，检查失败则核对恢复条件，最后交接批次与恢复入口。
```

Agent 把目标当前字节 SHA 与完整替换 SHA 绑定到单文件计划，计划及检查脚本放在项目外，通过工具完成 `Prepare → Apply → Check → Finalize`。它不会绕过拒绝直接删除文件、拿 Git HEAD 代替你当前工作区、把陌生检查当受信任程序，或把机器检查说成业务语义绝对正确。你得到实际变更、检查结果、批次路径、暂留内容和最终状态。

### 恢复 / 冲突处理：保留后来工作

```text
使用 project-bath 检查 E:/work/my-app 的既有批次。
我会提供之前交接的 D 盘 batch 路径；先用 Status 只读诊断。
只在工具确认当前目标、备份和 lease 条件仍匹配时恢复。
如果有后来编辑、另一活跃批次、证据损坏或未确认中断，保留现场并说明下一步，不强制覆盖。
```

Agent 先报告真实状态，再选择合法路径。未完成准备可 `Cancel`；安全条件满足可 `Restore`；无法安全自动恢复且终止条件有效时可 `Close`。`Completed` 历史批次也可恢复，但需要无其他活跃 batch、目标仍匹配，并再次核验根目录、父目录、备份与 Apply 后状态。它不会覆盖后来工作、删除别人持有的 lease、把 `Stopped` 当成 `Restored`，或自动清理 D 盘历史。你得到诊断、操作结果、保留下来的内容和可继续处理的证据。

## 为什么先保存，以及恢复边界

备份保存的是**当前文件原字节，包括未提交内容**。RC1 集中归档到 `D:/project-bath/<项目名-根路径hash>/<唯一批次>/`，包含原字节、计划、manifest、journal 和检查数据。D 盘不可用或备份校验失败时停止，不回退到直接清理项目。跨盘归档与恢复通过复制和校验完成；恢复归档文件要求目标路径空闲，不靠跨盘 rename 覆盖。

`Check` 是 **受信任检查，不是 OS sandbox**。检查脚本在隔离副本运行，接收 `ProjectRoot`；工具检测原项目和副本的内容、身份、mtime 与路径变化，新增或变化的内容保留供诊断。副本上限为 **2048 文件 / 512 目录 / 单文件 16 MiB / 总计 64 MiB / 30 秒**。依赖原绝对路径、卷身份、ACL 或外部可写服务的检查不适用。脚本仍可能具有绝对路径、网络、环境变量与逃逸子进程权限，因此只能执行可信检查。

过期或被修改的检查回执、其他 batch 的结果、浅层 `passed: true`、不匹配的 Apply event 和 post-state，都不能升级为 `Completed`。工具只证明检查与本批实际状态对应；清理是否符合业务语义仍由 Agent 判断。恢复不承诺还原完整 ACL、owner 或时间元数据。遇到拒绝保留证据，禁止手改 manifest、删除 lease 或强制覆盖。

## 按任务继续阅读

| 任务 | 文档 |
|---|---|
| 理解正常流程与源图 | [Workflow](./docs/workflow.md) |
| 取消、终止、冲突及历史恢复 | [恢复指南](./docs/recovery.md) |
| 对照各操作的条件与结果 | [控制面速查](./docs/control-plane.md) |
| 查看真实参数与计划格式 | [Runtime protocol](./references/protocol.md) |
| 查看 Runtime 来源与展示分层 | [Source 与分发说明](./docs/source.md) |

## License

project-bath 使用 [`MIT` 开源许可证](./references/LICENSE)。版本声明位于 [SKILL.md](./SKILL.md)。展示 HTML 使用 Archify；相关 MIT 与字体 notice 见 [展示许可说明](./licenses/showcase/archify/NOTICE.md)。
