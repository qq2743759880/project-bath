# 清理流程与交互阅读

[Open Interactive Diagram](https://qq2743759880.github.io/project-bath/) · [恢复交互图](https://qq2743759880.github.io/project-bath/recovery/)

![清理正常与异常路径](../assets/workflow.png)

图中步骤是交给Agent执行的方法，不是自动清理系统。绿色表示正常方法步骤；红色表示证据/原件保护和失败路径；紫色虚线表示只读或暂留分支。恢复细节拆为单独视图，避免长图掩盖判断条件。

点节点查看来源与上下游；路径按钮选择两个节点，只沿真实编写的有向连接探索；透镜按方法角色筛选；Live/Still控制有限trace动效；演示模式改变阅读布局。动态不改变规则，也不代表后台任务在运行。

## 源文件与离线使用

- [主流程 typed JSON](../assets/diagram-source/workflow.json)、[恢复 typed JSON](../assets/diagram-source/recovery.json)
- [主流程 self-contained HTML](index.html)、[恢复 self-contained HTML](recovery/index.html)：克隆后在浏览器本地打开即可，无需安装运行环境。
- [六秒trace WebM](../assets/workflow.webm)，这是阅读动效，非项目运行Demo。
- [备份与恢复说明](recovery.md)

## 对照原文

| 节点 / 连接条件 | 原始事实 |
|---|---|
| 确定范围、授权清理 / 仅审计 | [SKILL第1步](../SKILL.md#执行)：审计零写入；授权内可逆项执行；不清楚范围才澄清 |
| 建立基线 | 第2步：已有改动及失败单列 |
| 候选 → 证据充分 / 不足 | 第3步及判断依据：查真实入口引用、等价行为；不足暂留 |
| 保存 → 清理 / 暂留 | 第4步、备份规则：核验工作区原字节、hash、批次清单后才能写 |
| 清理 → 验收 → 交接 / 本轮回退 | 第4–6步：一个问题一批；重跑受影响检查；新增失败只回退本轮 |
| 恢复一致 / 后续改动 / 冲突 | 备份与恢复：只读本批清单，比对本轮后状态；补丁比对合并；冲突保留两份和现状 |

## 重建图像和HTML

使用[Archify官方 v3.0.1](https://github.com/tt-a1i/archify/releases/tag/v3.0.1)完整Skill。取得包后，从本仓根目录运行（将ARCHIFY目录换成自己的路径）：

```sh
node ARCHIFY/bin/archify.mjs finalize workflow assets/diagram-source/workflow.json docs/index.html --repo-root . --quality showcase --out-dir diagram-evidence --json
node ARCHIFY/bin/archify.mjs finalize workflow assets/diagram-source/recovery.json docs/recovery/index.html --repo-root . --quality showcase --out-dir recovery-evidence --json
```

源文件固定引用本仓原始Skill提交；该提交必须存在于本地Git对象中。原生finalize验证schema、showcase质量、来源、交付身份与真实浏览器；不要用单独render代替完整链。静态预览和WebM从原生viewer的导出菜单生成。重建工具需要Node与Chrome/Chromium；加载project-bath方法本身不需要这些工具。

[Archify MIT](../references/archify/LICENSE) · [原第三方声明](../references/archify/THIRD_PARTY_NOTICES.md) · [嵌入字体SIL OFL](../references/archify/JetBrainsMono-OFL.txt)。未使用第三方品牌标志。
