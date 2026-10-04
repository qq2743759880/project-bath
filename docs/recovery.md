# 为什么先保存，以及怎样恢复

权威规则是 [原始 Skill：备份与恢复](../SKILL.md#备份与恢复)。清理前的工作区可能包含尚未提交的用户改动，所以 Git HEAD 不能代替实际原字节。

- 整文件移入冷归档；局部编辑前保存实际工作区原字节，核对 SHA-256。默认复用项目冷归档，否则用 `.agent-archive/project-bath/<批次>/`，保留相对路径。
- 批次 `manifest.json` 记录范围、原/备份路径、处置、前/后 hash、依据和检查；局部编辑另留仅包含本轮变化的可逆补丁。没有 Git 也保留备份与差异。
- 原件能回取还不够：还要确认冷归档退出实际搜索、上下文入口和构建。忽略文件或改成 `.bak` 并不能证明隔离。

恢复时让 Agent 只读取本批次清单，并给出准确范围：

```text
按本批次 manifest.json 恢复刚才的清理。先比较当前文件与本轮后状态。
一致时才直接恢复；后续修改请用本轮补丁比对、合并，保留我的内容。
同名新文件不得覆盖；不能安全合并时保留两份和现状，说明冲突。
```

这是交给已加载 Skill 的 Agent 的请求，不是 shell 命令。不要全局 reset/clean，也不要以整文件恢复覆盖后续用户修改。检查失败只回退本轮，已有失败单独说明；无改动不建空归档。

## 恢复路径图

[Open Interactive Recovery](https://qq2743759880.github.io/project-bath/recovery/)

![恢复前比对，后续修改合并，冲突保留两份](../assets/recovery.png)

[可编辑JSON](../assets/diagram-source/recovery.json) · [本地HTML](recovery/index.html)
