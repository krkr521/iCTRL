# Native12 Windows candidate overlay

These reviewed source files are an overlay for an existing paired Windows-Control installation. They contain no pairing store or connection configuration. Do not run this folder as an independent installation: its existing transport dependencies remain in the installed runtime.

Back up the existing matching files before applying this overlay. Keep the previous runtime usable while the phone still runs an older Runner. Normal tasks now require authenticated Native12 capabilities; they never silently fall back to Focus or Settings transactions. `phone_task.py end` retains the existing legacy recovery route. Existing Auto-Lock state is preserved; normal native tasks refuse to proceed while a legacy record exists.

The session sends a heartbeat every five seconds, validates the lease before each input and sends End once. Unknown responses and input timeouts are never replayed. Server expiry is the fallback after process termination; it is not a guarantee of immediate cleanup. Notification banners may remain visible; XCTest interruption handling does not mute notifications.

This candidate has not been installed or accepted on a physical phone. Offline tests and CI compilation are reported separately.
