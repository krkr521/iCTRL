---
name: ictrl-phone-control
description: 在 Windows 通过已配对的 iCTRL Native12 会话操控 iPhone；F13 保活，不修改系统自动锁定或 Focus。
---

使用本机已安装的 iCTRL 客户端。先读本机 references/local-runtime.md 与 installation.json，不复制配对密钥、不重新配对、不清空 .state。

正常 UI 任务必须通过 `scripts/phone_task.py run --script <UTF-8任务脚本>` 执行。任务脚本直接 `import control` 并调用 `control.rpc_call()`，不嵌套会话。默认 TTL 120 秒，显式 `--ttl-seconds 300` 为上限，不能自动续租。脚本结束、异常或停止时发送一次 End；超时后先观察结果，不重放输入。

入口须通过认证的 automation_native_capabilities 确认 native session、已知 f13_lease 或 f13_service 完整契约、explicit_alerts_only 及当前 available。旧 Runner 拒绝正常任务，不静默回退 Settings 或 Quiet。F13 依赖私有 XCTest 接口，静态检查或编译通过不等于实际保活验收；手机已锁定时请用户本人解锁。

正常任务不打开 Settings，不读取或修改 Auto-Lock，不切 Focus，不运行静音快捷指令。每 5 秒认证心跳，服务器约 15 秒未收到即撤销任务 UI 授权；断网、崩溃和系统挂起不能保证立即 End。存在旧 Auto-Lock 记录则停止并保留，`end` 仅供明确补恢复旧记录；旧 Quiet pending 按原恢复流程处理，不能清记录掩盖不确定状态。`begin` 不用于持久占用会话；使用完整 run。

XCTest interruption handling 仅针对实际阻挡交互的预期弹窗；未知弹窗阻断后续输入。普通通知横幅仍可能出现，不承诺静音或跨设备通知抑制。已停止 Automation Running 遮罩闪亮研究，不宣称解决遮罩或物理触摸暂停。

只读状态、源码研究不启动会话。若连接失败先查 gateway 状态，不重启代理、重配对或重播未知 UI。Minis 使用自己的已配对身份和手机内 ictrl-ready 技能。分别报告任务结果、native End 和任何旧 pending；未安装或未经真机验收必须明确说明。


Native14 的已知能力契约为 `keep_awake:f13_service`、`keep_awake_scope:runner_service`、`ui_control_scope:owner_lease`。Runner 服务/Automation Running 就绪后，即使未连接或任务结束，仍每10秒 F13 保活；服务停止才停止该保活并恢复系统既有3分钟自然锁屏行为。手动锁屏有效，锁态未知时暂停；解锁后服务保活可恢复，但旧任务 lease 永不复活。Native12/13 的 `f13_lease` 旧契约仍可识别；未知契约拒绝。

服务 pulse 或 `service_keep_awake_running:true` 不是任务授权。UI 仍必须有本身份的 active lease、有效 TTL 与心跳；End/TTL/失联只撤销任务 UI，不应报告为 Native14 服务 F13 已停止。不要靠持续保活擅自续租或沿用 ended/expired lease。


Native15为Minis增加专用原子收尾：返回原聊天（用户明确stay例外）、End并停手机服务。Codex Windows仍使用普通End，保持Runner服务/F13运行；不要把Minis偏好套到Codex，也不要因Automation Running仍显示就判End失败。
