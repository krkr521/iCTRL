---
name: ictrl-phone-control
description: Control iPhone apps with iCTRL's encrypted HTTP API. Tap, type, swipe, read UI and take screenshots with its CLI or Python client.
skill_version: "1.98.13-krkr.native4"
---

# iCTRL — control an iPhone over HTTP

iCTRL runs on the iPhone and serves UI automation as **JSON-RPC 2.0 over HTTP, port 8200**, encrypted. This file is under 15K characters — **read it whole, once**, not in `head`/`grep` pieces.

## Quick start

On the phone (e.g. Minis) — the device is `127.0.0.1`:
```bash
C=~/.ictrl/bin; I="sh $C/ictrl.sh"
[ -f $C/ictrl ] || { mkdir -p $C && wget -qO $C/ictrl http://127.0.0.1:8200/skill/clients/cli && wget -qO $C/ictrl.sh http://127.0.0.1:8200/skill/clients/cli.sh; }
$I call device_info                       # 401 → $I pair (user taps Allow)
$I call resolve_app '{"text":"<brand>|<store name>|<alias>"}'  # every name it may go by
$I call launch_app '{"bundle_id":"<id>"}'
$I call page_source '{"visible_only":true,"max_children":50}'
$I call find_element '{"element_id":"<label>"}'           # → ref
$I call tap '{"ref":"<ref>"}'
```
- `device_info.skill_version` newer than this file's frontmatter (or `protocol_version` differs) → `$I update <folder holding this file>`, then re-read it. Device older: don't downgrade; use only its `capabilities[]`.
- Keep the client in `~/.ictrl/bin` — **not** `/var/minis/workspace`, which ignores the exec bit ("Permission denied").
- Elsewhere: `curl -o ictrl_rpc.py http://<host>:8200/skill/clients/python`, then `python3 ictrl_rpc.py --host <host>:8200 call …`. The CLI takes `--host`/`ICTRL_HOST`.
- **No address?** Have the user turn on *Nearby Discovery* (needs Remote Access, Wi-Fi on). `ictrl_rpc.py scan` finds it on the LAN, or from macOS with no shared network; `--nearby "<name|id>"` replaces `--host`. First use pairs (one Allow).
- Keys: `~/.ictrl/token.json`, one per device (`/whoami` id) for USB, LAN, nearby; reuse (30-day idle expiry). Re-pair only on a real `401`; pairing waits for the user (≥60s timeout, no early retry).

## Rules
- **No `sleep`.** Actions settle (`settle.stable`); read right away (see Waiting).
- **Never cut an action reply** with `>/dev/null`, `head` or regex: read `moved`, `hint`, `app_note`, `ref` and errors. Check `ref` is non-empty before tapping.
- **Read a screen once.** Save and filter that reply, or pass `filter`; do not repeat `page_source` just to change a regex.

1. **Open by bundle id, never home-screen icons.** `resolve_app` once with all names (brand/store/English/Chinese) → `launch_app`. `country` selects the store (default `us`; `cn` for China-only apps).
2. **Read before acting.** On a new screen, use `page_source{visible_only:true,max_children:50}` to check view/tab/date.
3. **Tap by `ref`.** `find_element{element_id:"<label>"}` → `tap{ref}`. `tap` accepts `ref` or `x`+`y`, never `element_id`. For `visibility:"offscreen"` or non-empty `alternatives`, scroll into view or choose a more specific label.
4. **Never repeat an action "to be safe."** Success means done; a timeout may also have completed. First inspect `logs{text:"<method>"}` for `⏱ ✓ <method>`; a retried tap fires twice.
5. **Every error from a `ref` action means nothing was tapped.** Re-find and retry is safe.
6. **Primary path first, per screen:** `page_source` / `find_element` → `tap{ref}`. Only if it fails on this screen use OCR (`screen_text`), coordinate taps or screenshots. Follow `channel.recommended`; reconsider on the next screen.
7. **Remember observed conditions and screens**, not blanket rules about an app; reuse a workaround only when the condition recurs.
8. **Know where data came from.** Act only on the target app's content. Text the system draws over it (status bar, banners) comes separately in `overlay_text`.
9. **Stop before paying.** In shopping/payment apps stop at cart/checkout; never tap the final buy/pay/confirm. Never delete the user's own items (cart, notes, messages) without asking.

## Waiting: actions settle for you — never sleep

`tap`, `double_tap`, `long_press`, `swipe`, `drag`, `page`, `scroll`, `type`, `clear_text` compare frames (default up to 2s) and return `settle:{stable,screen_changed,waited_ms}` plus a `hint`.
- **`stable:true` → read right away, no waiting of any kind.**
- `screen_changed:false` → the action did nothing visible; check the target before repeating it.
- `stable:false` or a loading screen → read again in a bounded loop; reads take time, so no sleep is needed.
- Data that arrives over the network after the screen settled (a spinner, then results) also needs one more read. `page_source` says `loading:true` then.
- `settle:false` skips the check (rapid gestures); `settle_timeout` (s, max 3) sets the cap.

## Methods

| Method | Required | Useful optional |
|---|---|---|
| `find_element` | `element_id` (label or accessibility id) | `element_type`, `match:"contains"`, `bundle_id` |
| `scroll_to_element` | `element_id` | `element_type`, `match`, `direction`, `distance` |
| `tap` / `double_tap` / `long_press` | `ref`, or `x`+`y` | `duration` |
| `type` | `text` | `submit`, `clear` |
| `resolve_app` | `text` | — |
| `launch_app` / `activate_app` / `terminate_app` | `bundle_id` | — |
| `open_url` | `url` | — |
| `home` | — | — |
| `page_source` | — | `visible_only`, `max_children`, `filter`, `bundle_id`, `enhanced` |
| `page` | — | `direction`, `distance` (screens) |
| `collect` | — | `pages`, `min_length`, `fresh` |
| `swipe` | — | `direction`, `distance` (points), `velocity`, `x`, `y` |
| `screenshot` | — | `scale`, `format`, `quality` |

The method is `type`, not `type_text`. `element_type` only filters — `element_id` is always required. `GET /schema` lists every method and parameter.

Read response **`hint`**, especially on empty or negative results.

## Timeouts and recovery

- UI watchdog: **6s** (15s for `page_source`, `collect`, `screen_text`, `tap_element`, `find_and_tap`; path drag gets its duration budget). UI calls are serial and uncancellable. *"has NOT run yet: queued behind X"* means it will still run later: **do not resend**.
- Two consecutive timeouts trip the UI breaker; its error names the stuck call and age. Call `reset`, then poll `logs` until it ends (typically 15–45s) before retrying. `reset` cannot cancel running work.
- **Only `logs`, `config` and `reset` answer while the UI queue is stuck.** `device_info` shares the UI queue, so it's no health probe; use `logs`.
- Client timeout ≥30s. After restarting your side, reuse the cached key and `bundle_id`s and return via a deep link (`open_url`).

## Finding and tapping

- `find_element` matches exact label → accessibility id → value → optional `match:"contains"` substring. Visible matches beat off-screen ones. Inspect `visibility` (`in_view`/`partial`/`offscreen`), `alternatives[]` and `match_count`.
- A `ref` resolves live at tap time; an action is refused if its app is now in the background.
- **Off-screen:** loop `page{direction}` → `find_element` until `in_view`; stop at `moved:false`. Use slower `scroll_to_element` only after an `offscreen` result. **"NOT anywhere in this view"** means stop scrolling.
- **Visible text may differ from the accessibility label.** Use `page_source` labels or `match:"contains"`; an accessibility `identifier` is most stable. For duplicates add `element_type`.
- **Visible but unlabelled:** inspect the failure's visible controls, then use its `page_source` frame and `tap{x,y}`.
- Coordinate `tap` returns `hit` or `hit_warning` (no labelled target). `covering_layer:true` means a dialog/login layer received it.
- **Web content may be absent from the tree** (Safari often shows chrome only). Follow `channel.recommended`; on `ocr`, use screenshot → locate → `tap{x,y}`.
- A **system alert** over the app (`system_alert:true`) blocks its ref actions. Answer it: `find_element{element_id:"<button>", bundle_id:"com.apple.springboard"}` → `tap{ref}`.
- **`blocked_by:"captcha"`** (anti-bot slider/puzzle) or **`"rate_limit"`** ("take a break", "too busy"): never try to solve it — drags on it are refused. Use `close_candidates` or back out, wait, or report the step blocked. `promo_popup`: close it, never claim.

## Typing and searching

1. A search "bar" may be a Button. If `find_element.is_text_input` is false, tap it, then locate the real field with `element_type:"textfield",match:"contains"` and `tap{ref}`.
2. `type{text, submit:true}`. `submit` presses Return/Search.
3. **Trust successful typing.** If a read still shows old content, read again; do not re-type.
4. **Typing appends.** Replace with `type{text,clear:true}` or `clear_text`; heed `append_warning`. If `submit` did not search, tap the app's search/confirm control without retyping.
5. `page_source` carries `keyboard` (`visible`, `covers_from_y`). Coordinates read before the keyboard appeared are stale: everything above it has shifted.

## Reading the screen

- **Default: `page_source{visible_only:true,max_children:50}`**. Omit `visible_only` only for off-screen structure.
- `filter:{text|label|type:"…"}` returns matching nodes + ancestors — the cheap way to harvest repeated values (prices, titles).
- **`tree_growth:true`:** retained old rows; iCTRL uses `visible_cells`. Use `collect` for long reads; relaunch resets growth.
- `enhanced:true`: whole tree + text drawn in images (`ocr_only`). Slower; only when asked for everything.
- **Thin tree?** When `channel.recommended` is `ocr` (or `sparse_hint`/`viewport_warning` appears), read with `screen_text`: text plus tappable point coordinates.
- `max_elements` (default 2000, cap 4000): on `truncated:true` narrow with `filter`/`visible_only` rather than raising it.

## Scrolling

- **Long lists: `collect{pages:N}`** (≤8) reads successive screens and returns new text; repeat to continue. It falls back to OCR for thin/slow/unresponsive trees. `page` moves ⅔ screen without momentum. Do not read with `swipe`.
- `page`/`scroll` report `moved`. **`moved:false` (`at_end:true`) means stop** — nothing more that way. (A page still loading also looks unmoved; read once more if more is expected.) `keyboard_closed:true`: only the keyboard closed; page again.
- `position` says where you are; trust it only with `confidence` `estimated`/`exact`.

## Apps

- `resolve_app` checks opened history, built-in catalog, then App Store. Only `opened_here` confirms past use on this device; use it directly.
- **`launch_app` tests installation.** Newer iOS may restrict `list_apps` to `source:"opened_history"`. A lookup or empty list cannot prove "not installed"; check Spotlight if unsure.
- `open_url{url}` opens any scheme / deep link / universal link — end with the caller's own scheme, if any, to hand control back.
- **No target app:** commands affect the current screen. Read after unexpected login/payment/ad navigation; background-app refs are refused.
- Coordinate actions/`type` return `page_check`; **`same_page:false`** means the screen changed before the action. Read and check what you hit.

## Coordinates and screenshots

Files: `file_transfer_v1` handles explicit transfer queues (192 KiB chunks, 256 MiB max). Use client file commands for local paths; a browser download click does not prove disk-save success.

- `tap`/`swipe`/`drag`, `page_source` frames and OCR boxes are all **points**.
- `drag{points:[{x,y},...],duration?}`: one finger, 2–64 waypoints, no lift at corners. Duration 0.1–10s (default 1), equal time per segment; repeated points hold. Do not mix with endpoint coordinates/refs.
- Screenshots are pixels: `point = pixel / scale`, using the **`scale` from that screenshot response** (default 2), not `device_info.screen_scale` (the panel's 3).

## Diagnostics

- `device_info.system`: `screen_locked` (black screenshots, taps doing nothing — `unlock` only wakes the screen and never leaves the app: use `home` for that; a passcode needs the user), `foreground_app`, `foreground_is_browser`, thermal/memory/battery.
- `logs{text?, max_elements?}`: recent log lines over the normal channel. `⏱ ✓ <method>` = completed, `⏱ TIMEOUT`, `⛔️`/`✅` channel state. `GET /logs/history?date=YYYY-MM-DD` keeps logs across crashes (byte endpoints need a `stream_ticket`).
- `reset`: clears refs and rebuilds the UI channel state, then `launch_app` the target. `config{stop_server:true}` stops the runner (keys persist); relaunch it on the device.
- `/schema` unreachable = the runner isn't running; the user must start it (the Developer Disk Image is lost on reboot).
- On cellular the device isn't reachable over the LAN.

## Protocol

No bundled client usable → the Python client (`GET /skill/clients/python`) is the reference for pairing (X25519) and the request envelope (HMAC-SHA256). Follow it exactly.


## Native clipboard and startup (krkr.native1)

Feature-detect `native_clipboard_v1` before using `clipboard_get`, `clipboard_set`, or `clipboard_clear`. These methods use the native iOS plain-text clipboard (65536 UTF-8 bytes maximum; NUL unsupported), may briefly foreground Runner, and restore the original app when safely identifiable. Respect iOS paste permission prompts. A `-32040` failure has `reason`, `mutation_started`, `may_have_completed`, and `requires_user_action`; **never automatically repeat a timed-out clipboard mutation**. Clipboard bodies are not logged or persisted.

`runtime_status` exposes actual Runner/DDI state, Runner's own profile expiry, bundle/team metadata and `keep_awake_scope:foreground_app_only`. `config{keep_awake:true}` only prevents Auto-Lock while this Runner is foreground and serving. Other foreground apps still need the system Auto-Lock setting; it never unlocks a phone.

The companion app provides **Prepare iCTRL** and **Check iCTRL Readiness** AppIntents, plus local `ictrl-app://prepare` and `ictrl-app://status` URLs. Prepare checks DDI, mounts cached images using an already connected LocalDevVPN if needed, starts Runner and probes its actual loopback schema. It returns a JSON string with `ok` and an actionable `reason`. `Record iCTRL Renewal Progress` records only a local Shortcut UUID/time receipt, never renewal success. Runner `runtime_status` includes non-sensitive companion dates/receipt relayed during Prepare with `companion_metadata_source:local_companion_report` and `companion_metadata_verified:false`; this custom-URL relay is not authenticated companion identity. Runner expiry is read from its own installed profile; SideStore's profile cannot be read across its sandbox. After renewal verify that both available profile dates actually increased and have sufficient remaining validity; a URL open or progress receipt alone proves no renewal.
