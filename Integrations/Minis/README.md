# Minis task-scoped iCTRL runtime

A Minis UI task holds one bounded Quiet lease and Auto-Lock context across separate shell calls. Independent read-only batches do not start Shortcuts. The old short-lived UI batch entry is rejected before sending any RPC.

Read [the skill](ictrl-ready/SKILL.md) for start/call/finish usage. `start --ttl-seconds` defaults to 240 seconds and validates 1–300; values at or below 75 are refused before Begin because no preparation/body budget remains. Existing records without a TTL are interpreted as 300, and a task ID cannot be reused with a different TTL.

Auto-Lock preparation and task commands share the deadline 75 seconds before lease expiry. If a status read consumes the remaining preparation budget, no subsequent UI command is sent. Auto-Lock restoration and Quiet End/status use the separate existing cleanup budget. Failed preparation remains conservative and does not start a second settings transaction.

Install only after stopping active Minis tasks. The installer verifies the supplied ZIP SHA-256, keeps a backup, and never reads pairing credentials or starts a task. This TTL240 package is a reviewed candidate and has not been installed or accepted on a phone. The earlier installed package has SHA-256 `8d89d91babba26a3cc421ad821e58a1c668af5f9a1056afddee368ac62531e25`; the current package hash is recorded in [manifest.json](manifest.json).

Windows validation: 29 tests discovered, 26 passed and 3 POSIX-only tests skipped. The native workflow runs the same suite under both Ubuntu and macOS with real POSIX locks and records its results in test-evidence artifacts. Those tests use fake phone operations and prove no live phone behavior.

Current limits: the native lease remains at most 300 seconds and includes preparation. A 75-second cleanup reserve is a policy boundary, not a measured phone recovery guarantee. Minis stop-button integration and iSH background scheduling remain unverified. Pending/unknown outcomes never authorize a replacement task, an automatic UI retry, or a new Begin. One successful 240-second preflight does not identify the previous callback failure's root cause.

Run offline tests with `python3 -B -m unittest discover -s tests -v` from this directory. No test contacts a phone or reads credentials.
