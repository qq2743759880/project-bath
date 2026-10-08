# 工具协议（0.2.0-rc2 工程 staging）

Windows / PowerShell 7.4+ / 固定本地 NTFS 普通对象。先运行绝对路径 `scripts/bath.ps1 -Action Help` 核对候选实际能力。`ok=false` 或非零退出即停止对应操作。

## 入口、阶段与计划

schema 1 单文件不加 `-Group`。schema 2 关联文件和 schema 4 更名加关联文件均用同一 `bath.ps1 -Group`；没有 `-Mixed`，不另建 coordinator 或嵌套更名批次。组件脚本不作为日常独立入口。

schema 1/2 使用 Prepare、Status、Apply、Restore、Check、Finalize、Close；Cancel 仅用于旧单文件准备失败。schema 4 分两阶段：A 先验证 Prepare/Apply/Restore/Close，完整备份可 `execution_ready=true`，但 Check/Finalize 明确阻止且 `eligible_for_finalize=false`；B 在 A 验收和功能门证据后，才为新建、匹配最终 runtime 的批次开放 Check/Finalize。旧 manifest 不升级；A 的 Applied 用 Restore，不能改名 Completed 来释放 lease。

```powershell
pwsh -NoProfile -File '<tool>/bath.ps1' -Group -Action Prepare -Root '<project>' -Plan '<plan.json>' -Scope '<scope.json>'
# Check/Finalize 仅用于已验收的阶段 B：
pwsh -NoProfile -File '<tool>/bath.ps1' -Group -Action Check -Root '<project>' -Batch '<batch>' -CheckScript '<check.ps1>'
pwsh -NoProfile -File '<tool>/bath.ps1' -Group -Action Finalize -Root '<project>' -Batch '<batch>' -Receipt '<returned receipt>'
```

单文件去掉 `-Group`；Status/Apply/Restore/Close 用 `-Action <操作> -Root <project> -Batch <returned batch>`。Scope 仅 Prepare 传入并冻结。group 未传时选整个根：inputs `["."]`、无排除或输出。单文件未传 Scope 的兼容检查接受 `ProjectRoot`，视图任何变化拒绝 PASS；传 Scope 后接受 `ViewRoot`。

schema 1 恰好一个 entry；schema 2 使用相同文件字段并增加唯一 `entry_id`：

```json
{"schema_version":2,"entries":[{"entry_id":"retire","path":"old.md","action":"archive","before_sha256":"<current SHA256>","after_sha256":"absent","evidence":"替代入口已覆盖旧内容"}]}
```

schema 1 省略 entry_id。edit 要完整 replacement_path 与小写 after SHA；archive 要 `after_sha256="absent"` 且禁止 replacement_path。before SHA 是当前用户工作区字节，可用 `Get-FileHash -LiteralPath ... -Algorithm SHA256` 转小写，不能用 Git HEAD 替代。

schema 4 顶层只有 schema_version、rename、非空 entries：

```json
{"schema_version":4,"rename":{"entry_id":"rename","path":"docs/old","destination":"docs/current","evidence":"实际入口与引用同步更名"},"entries":[{"entry_id":"inside","path":"docs/old/index.md","action":"edit","before_sha256":"<current SHA256>","after_sha256":"<replacement SHA256>","evidence":"更新目录内入口","replacement_path":"<absolute replacement path>"}]}
```

一次普通目录更名，源/目标在同一现存普通父目录下，目标任何对象均不存在；关联文件至少一个，可全部位于源子树外，也可位于内部或两者兼有；不要求为更名额外修改目录内文件。文件 path 始终是更名前路径；Prepare 计算 path_after，调用者不得提供。仅按路径边界映射：`docs/old/a`→`docs/current/a`，不改 `docs/old2/a`。文件字段复用 schema 2，ID 在 rename 和所有 files 间唯一。

路径使用规范项目相对正斜杠，大小写不敏感去重；ID 为 `[a-z][a-z0-9_-]{0,63}`。拒绝 JSON 类型错误、未知/重复键及别名。禁止根/跨父/多次/嵌套/仅大小写更名，禁止文件初始位于目标子树、目录作为文件 entry、映射碰撞及隐式创建目录。复杂对象、硬链接、ADS、reparse、自定义 ACL、特殊属性和过长路径仍拒绝。

## 范围与检查

scope schema 1 示例；是否排除由 Agent 判断，不自动排除依赖：

```json
{"schema_version":1,"inputs":["."],"excluded":[{"path":".venv","reason":"本次纯文档检查不依赖该环境"},{"path":".cache","reason":"本次生成的缓存不作为输入"}],"outputs":[".cache"],"limits":{"max_files":0}}
```

inputs 非空、不重叠且存在，`.` 选整个根；excluded 为带非空理由的精确路径/子树，非 glob。outputs 为仅视图可写目录前缀，不能是 `.` 或现存文件；已有输出位于输入时先明确排除。修改目标必须被输入覆盖且不能与排除/输出相交。归档不能选会消失的精确文件输入，应选仍存在的父目录。排除代表不复制、不验证，不代表依赖行为通过。

默认 max_files=0，省略同样无文件数量上限；正整数可限量。仍默认 512 目录、单文件 16 MiB、总计 64 MiB、30 秒；硬上限为 100000 目录、总计 1 GiB、300 秒，单文件仍最多 16 MiB。目录包括根及必要祖先，其余 limits 为受硬上限约束的正整数；不保证无限资源或 OOM 安全。Preview 只读；Ready 不等于修改就绪/授权。

mixed 保留原 scope，并按同一路径映射生成 scope-after；保留理由、limits、顺序及字段存在性。两个 scope、原选中快照和确认事件共同绑定更名后快照，包括外部未改文件及空目录。即使 Check 排除某个未改子树，namespace ledger 仍普查更名目录的全部子项；Check scope 不能缩小更名安全核验。

scoped Check 将输入复制到保留的 D 视图，工作目录及 ViewRoot 指向副本。脚本只通过 ViewRoot 定位项目，不能把 PSScriptRoot 当项目根；缓存/报告只写 outputs。其他输入的字节、身份、写入时间或路径集合变化、源状态变化均拒绝 PASS。

```powershell
param([Parameter(Mandatory)][string]$ViewRoot)
Set-Location -LiteralPath $ViewRoot
& '<checker>'
if ($LASTEXITCODE -ne 0) { exit 1 }
exit 0
```

主入口与 group 每次检查先记录 CheckStarted；最新失败或中断立即使旧 PASS 失效。Checked/新 receipt 绑定该 check_attempt_event_id；Finalize 仅接受最新实际成功尝试的原 receipt。证据绑定批次、manifest、完整 Apply 事件、runtime、scope、选中状态和保留运行；mixed 还绑定双 scope、完整 namespace。Finalize 再查当前状态与证据，正常 Completed 先确认再释放自己的 lease。实验 `bath-view.ps1` receipt 的 eligible_for_finalize=false，不能直接完成批次。

检查仍有宿主权限。需要原卷、ACL、原绝对路径或外部可写服务的检查不适用，明确未验证，不绕过工具直跑。检查充分性与业务语义由 Agent 负责；视图不是 OS 沙箱；未运行的并发观察器不能称已通过。

## D 保存、恢复与停止

`D:/project-bath/<项目名-根hash>/<唯一批次>/` 保存实际原字节：单文件 before.bin；group/mixed 每个修改文件 entries/<entry_id>/before.bin，edit 另存完整 after.bin。mixed 对其他更名子项保存完整 namespace ledger，**不备份整棵树的文件字节**。原计划、runtime、双 scope、namespace 及全部修改文件备份均须保存/readback 核验后才允许首个项目写入；缺失或篡改任一备份拒绝全部写入。

一把项目锁、一个 owner lease、一个批次；逐项意图及精确确认持久记录。mixed 先确认目录更名，再重新核验映射后的全部文件/父目录并依计划修改；仅更名 Applied 不等于整批 Applied。不能宣称目录 ACID 或冻结全树事务。

- Restore：只恢复有自身确认 Applied 事件且当前状态匹配的文件，逆序执行；mixed 在 path_after 恢复文件，然后才逆转目录。归档恢复 CreateNew，原名必须不存在。用户后续修改、同名新对象或未知写入保留；安全项可先恢复，残余冲突保持 lease，禁止目录逆转。逆转前普查完整 namespace，仅自身确认 Restored 事件的文件可更新预期 ID/写入时间，未改子项保留原 ID/时间；不接受仅哈希匹配或拿当前观察值当授权。原源名必须空闲，父目录/目标 ID 必须匹配。完整 Restored 才释放自己的 lease；重复 Restore 只核验不写入。
- 历史 Completed Restore：须 lease 空闲或归自己，核对原 intent 及当前状态，不能释放后来的 owner。Stopped 不自动 Restore。Apply/Check 绑定 runtime；安全恢复仍须格式/字节/确认事件守卫。
- Status：只读实际 namespace 与逐项状态、确认前缀及冲突。意图无精确确认即未知写入，不因字节相同猜测成功；损坏/歧义 journal 禁止自动修改。
- Close：intact 当前 owner 对准备不完整、未确认中断或冲突保存 stopped.json，再释放自己的 lease；不写项目，`restored=false`、Stopped 不等于完整恢复。mixed 可关闭尚未 Apply 的 BackedUp；schema 2 的健康 BackedUp 用 Restore；健康批次用 Restore 或已开放的 Finalize。重试不得释放别人 lease，不删除坏证据。
- Cancel：仅旧单文件未完整准备且无操作日志的当前 owner；group/mixed 用 Close。

恢复字节不承诺恢复全部 owner/时间等元数据；锁/lease 不限制其他宿主写入。只有真实终态、自己的 lease 释放及充分检查有证据才报告完成。
