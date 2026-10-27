# Minis task-scoped iCTRL runtime

A Minis UI task holds one bounded Quiet lease and Auto-Lock context across separate shell calls. Independent read-only batches do not start Shortcuts. The old short-lived UI batch entry is rejected before sending any RPC.

Read [the skill](ictrl-ready/SKILL.md) for start/call/finish usage. Install only after stopping active Minis tasks. The installer verifies the supplied ZIP SHA-256, keeps a backup, and never reads pairing credentials or starts a task.

Validation: 24 offline tests passed under Ubuntu, including real POSIX locking and seven separate calls sharing one context. Phone acceptance of the new worker is still pending. A separate native6 Windows managed preflight verified one 300-second lease, a 10-second body hold and confirmed Quiet cleanup; it does not validate the Minis worker.

Current limits: the 300-second lease includes preparation; 75 seconds is reserved for cleanup but has not been measured on the phone. Minis stop-button integration and iSH background scheduling are not yet verified. Pending/unknown outcomes never authorize a replacement task or an automatic UI retry.

Run offline tests with `python3 -m unittest discover -s tests -v` from this directory. No test contacts a phone or reads credentials.
