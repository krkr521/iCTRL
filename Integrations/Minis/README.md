# Minis native task runtime

A complete task holds one native lease across separate shell calls. The worker sends authenticated heartbeats every five seconds; the server revokes UI after heartbeat loss or lease expiry. Native12/13 also stop lease-scoped F13; Native14 service-scoped pulses continue until service stop or lock/health pause. Normal tasks never open Settings, modify Auto-Lock, change Focus or launch a quiet shortcut. Native12 capability discovery is mandatory and old Runners are rejected. The retained legacy modules are for explicit recovery; existing Auto-Lock records block normal native tasks and are never deleted to bypass recovery.

Read [the skill](ictrl-ready/SKILL.md) for start/call/finish usage. TTL defaults to 240 seconds, maximum 300. The inherited 75-second cleanup reserve remains a conservative policy; it is not a measured device recovery guarantee. Task/request IDs prevent accidental resubmission after unknown outcomes. UI input is never replayed.

Install only after stopping active tasks. The installer checks the supplied ZIP hash, retains backups and does not read pairing credentials or start a task. This Native12 package is a candidate, not an installed or accepted phone runtime. Existing runtime and pending records must remain available until explicit migration.

XCTest explicit interruption handling addresses blocking alerts. It does not hide or mute every notification banner, and unknown alerts block subsequent input. F13 uses private XCTest APIs; CI compilation and offline policy tests do not establish physical idle-timer behavior. Minis stop-button integration, iSH scheduling, long background operation and device acceptance remain unverified.

Run `python3 -B -m unittest discover -s tests -v` here. CI runs real POSIX filesystem/lock tests on Ubuntu and macOS; phone operations remain fake.

Native14 additionally supports the explicitly discovered `f13_service`/`runner_service` lifecycle. Runner-service pulses persist across task End and heartbeat loss; UI remains strictly owner-lease scoped. Manual lock and unknown lock state pause service pulses, and old UI leases never revive. A service pulse is not proof of UI authorization.


## Native15 Minis completion candidate

New tasks require the trusted originating Minis session ID (canonical `minis://sessions/<id>`). Default completion returns to that precise chat and atomically ends the captured control lease and closes its Runner service. Explicit user stay/open-App intent skips the return, not End/stop. Codex continues using ordinary End and service keep-awake. This requires `minis_atomic_finish:1`; old Runner support is rejected before Begin.

`finish --wait 30` waits for a bounded terminal state without holding the task lock. `control_end_confirmed`, `return_route`, `chat_verified`, and `service_finish:closing` are separate evidence: dispatch does not prove the chat rendered, and accepted closing is not a physical stop observation. Unknown in-flight UI is never replayed or followed by return UI. A lost finish response is not retried, and the client never sends a separate global config stop after End.

Current candidate is local only, not deployed. Native stop-button cancellation, suspended/killed workers and physical device acceptance retain their explicit verification boundary. Historical tasks and audits are preserved.

Automatic origin uses two completed tool rounds: first prepare+ensure (random IDs persisted), then start resolves the prior successful prepare receipt through globally unique nonce matching. The current shell input is not assumed persisted while executing. `start --wait-ready 20` polls only local state, reducing avoidable model/tool round trips. See docs/minis-origin-context.md.

Native16 normal return requires authenticated `minis_handoff:1` before Begin. Its one-shot finish transport has a separate 15-second budget; the original lease bounds the server handoff to at most eight seconds. `app_confirmed` plus `foreground_confirmed:true` proves the target app was observed, not the exact chat UUID. Unknown alerts are blocked, not automatically approved. Terminal failures still clean up the captured lease/service when authority has not been superseded.
