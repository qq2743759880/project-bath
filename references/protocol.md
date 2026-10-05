# 单文件工具协议

用绝对路径执行本 skill 内 `scripts/bath.ps1`，先调用 `-Action Help`。返回 JSON 的 `ok=false` 或非零退出码即停止对应操作。工具保护只在此入口生效；检查脚本是受信任代码，宿主没有全局只读限制。

```powershell
pwsh -NoProfile -File '<tool>' -Action Prepare -Root '<project>' -Plan '<plan.json>'
pwsh -NoProfile -File '<tool>' -Action Status -Root '<project>' -Batch '<returned batch>'
pwsh -NoProfile -File '<tool>' -Action Apply -Root '<project>' -Batch '<batch>'
pwsh -NoProfile -File '<tool>' -Action Check -Root '<project>' -Batch '<batch>' -CheckScript '<check.ps1>'
pwsh -NoProfile -File '<tool>' -Action Finalize -Root '<project>' -Batch '<batch>' -Receipt '<returned receipt>'
```

Prepare 计划严格限以下字段，路径相对项目根，不允许目录或多个 entry：

```json
{"schema_version":1,"entries":[{"path":"old.md","action":"archive","before_sha256":"<current bytes SHA256>","after_sha256":"absent","evidence":"actual semantic evidence"}]}
```

编辑改成 `action:"edit"`，`after_sha256` 为替换原字节 SHA，并增加绝对 `replacement_path`。可用 `Get-FileHash -LiteralPath ... -Algorithm SHA256` 取得小写 SHA。Prepare 冻结计划与替换快照，Apply 不采用后续外部修改。

Check 在确认 Applied 后，把普通项目文件复制到本批 D 盘 `view-*` 隔离目录；`ProjectRoot` 和工作目录都指向副本，不能依赖 `$PSScriptRoot` 指向项目。原项目现有文件/目录保持读取句柄，阻止常规写入、删除和换名；副本可写但任何字节、身份、写入时间或路径集合变化均使 receipt 失败，即使退出码是 0。副作用副本和脚本输出保留，不自动清理。原项目新增路径也会检测并拒绝 PASS，但不会删除它。限制：≤2048 文件、≤512 目录、单文件 ≤16 MiB、总字节 ≤64 MiB；复杂对象、过长路径或超限拒绝执行。需要原绝对路径、ACL、卷身份或副本以外服务的检查不适用，不能借助真实项目直跑来绕过保护。

30 秒超时；显式处理外部退出码，失败 `exit 1`。receipt 绑定输出、退出码、脚本 SHA、manifest、Apply 事件、时间、目标状态及原项目/副本清单 SHA。Finalize 核对最新 receipt、当前目标和两份清单。单独 `passed:true` 无效。此保护针对受信任检查的常见副作用，**不是 OS 沙箱**：显式绝对路径、网络、环境变量或逃逸子进程仍拥有宿主权限；禁止这样的检查。复制视图不是业务正确证明。

备份：`D:/project-bath/<项目名-根路径hash>/<唯一批次>/`。before.bin 是原工作区字节，plan.json / manifest.json / journal.jsonl 及检查资料用于回查；不要手改。恢复字节不承诺完整恢复时间、owner 等元数据。硬链接、ADS、reparse、自定义 ACL、特殊属性、路径过长等对象拒绝。

异常命令同样传 Root 和 Batch：

- `Restore`：已保存、已应用或 Completed 批次的回退。历史回退须 lease 空闲或仍归该批，重新核对 root/parent/备份/Apply 后状态后取得 lease；其它批次、后续用户修改、同名新对象均拒绝覆盖。归档用目标卷 CreateNew 复制 D 字节；编辑持写句柄核对后恢复。完成后 Restored、释放自己的 lease；历史完成 receipt 保留，不能再声明当前 Completed。中断仍先 Status；Stopped 不支持自动 Restore。
- `Cancel`：完整准备未形成且无操作日志的当前 owner；只写 Cancelled 并释放 lease，保留所有文件。不能取消已准备或已应用批次。
- `Close`：Applying / Restoring 未确认，或证据/目标冲突；只写 Stopped、观察快照与原因，并释放自己的 lease，不恢复、不删除。健康批次必须走正常路径。
- `Status`：只读。IncompletePrepare 用 Cancel；InterruptedRestore / AppliedUnconfirmed / Conflict 先判断可恢复性，未知则 Close。历史 Completed 后目标又变化，会显示 ChangedAfterCompletion；不能复用旧 PASS 宣称仍通过。

重复终态操作只可能释放该批仍持有的 lease，不能释放后来批次。项目级锁及持久 owner 防工具调用交错，不限制宿主其它写入。未知/损坏证据若工具拒绝，保留并报告，不自行清除控制文件。
