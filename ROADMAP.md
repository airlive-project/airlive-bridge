# Roadmap — Airlive Bridge (Mac MVP, no Virtual Camera)

Estimates are focused-build ranges. Big head start: the Studio app already has a
working receiver (Bonjour multi-slot + decode + jitter/playout + control) and
RTMP/SRT via HaishinKit — we port, not rewrite. NDI and RTSP are the new pieces.

| Phase | Deliverable | ~Time |
|------:|-------------|-------|
| 0 | Repo scaffold; port the receiver core (channels = Studio slots) into a standalone module | 2–3 d |
| 1 | Channels: create / rename / status, Bonjour advertise, connect; UI shell + **hide-preview** | ~1 wk |
| 2 | **NDI** output (frame convert + tally feedback → setCue) | ~3 d |
| 3 | **SRT + RTSP** outputs (remux H.264, no re-encode) | ~4 d |
| 4 | In-app remote control (controls → type-2; live readback) | ~3 d |
| 5 | Polish: settings persistence, reconnect ✅, packaging / signing / notarize ✅ (pipeline: scripts/package.sh + entitlements + make-icon.sh + docs/PACKAGING.md — needs your Developer ID cert, notary profile, logo PNG) | ~4 d |

**MVP total (no VCam): ~2–3 weeks.**

Fast-follow (post-MVP): Virtual Camera (macOS system extension, ~1–1.5 wk),
then Windows.

## v1 close criteria (decided 2026-06-23)

**v1 outputs:** NDI ✅ + OBS passthrough relay ✅ + **RTSP** ✅ + **SRT** ✅ — all
four built (RTSP/SRT remux the program's H.264, no transcode). RTSP/SRT still need
real-client validation (VLC/ffmpeg for RTSP; libsrt + an SRT receiver for SRT) — the
protocol wire can't be exercised from a build; folded into the soak/E2E pass.
**Distribution:** signed + **notarized** installer on the site (like OBS) — NOT the
Mac App Store (sandbox almost certainly rejects NDI/raw-socket/Bonjour; revisit only
if it turns out to pass). Same model as Studio (sold via airlive.studio).
**Reliability gate (THE close gate):** a soak test — **5 cameras streaming 3–4 h**
with no lag/dropout from our side — must pass before v1 is "done".

### Reliability hardening — 5-cam × 4-h (long-run audit 2026-06-23)

Static audit verdict: the per-frame hot path is sound (decode session reused across
keyframes, jitter ring bounded, **no per-frame @Published**, real per-channel
isolation, no retain cycles, balanced observers). Fixes landed from the audit:
- ✅ **C1 (crash):** drain async frames before invalidating the decode session on a
  mid-stream format change (`WaitForAsynchronousFrames`) — UAF that's 5× likelier
  with 5 cams.
- ✅ **M3 (main stall):** NDI `clock_video:false` — stop the SDK sleeping-to-pace on
  the main thread every frame (the jitter ring is the timing authority).
- ✅ **M1 / L1:** prune expired `authBans` (+ clear on password change); clear the
  tally entry on channel removal.
- ✅ Earlier: Bonjour-no-readvertise-while-connected (reconnect loop), program-tap
  data race, all-orientation preview render.

Deferred hardening — do alongside the soak test (profiling-gated, low risk after the
above keep main healthy):
- ✅ **H1 (DONE 2026-06-29)** — per-frame program taps gated on an `isProgramSource`
  flag (set by `routeProgram`, queue-confined): a NON-program channel now does ZERO
  per-frame `DispatchQueue.main.async` hops (at 5 cams ~4/5 of the old hops were no-ops
  finding a nil closure). `present()` restructured so the one-shot no-signal gate still
  flips exactly once per (re)connect. swift-reviewer caught + fixed a race (the Lowest-
  preset inline promote now hops to `queue` so the gate state stays confined).
- ✅ **H2 (DONE 2026-06-29)** — `channel.remote` coalesced to ~1 Hz in the receiver
  (leading-edge immediate, then ≤1/sec), so a phone sending state faster can't churn
  SwiftUI. Cleared on disconnect so a trailing flush can't resurrect stale state.
- ✅ **M2 (DONE 2026-06-29)** — `accept()` arms a candidate-ready timeout; a half-open
  dual-stack straggler that never reaches `.ready` is dropped from `pendingConnections`.
- **M4 (still deferred)** — honor `previewEnabled` in `present()` (skip `publishFrame`
  for hidden, non-program channels) — the documented thermal/no-op-post saving.
  Deferred: needs a queue-safe `previewEnabled` mirror + correct "is program" knowledge
  to avoid blanking a wanted tile, and overlaps the in-flight multiview-UI rework — do
  it with the soak test once the UI behaviour settles.

**Soak protocol (run with testers, 5 phones):** 3–4 h continuous · Instruments
Allocations + Leaks + Time Profiler (memory must stay FLAT, no per-reconnect VT
session growth) · pull one camera's Wi-Fi mid-show → it must rejoin cleanly without
touching the other 4 · add/reorder channels while others are live (must not drop
them) · all 4 orientations · NDI + OBS simultaneously, with and without password.

### Multi-camera scenario audit (2026-06-30) — 10 scenarios, 54 agents, 37 confirmed → deduped ~14

A workflow traced realistic scenarios (delivery-mode swap, program-source-lost, camera-swap,
combined two-receivers, all-disconnect, tally routing, threading, profile-on-the-fly,
add/remove/reorder live, AirPlay/combined program vs passthrough outputs); each finding was
adversarially re-verified.

✅ **WAVE 1 FIXED + swift-reviewer-clean (2026-06-30):**
- **CRITICAL** — AirPlay/combined program silently dead-aired OBS-relay/RTSP/SRT (they need raw
  H.264; AirPlay emits only decoded frames).  Now: `BridgeModel.programSupportsPassthrough`
  (false for airplay/combined/capture program) → yellow warning banner in OutputsRail;
  `AirliveRelayOutput.clearLastFormat()` so a reconnect can't replay stale SPS/PPS into a
  frameless relay; `requestKeyframeForProgram` gated on `producesRawH264 && videoActive`.
- **HIGH** — `AirPlayReceiver.extraDelaySec` data race → `stateLock`; AirPlay stale-frame closure
  resurrecting `isConnected` after `stop()` → `_stopped` guard + `[weak channel]` + nil callback
  before teardown; `CaptureDeviceReceiver.stop()` async→sync (device re-acquire after profile);
  combined-channel UI read `isConnected` (video) not the control side → `anyConnected` computed
  (rail status + delete-confirm, multiview dot/offline, no-signal) + lens-row on
  `remoteControlConnected`; dead-air cutting to a disconnected camera → `take()`/`programSelect`
  require `isConnected`; tally not re-asserted on reconnect (LED stayed dark) →
  `BridgeChannel.onConnectivityChanged` → `syncMultiviewTally(force:)`; `NDIOutput.send()` blocked
  main per frame → own `sendQueue` + drop-in-flight.
- **MEDIUM/LOW** — AirPlayReceiver missing H1 program-source gate (per-frame main hops) → gated;
  TallyStore not cleared on disconnect (stale border) → cleared on full disconnect;
  multiview→solo left stale auto-tally → `clearAllTally()`; `remoteFlushScheduled` not reset on
  disconnect (≈1 s blank panel on fast reconnect) → reset.

✅ **WAVE 2 — done 2026-06-30 (operator: "do all of wave 2"):**
- **#12 AirPlay mid-session disconnect now detected.** `AirPlayEngine.mm` got an `onConnectionLost`
  block (mirrors `onVideoFrame`): fired from `conn_reset` and from `conn_destroy` when
  `openConnections_` hits 0.  `AirPlayReceiver` clears the channel's video state (`isConnected`/
  `latestFrame`/blank mirror) + resets `_didFlipGate` so the next session re-flips — a phone that
  stops mirroring no longer shows "connected" forever.  For a combined channel the control side is
  untouched (only the video transport clears).
- **#6 NDI dead-signal on program drop.** When the ON-AIR source's VIDEO transport drops
  (`isConnected→false`), `BridgeModel` pushes ONE cached opaque-black 1080p BGRA frame to the
  buffer outputs (NDI) — receiver shows black instead of a frozen last frame (operator's chosen
  behaviour).  Keyed off `isConnected`, so a combined channel that loses AirPlay video still blacks.
- **#20 OBS relay sample-before-format.** `AirliveRelayOutput.awaitFormat()` (called from
  `routeProgram` on a real source change) drops `relaySample` until the new source's `relayFormat`
  arrives (the forced keyframe brings it) — no ~300 ms decode-against-stale-SPS/PPS gap.

⏸ **WAVE 2 — deliberately NOT done (risk > benefit this pass):**
- **#28 `AirPlayEngine.stop()` joins native threads on main** (brief UI hitch during profile load).
  Kept SYNCHRONOUS on purpose: an async teardown races the immediate rebuild's port bind
  (profile reload → port conflict) and the detached thread joins risk a use-after-free of the
  engine.  The hitch is brief + occasional; a safe off-main teardown needs a dedicated careful
  pass (free the port synchronously, join the threads on a thread that owns the engine's lifetime).
- LOW: `removeChannel` double `routeProgram`; multiview grid capacity formula diverges from
  `multiviewCapacity()` at 17+ channels.

## Open decisions

1. **UI / tech stack** — RESOLVED: SwiftUI + ported Studio Swift (shipped).

## Backlog (post-MVP)

- ✅ **AirPlay + control "killer combo" — DONE 2026-06-29 (v4 — ONE combined channel, two transports).**
  Final shape (operator's design): a THIRD "+" source type **"Screen Mirroring + Remote Control"**
  (`ChannelKind.screenMirroringPlusControl`) — ONE channel that runs BOTH receivers for the SAME
  phone: an AirPlay (UxPlay) receiver for VIDEO + a control-only ARLV receiver (`controlSide`) for
  CONTROL + tally.  The phone screen-mirrors to it (video) AND connects the Airlive app to it
  (control-only — the receiver sends `setDeliveryMode(.controlOnly)` on connect, so the phone gates
  its encoder → cool, one encode).  CAMERA SIDE IS IMPLEMENTED (verified in `CaptureEngine.swift`:
  `setDeliveryMode`→`setEncoderEnabled(false)`, `videoActive` reported, sticky across reconnects).
  One tile shows the AirPlay video; its CAMERA CONTROL panel + tally drive over the ARLV side. No
  binding/picker — it's self-contained.
  - Impl: `BridgeChannel` now holds two receivers — `receiver` (AirPlay video) + `controlReceiver`
    (ARLV control); `send` routes to the control side; `rename`/`updateAuth`/`updateOrder`/
    `setProgramSource` fan out to both; `controlConnected` (separate from video `isConnected`),
    `remoteControlConnected` computed (drives the panel's enabled state), `videoActive == true`
    (video is AirPlay's, not the control side's `videoActive=false`).  `BridgeChannelReceiver`
    gained a `controlSide` flag: sets `controlConnected`/`remote` only (never `isConnected`/
    `latestFrame`/`outputRotation` — those belong to the AirPlay side) and sends control-only on
    connect.  `CameraControlSection`/`ControlPanel` render the panel for any back-channel-owning
    channel.  Persisted via `kind` in the profile (no binding to store).
  - swift-reviewer passes: v3 HIGH (panel didn't observe its control channel — extracted
    `ControlPanel`) carried forward; v4 dual-receiver state separation done (controlSide guards).
  - **v1/v2/v3 superseded** (same day): v1 = "Video source" picker on the Airlive gear; v2 =
    "Remote control" dropdown on the AirPlay tile; v3 = a SEPARATE control-only "Remote Control"
    channel you bind to a Screen-Mirroring tile.  All reverted — operator wanted ONE channel that
    IS both (UxPlay + the app), "two birds one stone", no binding step.
  - Optional later: auto-match when the iPhone system name equals the operator name.

- ✅ **Profiles (save / load a whole setup) — DONE 2026-06-29.** Menu **Profiles → Save
  Profile… (⇧⌘S) / Open Profile… (⌘O)** serialise the configuration to a `.airliveprofile`
  JSON (`BridgeProfile`): channels (id, kind, name, order, capture-device id, delay +
  extra-delay ms, preview toggle) + program outputs (kind, label, config, RTSP port) +
  mode. `BridgeModel.snapshotProfile()` / `applyProfile(_:)` rebuild the layout — channel
  IDS ARE PRESERVED so a previously-paired phone reconnects to the same slot; outputs come
  back OFF (a restored output must not auto-publish). The PASSWORD is intentionally NOT in
  the file (Keychain-global → the file is safe to share). LIVE connections are not saved.
  Follow-ons (not done): a recent-profiles list and "reopen last on launch".

- ✅ **Per-source latency in milliseconds (manual multicam sync) — DONE 2026-06-29.**
  A precise **"Additional delay (ms)"** field (type the exact number + ±10 stepper + Reset,
  no consumer crutches) in each channel card's gear popover (`ChannelsRail`), bound to
  `BridgeChannel.extraDelayMs` → forwarded live via `ChannelReceiver.updateExtraDelay(_:)`.
  - ARLV: ADDED ON TOP of the existing `LatencyPreset` presets (kept as-is) — the receiver's
    effective playout depth is `basePresetSeconds + extraDelaySeconds`, re-anchored on change.
  - AirPlay: a NEW fixed-delay path (was "show ASAP") — frames held a constant offset on a
    side queue; **0 = the original immediate path, unchanged → zero risk default**.
  - HDMI/USB capture: no-op (local, no playout buffer).
  - Pure receiver-side, zero iPhone cost / no thermal impact, as designed.
  - **Auto-align stays deferred** (can't know absolute capture→Mac latency: phone/Mac clocks
    unsynced; AirPlay RTP/NTP is cross-protocol). Manual is the shipping design; optional
    later: an approximate "clap-sync".
  - Caveat: AirPlay's inherent ~150–250 ms mirror latency is a floor; the ms field adds ON
    TOP, it can't go below the floor.

- **Multiview Full-Screen / Detach (clean wall).** The multiview top bar has two
  buttons: Full-Screen (today: native window full-screen) and Detach (opens the
  multiview in its own window — already works). Roadmap piece: a CLEAN multiview-only
  full-screen that hides the rails + controls (just PVW/PGM + the thumbnail wall), and
  Detach polish (remember the window frame / place on a second screen).

- **Multiview + program routing (switcher-lite).** Show all channels in a
  multiview; choose what goes to air; route a *selected* camera to a *selected*
  output seamlessly — don't blindly publish every signal, pick which camera goes
  where and switch without glitches.
- **Control-panel / settings UX redesign.** Card-based quick-select, lens-first
  with ISO-compensation, clean sliders (no track artifacts), tidy segmented
  controls, tighter spacing, window auto-fit. (First UX pass — in progress.)

## Security (P1 — cross-cutting, needs the apps team)

**Threat model (deliberately narrow):** the LAN stream is NOT secret — anyone may
watch the video. The only real risk is a **prankster on the same network with the
same app** grabbing a channel slot or mixing a fake feed into someone's multiview.
This is an **access** problem, not a confidentiality one.

**P1 — receiver-password auth (challenge-response, HMAC).** "Like a WiFi password":
the receiver owns the password; the iPhone enters it once (cached in Keychain),
re-prompts only on first connect or after a password change; rotating the password
revokes everyone. **Off by default** (current open behaviour unchanged).
- Wire: receiver sends a one-shot `nonce`; camera replies `HMAC-SHA256(password, nonce)`;
  receiver verifies before accepting video. Password never crosses the wire; nonce is
  single-use (replay-proof). New optional packet types in AirliveCore (version byte
  keeps back-compat).
- Receiver adds: "Require password" toggle + field, anti-brute-force backoff, optional
  "disconnect connected cameras now" on change. We implement this side in Bridge + the
  OBS plugin once AirliveCore + camera ship the handshake.
- **Cost: one HMAC per connection — zero per-frame, zero thermal impact.**

**NOT doing — TLS / stream encryption.** The video isn't secret, so encrypting it
buys nothing for our threat model and costs thermal budget. We accept that a deep,
equipped attacker could sniff the plaintext feed; password auth filters the 99%
(pranksters / accidental cross-connects) that actually matter.

## Out of scope

Editing the camera / studio / AirliveCore apps. The wire protocol is frozen;
any change there is requested from the apps team, not made here.
