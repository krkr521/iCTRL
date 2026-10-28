---
name: ictrl-ready
description: Minis 通过已有配对操控本机 iCTRL；一次完整 UI 任务共用 Native12 F13 保活会话，不修改 Focus 或自动锁定设置。
---

使用当前 HOME 的 Minis 专用配对，不借 Windows 或浏览器身份、不新建配对、不改 VPN。手机锁定时请用户解锁，密码只在手机输入。

## 服务就绪

先用 `shell_execute` 执行：

```sh
sh "$HOME/.ictrl/runtime/ensure-ictrl.sh"
```

只有 `ok:true` 才继续。这只验证 schema，不能代替授权或点击验收。脚本未就绪时最多调用一次本机 prepare URL，不挂载 DDI、不切 VPN；明确缺 DDI 时才提示使用手机已有挂载流程。不要为了就绪反复打开快捷指令。

## 只有读取

独立查询 `device_info`、`resolve_app`、`find_element`、`page_source` 等，可以将 1–100 条命令写为 JSON 数组：

```sh
python3 -B "$HOME/.ictrl/runtime/quiet_batch.py" /path/read.json --store-key 'device:<已有设备标识>' --results-file /path/new-read-results.jsonl
```

整批只读才会执行，不调用 Begin/End，不进入设置。`config` 只有空参数算只读；未知方法、管理 RPC 或混入点击会在任何 RPC 前拒绝。需要页面结果时必须指定全新私有结果文件并读取它，stdout 不是页面正文。旧 `quiet_batch.py` 的 UI 入口已停用，出现 `ui_requires_task_session` 时改用以下任务流程，不能换文件名重试旧 UI 批次。

## 一次完整 UI 任务

读界面、模型思考、点击和后续多个 shell 调用必须共用一个 `task_session.py` worker。一次任务只开始一次 Native12 lease，由 worker 每 5 秒发送认证心跳；服务端约 15 秒收不到心跳会撤销任务 UI 授权。正常任务不打开 Settings，不改 Auto-Lock，不切 Focus，不运行静音快捷指令。不要按每个点击、截图或短批启动新任务。

1. 开始前生成并保存一个随机 32 位十六进制 `task_id`。后续每条命令都带同一个 ID，不能把随机 ID 生成式直接放进可重复执行的 start。每个 UI 请求也预先保存独立的 32 位十六进制 `request_id`。
2. 用已有 `device:<id>` 开始：

```sh
python3 -B "$HOME/.ictrl/runtime/task_session.py" start --task-id TASK_ID --store-key 'device:<已有设备标识>' --ttl-seconds 240
python3 -B "$HOME/.ictrl/runtime/task_session.py" status --task-id TASK_ID
```

`starting` 时只观察 status，等待 `running` 后才能调用。start 不会等待后台准备完成。重复同一 task_id 只观察旧任务；未知、未恢复或仍运行的旧任务不允许换 ID 重开。不要接管别的 Minis 任务。

3. 同一 worker 内逐条调用并读取独占的结果文件，例如：

```sh
python3 -B "$HOME/.ictrl/runtime/task_session.py" call --task-id TASK_ID --request-id REQUEST_ID --method page_source --params '{"visible_only":true}' --results-file /path/new-result.json --wait 90
```

`TASK_ID`、`REQUEST_ID` 是已保存 ID 的占位符。`--params` 是 JSON 数据，不能带 `automation_session`。一次只允许一条未完成请求。Minis `shell_execute` 的 timeout 设为 120 秒，必须比这里的 90 秒等待更长；不要在外层只等几十秒。也不要并行提交点击。

相同请求 ID、相同内容只读取旧结果，不再次发送；同 ID 不同内容拒绝。结果为 `unknown`、`expired` 或 shell 超时时，先观察状态/已有结果，不换 ID 重放可能执行过的操作。请求过期尚未发送时不会迟发 UI；已经在途的操作不能撤销，仍可能完成。

4. 任务完成、失败或用户要求停止时，发送一次 finish，再只观察状态：

```sh
python3 -B "$HOME/.ictrl/runtime/task_session.py" finish --task-id TASK_ID
python3 -B "$HOME/.ictrl/runtime/task_session.py" status --task-id TASK_ID
```

`stop_requested` 或 `stopping` 不是恢复完成。只有 `complete` 且 `restore` 为 `restored`、`already_never`、`user_value_preserved`、`no_record` 或 `not_required` 才算已确认收尾。`unknown/pending` 保留原记录，停止 UI，不重新 Begin、不自动 inspect、不杀 Runner。旧 Quiet 回执不明时保留 pending，按原有明确恢复流程处理，不能直接开启新版会话掩盖记录。

## 时间、恢复与能力边界

Native 整个 lease 最长 300 秒，从 Begin 开始计时；start 的 TTL 默认 240 秒，可显式指定 1–300 秒。75 秒及以下不足以留下正文预算，会在 Begin 前拒绝；准备后余量不足 75 秒时不进入任务 UI。默认 240 是为五分钟上界留余量，故障根因尚未确认。相同 task ID 的 TTL 必须一致，旧状态缺少 TTL 按 300 秒解释。worker 提前保留 75 秒恢复时间，status 的 `remaining_body_seconds` 是剩余可接单时间；准备本身也会消耗时间。预算不足就 finish 并汇报已完成部分，不自动续租、不连续开新会话维持长任务。75 秒是待真机验证的保守预留，不是恢复耗时保证。

新版任务不读取或写入系统 Auto-Lock。开始时只检查本地旧记录；存在任何旧 Auto-Lock 记录时停止并明确恢复，不删除 `~/.ictrl/autolock` 或 `~/.ictrl/tasks` 掩盖 pending。新运行时不读取 Windows 的状态。旧恢复模块保留供明确恢复使用。

Minis 的停止按钮尚未与 worker 原生取消事件联动：能执行清理时先 finish；仅按停止不能保证立即恢复。进程崩溃/被系统挂起时也不能保证立即收尾，不能据 helper 安装成功或离线测试声称后台链路已通过真机验收。普通 Agent 任务不用手动终端替代实际 Agent 验收；交互终端与 Agent 的后台保活不同。

必须通过认证的 `automation_native_capabilities` 确认 Native12、F13 lease、显式弹窗策略及当前 available；旧 Runner 明确拒绝，不自动回退 Settings/Quiet。XCTest 仅处理实际阻挡交互的预期弹窗，未知弹窗阻断后续输入；它不能保证屏蔽普通通知横幅，也不提供静音保证。F13 依赖私有 XCTest 能力，编译成功不等于本机保活已验收。手机锁定时停止并请用户解锁。

手动网页使用独立身份；本技能不改变手动通知策略。Automation Running 遮罩闪亮研究已停止，此包不宣称解决遮罩或物理触摸自动暂停。

Native14 的已知能力契约为 `keep_awake:f13_service`、`keep_awake_scope:runner_service`、`ui_control_scope:owner_lease`。Runner 服务/Automation Running 就绪后，即使未连接或任务结束，仍每10秒 F13 保活；服务停止才停止该保活并恢复系统既有3分钟自然锁屏行为。手动锁屏有效，锁态未知时暂停；解锁后服务保活可恢复，但旧任务 lease 永不复活。Native12/13 的 `f13_lease` 旧契约仍可识别；未知契约拒绝。

服务 pulse 或 `service_keep_awake_running:true` 不是任务授权。UI 仍必须有本身份的 active lease、有效 TTL 与心跳；End/TTL/失联只撤销任务 UI，不应报告为 Native14 服务 F13 已停止。不要靠持续保活擅自续租或沿用 ended/expired lease。
