---
name: ictrl-ready
description: Minis 通过已有配对操控本机 iCTRL；一次完整 UI 任务共用原生控制租约；结束时精确返回发起聊天并停止 Minis 占用的服务，不修改 Focus 或自动锁定设置。
---

使用当前 HOME 的 Minis 专用配对，不借 Windows 或浏览器身份、不新建配对、不改 VPN。手机锁定时请用户解锁，密码只在手机输入。

## 普通任务的最短已知路径

不要为“打开某App”等普通请求读取本技能源码、`--help`、遍历脚本目录或自制第二套会话。应用解析用 `resolve_app` 的 `{"text":"应用名"}`，不是 `{"name":...}`；已明确唯一bundle时直接在同一worker `launch_app`。只读批不能放 `automation_native_capabilities` 或其他 `automation_*` 管理方法；capabilities/register/begin/finish由worker内部处理，不能为此改用旧Quiet批次。

同一个 `shell_execute` 中提交已保存ID的命令并读取该独占结果文件，避免“call一个工具轮→再cat一个工具轮”的无用往返。start准备就绪后直接做所需最小动作，正文成功即finish，不等默认TTL耗尽。等待只轮询本地任务状态，不重复Begin或UI。

## 服务就绪

先用 `shell_execute` 执行：

```sh
python3 -B "$HOME/.ictrl/runtime/task_session.py" prepare && sh "$HOME/.ictrl/runtime/ensure-ictrl.sh"
```

首轮prepare只生成并保存随机task_id和origin_nonce，输出kind:ictrl_origin_prepared；保存返回的TASK_ID。此shell工具轮必须先完成，下一工具轮才能start；不能在同一正在执行的shell里查自己尚未持久化的tool_use。准备与ensure的工具结果完整成功且 `ok:true` 才继续。这只验证 schema，不能代替授权或点击验收。脚本未就绪时最多调用一次本机 prepare URL，不挂载 DDI、不切 VPN；明确缺 DDI 时才提示使用手机已有挂载流程。不要为了就绪反复打开快捷指令。

## 只有读取

独立查询 `device_info`、`resolve_app`、`find_element`、`page_source` 等，可以将 1–100 条命令写为 JSON 数组：

```sh
python3 -B "$HOME/.ictrl/runtime/quiet_batch.py" /path/read.json --store-key 'device:<已有设备标识>' --results-file /path/new-read-results.jsonl
```

整批只读才会执行，不调用 Begin/End，不进入设置。`config` 只有空参数算只读；未知方法、管理 RPC 或混入点击会在任何 RPC 前拒绝。需要页面结果时必须指定全新私有结果文件并读取它，stdout 不是页面正文。旧 `quiet_batch.py` 的 UI 入口已停用，出现 `ui_requires_task_session` 时改用以下任务流程，不能换文件名重试旧 UI 批次。

## 默认收尾规则（协议 native15-minis-atomic-v1）

用户已明确：Minis 任务结束后退出 Automation Running/停止 iCTRL 服务与F13；Codex 远控保留服务。两者策略不同，不能修改全局保活开关代替任务收尾。普通任务默认返回**发起这次任务的具体聊天**，再结束控制并停止服务；只有用户明确要求打开某App或停留某页面，才选择 `--completion stay`，但仍必须结束控制并停服。

发起前执行上面的prepare+ensure首轮，保存prepare返回的真实TASK_ID。下一工具轮的start会按私有记录中的随机nonce，全局 `list --keywords nonce --limit 2` 唯一匹配session，再读取该会话tool记录，核对确实是本次prepare命令且成功工具结果含同task_id/nonce。它不是按latest猜，也不会查询正在执行中的工具。零匹配、重复、截断、未完成记录一律在Begin前拒绝。若调用环境已提供受信当前session id，可显式 `--origin-session-id`，不要求普通用户手填。精确路由是 `minis://sessions/<id>`；不能用`minis://done`或仅激活Minis首页冒充回原聊天。

## 一次完整 UI 任务

读界面、模型思考、点击和后续多个 shell 调用必须共用一个 `task_session.py` worker。一次任务只开始一次 native lease，由 worker 每 5 秒发送认证心跳；服务端约 15 秒收不到心跳会撤销任务 UI 授权。正常任务不打开 Settings，不改 Auto-Lock，不切 Focus，不运行静音快捷指令。不要按每个点击、截图或短批启动新任务。

1. 使用首轮prepare生成并已保存的随机32位十六进制 `task_id`，不要在start里重新生成。后续每条命令都带同一个 ID，不能把随机 ID 生成式直接放进可重复执行的 start。每个 UI 请求也预先保存独立的 32 位十六进制 `request_id`。
2. 用已有 `device:<id>` 开始：

```sh
python3 -B "$HOME/.ictrl/runtime/task_session.py" start --task-id TASK_ID --store-key 'device:<已有设备标识>' --ttl-seconds 240 --wait-ready 20
python3 -B "$HOME/.ictrl/runtime/task_session.py" status --task-id TASK_ID
```

`starting` 时只观察 status，等待 `running` 后才能调用。start 默认在同一shell内最多20秒观察本地准备状态（`--wait-ready 20`），不会等满TTL；超时仍为starting只观察status，不重发start。重复同一 task_id 只观察旧任务；未知、未恢复或仍运行的旧任务不允许换 ID 重开。不要接管别的 Minis 任务。

3. 同一 worker 内逐条调用并读取独占的结果文件，例如：

```sh
python3 -B "$HOME/.ictrl/runtime/task_session.py" call --task-id TASK_ID --request-id REQUEST_ID --method page_source --params '{"visible_only":true}' --results-file /path/new-result.json --wait 90
```

`TASK_ID`、`REQUEST_ID` 是已保存 ID 的占位符。`--params` 是 JSON 数据，不能带 `automation_session`。一次只允许一条未完成请求。Minis `shell_execute` 的 timeout 设为 120 秒，必须比这里的 90 秒等待更长；不要在外层只等几十秒。也不要并行提交点击。

相同请求 ID、相同内容只读取旧结果，不再次发送；同 ID 不同内容拒绝。结果为 `unknown`、`expired` 或 shell 超时时，先观察状态/已有结果，不换 ID 重放可能执行过的操作。请求过期尚未发送时不会迟发 UI；已经在途的操作不能撤销，仍可能完成。

4. 正文完成后**立即** finish，不为等待TTL而空转，不先回复“完成”。失败、超时或用户要求停止时同样执行一次finish；未知在途操作不重放，安全跳过额外返回UI。Minis专用 `automation_native_finish` 把精确返回路由、End、关闭服务授权与官方停服关联到同一owner/lease，不能自行 End 后再 `config stop_server`，避免误停新owner。

```sh
python3 -B "$HOME/.ictrl/runtime/task_session.py" finish --task-id TASK_ID --wait 30
python3 -B "$HOME/.ictrl/runtime/task_session.py" status --task-id TASK_ID
```

`finish --wait 30` 在不占任务锁时有界等待，超时/不确定退出非零；不要因此重发动作。`stop_requested` 或 `stopping` 不是恢复完成。先确认 `control_end_confirmed:true`；只有 `complete` 且 `restore` 为 `restored`、`already_never`、`user_value_preserved`、`no_record` 或 `not_required` 才算控制租约已确认结束。还要分别读取 `return_to_chat`：`return_route:dispatched` 仅为指定聊天路由已排队，`chat_verified:false` 不等于工具看到了正确聊天；`service_finish:closing` 是服务端接受停服并同步撤销保活授权，不冒充已观察到进程消失。答复时按实际字段说明，不把 `restore:not_required` 当作回聊天证明。`unknown/pending` 保留原记录，停止 UI，不重新 Begin、不自动 inspect、不杀 Runner。旧 Quiet 回执不明时保留 pending，按原有明确恢复流程处理，不能直接开启新版会话掩盖记录。

## 时间、恢复与能力边界

Native 整个 lease 最长 300 秒，从 Begin 开始计时；start 的 TTL 默认 240 秒，可显式指定 1–300 秒。75 秒及以下不足以留下正文预算，会在 Begin 前拒绝；准备后余量不足 75 秒时不进入任务 UI。默认 240 是为五分钟上界留余量，故障根因尚未确认。相同 task ID 的 TTL 必须一致，旧状态缺少 TTL 按 300 秒解释。worker 提前保留 75 秒恢复时间，status 的 `remaining_body_seconds` 是剩余可接单时间；准备本身也会消耗时间。预算不足就 finish 并汇报已完成部分，不自动续租、不连续开新会话维持长任务。75 秒是待真机验证的保守预留，不是恢复耗时保证。

新版任务不读取或写入系统 Auto-Lock。开始时只检查本地旧记录；存在任何旧 Auto-Lock 记录时停止并明确恢复，不删除 `~/.ictrl/autolock` 或 `~/.ictrl/tasks` 掩盖 pending。新运行时不读取 Windows 的状态。旧恢复模块保留供明确恢复使用。

Minis 的停止按钮尚未与 worker 原生取消事件联动：能执行清理时先 finish；仅按停止不能保证立即恢复。进程崩溃/被系统挂起时也不能保证立即收尾，不能据 helper 安装成功或离线测试声称后台链路已通过真机验收。普通 Agent 任务不用手动终端替代实际 Agent 验收；交互终端与 Agent 的后台保活不同。

新任务必须通过认证的 `automation_native_capabilities` 确认 `minis_atomic_finish:1`、已知F13契约、显式弹窗策略及当前 available；旧 Runner 明确拒绝，不自动回退 Settings/Quiet。XCTest 仅处理实际阻挡交互的预期弹窗，未知弹窗阻断后续输入；它不能保证屏蔽普通通知横幅，也不提供静音保证。F13 依赖私有 XCTest 能力，编译成功不等于本机保活已验收。手机锁定时停止并请用户解锁。

手动网页使用独立身份；本技能不改变手动通知策略。Automation Running 遮罩闪亮研究已停止，此包不宣称解决遮罩或物理触摸自动暂停。

Native14 的已知能力契约为 `keep_awake:f13_service`、`keep_awake_scope:runner_service`、`ui_control_scope:owner_lease`。Runner 服务/Automation Running 就绪后，即使未连接或任务结束，仍每10秒 F13 保活；服务停止才停止该保活并恢复系统既有3分钟自然锁屏行为。手动锁屏有效，锁态未知时暂停；解锁后服务保活可恢复，但旧任务 lease 永不复活。Native12/13 的 `f13_lease` 旧契约仍可识别；未知契约拒绝。

服务 pulse 或 `service_keep_awake_running:true` 不是任务授权。UI 仍必须有本身份的 active lease、有效 TTL 与心跳；End/TTL/失联只撤销任务 UI，不应报告为 Native14 服务 F13 已停止。不要靠持续保活擅自续租或沿用 ended/expired lease。


本技能依赖认证的minis_atomic_finish:1；Native14仅具原End，不具Minis原子停服事务。以本次真实能力读回决定是否可执行，不能把技能文件已安装当作Runner已升级或真机验收成功。Minis原生停止按钮与worker取消事件仍未证明联动；进程挂起/崩溃边界需独立证据，不因技能文字改变而标成功。


更新技能后旧聊天可能仍持有旧版已读上下文。验收要使用新聊天，或在实际tool记录中确认重新file_read了包含协议标记native15-minis-atomic-v1的当前文件，并核对部署hash；仅替换磁盘文件不算真实Agent已使用新流程。
