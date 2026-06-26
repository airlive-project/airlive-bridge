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
- **H1** — queue-confine the program sample/format taps so the relay path has zero
  per-frame `DispatchQueue.main.async` hops (only matters if main ever stalls).
- **H2** — coalesce `channel.remote` to ~1 Hz in the receiver (don't trust the
  phone's throttle; protects main if a phone sends state faster).
- **M2** — arm a "candidate never readied" timeout in `accept()` to drop stranded
  dual-stack stragglers.
- **M4** — honor `previewEnabled` in `present()` (skip `publishFrame` for hidden,
  non-program channels) — delivers the documented thermal/no-op-post saving.

**Soak protocol (run with testers, 5 phones):** 3–4 h continuous · Instruments
Allocations + Leaks + Time Profiler (memory must stay FLAT, no per-reconnect VT
session growth) · pull one camera's Wi-Fi mid-show → it must rejoin cleanly without
touching the other 4 · add/reorder channels while others are live (must not drop
them) · all 4 orientations · NDI + OBS simultaneously, with and without password.

## Open decisions

1. **UI / tech stack** — RESOLVED: SwiftUI + ported Studio Swift (shipped).

## Backlog (post-MVP)

- **AirPlay ↔ control manual bind (delivery-mode "killer combo").** Delivery mode is
  SHIPPED (Video+Control / Control-only toggle, videoActive-keyed "CONTROL ONLY"
  placeholder, operator gates, deviceName label — see docs/DELIVERY-MODE-DESIGN.md). What
  remains is the convenience that MERGES two transports into one tile: when an Airlive
  channel is Control-only (`videoActive==false`) AND the operator has manually bound it to
  an AirPlay (Screen Mirroring) tile from the same phone, composite the AirPlay video into
  that channel's tile instead of the "CONTROL ONLY" placeholder — so one tile shows AirPlay
  video + Airlive control/tally (one encode on the phone, full control). Bind is MANUAL
  (operator taps "this AirPlay tile = this control link"; deviceName makes it obvious;
  optional auto-match if the iPhone system name equals the operator name). Needs a
  `linkedControlChannelID` on the AirPlay channel + a bind affordance in ChannelsRail + the
  tile/program routing to pull the linked AirPlay video. Until then the combo still works as
  TWO separate tiles. (David to send UI mockup, like the latency feature.)

- **Profiles (save / load a whole setup).** A "Profiles" menu (already stubbed in the menu
  bar: New Profile… / Open Profile…) that serialises the entire configuration — channels
  (kind, name, order, capture-device id), program outputs (kind, label, config, order) and
  the password flag — to a `.airliveprofile` JSON file via NSSavePanel, restored via
  NSOpenPanel (clear + re-add channels/outputs from the snapshot). Needs `BridgeModel`
  snapshot/apply methods + Codable config structs (live channels/receivers are rebuilt on
  load, not the connections). Wire the two existing (disabled) menu items to it. Nice
  follow-ons: a recent-profiles list and "reopen last on launch".

- **Per-source latency in milliseconds (manual multicam sync).** A precise numeric
  latency field (in ms) on EVERY source, set by the operator. This is a PROFESSIONAL
  tool — expose the exact number, not consumer crutches (no "±1 frame" nudges, no vague
  presets). The Mac can only ADD delay (buffer decoded frames), never reduce below a
  source's own floor — so you sync by raising every fast source UP to the slowest. Example:
  AirPlay arrives ~120 ms, the Airlive app ~230 ms → dial AirPlay +110 so both play out at
  230 ms, in sync. Pure receiver-side (extra decoded frames held in a per-channel ring):
  ZERO iPhone cost, no thermal impact.
  - Mechanism: the ARLV channel already has a playout buffer + an Output-delay row
    (`LatencyPreset`). Two pieces to build: (1) **KEEP the existing ARLV presets as-is** and
    ADD a separate manual **ms field** ALONGSIDE them — it's an *additional* fine offset, not
    a replacement (presets stay for quick coarse choice; the ms field is the precise extra);
    (2) extend the SAME deadline-ring playout to AirPlay channels (today "show ASAP", no
    buffer) so AirPlay can be delayed too. Additive, isolated, low risk (worst case = extra
    latency, not a crash).
  - **Auto-align is NOT exact and is deferred.** We can't know absolute capture→Mac latency
    (phone and Mac clocks aren't synced — the skew is baked into `timestamp_us`; AirPlay's
    RTP/NTP is cross-protocol). True auto needs either an event calibration (clap/flash
    detected in every feed) or NTP-stamped capture time from the app (frozen wire / app
    team). So manual is the shipping design; optional later: a "clap-sync" that's only
    approximate.
  - **UI: David will send a mockup** — implement the placement/layout from that, don't
    invent it. (The ms field sits next to, not instead of, the ARLV preset row.)
  - Caveat: AirPlay's inherent ~150–250 ms mirror latency is a floor; the ms field adds
    ON TOP, it can't go below the floor.

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
