# Airlive Bridge

Receive the **Airlive Camera** (iPhone) stream on a Mac and re-publish it to any
production tool — **NDI / SRT / RTSP** — with **remote camera control built in**.

It's the piece between the OBS plugin (one host) and the Studio app (a finished
switcher): a thin, universal bridge that turns one iPhone feed into a standard
output every tool understands.

## Why

Downstream protocols (NDI/SRT/RTSP) are **one-way video out** — they can't send
control back to the iPhone. So remote control (ISO/WB/lens/tally…) lives **in
this app**. One bridge → works in vMix, ProPresenter, Wirecast, OBS, Resolume,
TouchDesigner, etc.

## Model

- You **create channels** (receiver slots) — not a list of pre-found cameras.
  Each channel advertises Bonjour `_airlive._tcp`; the iPhone connects to the
  one you pick.
- Per channel: a live preview with a **hide-preview** toggle (don't render video
  you don't need — saves CPU/GPU), camera control, and one or more **outputs**
  (NDI/SRT/RTSP) with a **renameable output label** ("what it sends").

## MVP scope

- ✅ Outputs: **NDI, SRT, RTSP**
- ✅ In-app remote control (type-2: ISO / shutter / WB / tint / lens / zoom /
  focus / fps / LUT / tally) + live `StateSnapshot` readback
- ✅ Fixed-delay presets (Unbuffered / Normal / Smooth / Safe), hide-preview
- ⏭ Virtual Camera — fast-follow, **not in MVP**
- ⏭ Windows (the vMix world) — later; NDI/SRT carry over, VCam differs

## Protocol (fixed — defined elsewhere)

ARLV over TCP (18-byte header, H.264 AVCC) + Bonjour `_airlive._tcp` + type-2
JSON control. **Frozen**, owned by the `airlive` repo. This repo adapts to it;
it never changes it.

## Reuse

Ports (copies) proven Swift from the Studio app for the Mac MVP:
`CamSlotReceiver` (receiver + Bonjour multi-slot + decode + jitter/playout +
control), `OutputSettings` (LatencyPreset), HaishinKit (RTMP/SRT). New work:
**NDI** (NDI SDK) and **RTSP** (small muxer/server).

## Boundaries

Standalone repo. The `airlive` camera / studio / AirliveCore code is **never
edited from here** — protocol or app-side changes are handed to the apps team to
avoid conflicts. Studio is read for reference / porting only.
