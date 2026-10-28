# Minis Native12 task runtime

A complete task holds one native lease across separate shell calls. The worker sends authenticated heartbeats every five seconds; the server stops F13 after heartbeat loss or lease expiry. Normal tasks never open Settings, modify Auto-Lock, change Focus or launch a quiet shortcut. Native12 capability discovery is mandatory and old Runners are rejected. The retained legacy modules are for explicit recovery; existing Auto-Lock records block normal native tasks and are never deleted to bypass recovery.

Read [the skill](ictrl-ready/SKILL.md) for start/call/finish usage. TTL defaults to 240 seconds, maximum 300. The inherited 75-second cleanup reserve remains a conservative policy; it is not a measured device recovery guarantee. Task/request IDs prevent accidental resubmission after unknown outcomes. UI input is never replayed.

Install only after stopping active tasks. The installer checks the supplied ZIP hash, retains backups and does not read pairing credentials or start a task. This Native12 package is a candidate, not an installed or accepted phone runtime. Existing runtime and pending records must remain available until explicit migration.

XCTest explicit interruption handling addresses blocking alerts. It does not hide or mute every notification banner, and unknown alerts block subsequent input. F13 uses private XCTest APIs; CI compilation and offline policy tests do not establish physical idle-timer behavior. Minis stop-button integration, iSH scheduling, long background operation and device acceptance remain unverified.

Run `python3 -B -m unittest discover -s tests -v` here. CI runs real POSIX filesystem/lock tests on Ubuntu and macOS; phone operations remain fake.
