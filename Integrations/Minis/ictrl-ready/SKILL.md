---
name: ictrl-ready
description: Minis 通过已有配对操控本机 iCTRL；一次完整 UI 任务共用静音和自动锁屏会话，只读查询不跳快捷指令。
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

读界面、模型思考、点击和后续多个 shell 调用必须共用一个 `task_session.py` worker。一次任务只开始一次 Quiet、管理一次 Auto-Lock，结束时先恢复 Auto-Lock 再结束 Quiet。不要按每个点击、截图或短批启动新任务。

1. 开始前生成并保存一个随机 32 位十六进制 `task_id`。后续每条命令都带同一个 ID，不能把随机 ID 生成式直接放进可重复执行的 start。每个 UI 请求也预先保存独立的 32 位十六进制 `request_id`。
2. 用已有 `device:<id>` 开始：

```sh
python3 -B "$HOME/.ictrl/runtime/task_session.py" start --task-id TASK_ID --store-key 'device:<已有设备标识>'
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

`stop_requested` 或 `stopping` 不是恢复完成。只有 `complete` 且 `restore` 为 `restored`、`already_never`、`user_value_preserved`、`no_record` 或 `not_required` 才算已确认收尾。`unknown/pending` 保留原记录，停止 UI，不重新 Begin、不自动 inspect、不杀 Runner。静音回执不明时按服务器原有人工恢复流程处理。

## 时间、恢复与能力边界

Native 整个 lease 最长 300 秒，从 Begin 开始计时。worker 提前保留 75 秒恢复时间，status 的 `remaining_body_seconds` 是剩余可接单时间；准备本身也会消耗时间。预算不足就 finish 并汇报已完成部分，不自动续租、不连续开新会话维持长任务。75 秒是待真机验证的保守预留，不是恢复耗时保证。

Auto-Lock 原值必须从手机实际设置读取并保存，任务中按需设为永不；结束时恢复真实原值，用户中途改成别的值时保留用户改动。不要写死三分钟，不删除 `~/.ictrl/autolock` 或 `~/.ictrl/tasks` 掩盖 pending。新运行时不读取 Windows 的状态。

Minis 的停止按钮尚未与 worker 原生取消事件联动：能执行清理时先 finish；仅按停止不能保证立即恢复。进程崩溃/被系统挂起时也不能保证立即收尾，不能据 helper 安装成功或离线测试声称后台链路已通过真机验收。普通 Agent 任务不用手动终端替代实际 Agent 验收；交互终端与 Agent 的后台保活不同。

手动网页使用独立身份；本技能不改变手动通知策略。不解决 Automation Running 遮罩闪亮和物理触摸自动暂停。