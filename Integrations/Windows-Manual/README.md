# Manual browser recovery panel

This module is the manual-control panel used by the Windows remote-page
integration. It is a browser script, not a pairing store or a complete bridge.
The integration provides the existing authenticated `rpc`, DOM document,
`supportsQuiet`, input targets, and pointer-cancellation callbacks to
`window.IctrlQuietManualCompat.create`.

Native9 owner status supplies advisory recovery availability. During the
existing protection window the panel displays the relative wait and does not
send an inspection. After eligibility changes, the user must explicitly click;
the panel refreshes owner status before sending once. An unknown sent result
stays latched across reconnects. Only a confirmed unblocked manual-ready state
retires that attempt for a later lease. Reconnecting invalidates an old read
preflight; it never resends an inspection or phone input.

Older Runner responses without availability fields retain the previous manual
inspection behavior. Server authorization remains mandatory in every case.
No timer automatically starts Focus, takes over, or retries a phone action.

To update an existing Windows integration, replace its matching
`web/quiet-manual-compat.js`, then reload its already-paired remote page. This
does not require replacing a pairing key or restarting the SSH bridge.

Offline checks (no network, credentials or device):

```text
node Integrations/Windows-Manual/test_quiet_manual.js
node Integrations/Windows-Manual/test_inspection_wait.js
```
