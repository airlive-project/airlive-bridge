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

## Open decisions (resolve at kickoff)

1. **UI / tech stack** — SwiftUI + ported Studio Swift (fastest, Mac-only) vs
   HTML-in-Tauri (reuses the mockup 1:1, cross-platform).
2. **Output order** — proposed NDI → SRT/RTSP, since NDI alone unlocks
   vMix / ProPresenter / Wirecast.

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
