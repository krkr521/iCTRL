# Quiet-session experiment

This isolated prototype is not connected to the iCTRL Runner and does not enable notification suppression. It models a bounded, explicit automation lease and a report from user-configured system Shortcuts. The current application still has no automatic Focus session.

Run `swift test --package-path Experiments/QuietSession` and `python3 -m unittest discover -s Experiments/QuietSession -p test_*.py`. A successful test is not phone validation. Read PROTOCOL.md and INTEGRATION.md for the pending server, Shortcuts and UI work, global Focus limits and unresolved in-flight/ABA boundaries.
