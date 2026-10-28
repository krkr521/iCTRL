# Minis originating-chat binding

The ordinary Minis workflow uses a completed prepare tool round before starting a
control lease. `task_session.py prepare` generates and privately saves independent
random task and nonce values, emits a structured receipt, and can share the existing
ensure shell call. No phone UI, pairing or model request is sent by prepare.

The next tool round resolves the nonce with `minis-sessions-cli list --keywords`
(global parts_json matching) with a limit of two: zero or multiple sessions refuse.
It then reads only the matching session's recent tool records and requires one exact
prepare command, an untruncated successful result with the same tool-use ID, and a
structured receipt matching both private values. A title-only hit, text quote, echo,
unfinished current tool, truncated input/output or duplicate match does not qualify.
It never selects the latest session. A repeated task start reuses its already bound
origin and cannot silently bind another chat.

The source basis is OpenMinis/OpenMinis revision
`6eda5523a9c14fa8edc4fd9fb72e643fe47f23be`:

- `src/ios/Agent/Chat/AIChatViewModel+AgentLoop.swift` defers assistant/tool-use DB
  writes until tool results are ready, then appends them in one transaction. Thus
  looking up the current shell's unpersisted command in the same call is invalid.
- `src/ios/Agent/Chat/ChatStore+SessionQueries.swift` queries session title or the
  entire messages.parts_json before LIMIT. Its search-message command subsequently
  filters non-text hits, so search is not used for this binding.
- `src/ios/NativeOffloads/SessionsOffloadBridge.swift` exposes full tool inputs and
  tool results with IDs, success and explicit truncation fields.
- `src/ios/Shared/DeepLinkRouter.swift`
  routes canonical `minis://sessions/<id>` to the specified session, not merely the
  app home. Dispatch is recorded separately from visible-chat verification.

The new workflow requires authenticated `minis_atomic_finish:1` before Begin.
Minis completion atomically binds origin routing, ending the captured lease and
closing its service. Explicit stay only skips returning. Unknown in-flight UI skips
returning but still requests owner-bound cleanup; no input is replayed. Ordinary
Codex End and its service keep-awake policy are unchanged.

Offline tests establish parsing, uniqueness, lifecycle and no-replay policy only.
The installed Minis persistence order, precise chat navigation, native closing and
service disappearance need physical acceptance. Crashes/suspension before finish
and the Minis stop button are not represented as a proven native cancellation hook.
