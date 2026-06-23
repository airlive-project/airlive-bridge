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
| 5 | Polish: settings persistence, reconnect, packaging / signing / notarize | ~4 d |

**MVP total (no VCam): ~2–3 weeks.**

Fast-follow (post-MVP): Virtual Camera (macOS system extension, ~1–1.5 wk),
then Windows.

## v1 close criteria (decided 2026-06-23)

**v1 outputs:** NDI ✅ + OBS passthrough relay ✅ + **SRT + RTSP** (to build).
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
