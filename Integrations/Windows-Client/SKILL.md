---
name: ictrl-phone-control
description: 在 Windows 通过已配对的 iCTRL Native12 会话操控 iPhone；F13 保活，不修改系统自动锁定或 Focus。
---

使用本机已安装的 iCTRL 客户端。先读本机 references/local-runtime.md 与 installation.json，不复制配对密钥、不重新配对、不清空 .state。

正常 UI 任务必须通过 `scripts/phone_task.py run --script <UTF-8任务脚本>` 执行。任务脚本直接 `import control` 并调用 `control.rpc_call()`，不嵌套会话。默认 TTL 120 秒，显式 `--ttl-seconds 300` 为上限，不能自动续租。脚本结束、异常或停止时发送一次 End；超时后先观察结果，不重放输入。

入口须通过认证的 automation_native_capabilities 确认 Native12 session、f13_lease、explicit_alerts_only 及当前 available。旧 Runner 拒绝正常任务，不静默回退 Settings 或 Quiet。F13 依赖私有 XCTest 接口，静态检查或编译通过不等于实际保活验收；手机已锁定时请用户本人解锁。

正常任务不打开 Settings，不读取或修改 Auto-Lock，不切 Focus，不运行静音快捷指令。每 5 秒认证心跳，服务器约 15 秒未收到即停止保活；断网、崩溃和系统挂起不能保证立即 End。存在旧 Auto-Lock 记录则停止并保留，`end` 仅供明确补恢复旧记录；旧 Quiet pending 按原恢复流程处理，不能清记录掩盖不确定状态。`begin` 不用于持久占用会话；使用完整 run。

XCTest interruption handling 仅针对实际阻挡交互的预期弹窗；未知弹窗阻断后续输入。普通通知横幅仍可能出现，不承诺静音或跨设备通知抑制。已停止 Automation Running 遮罩闪亮研究，不宣称解决遮罩或物理触摸暂停。

只读状态、源码研究不启动会话。若连接失败先查 gateway 状态，不重启代理、重配对或重播未知 UI。Minis 使用自己的已配对身份和手机内 ictrl-ready 技能。分别报告任务结果、native End 和任何旧 pending；未安装或未经真机验收必须明确说明。
