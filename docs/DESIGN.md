# UI design notes

Three-zone window (dark broadcast-tool aesthetic, Airlive red accent). A
clickable HTML mockup was reviewed and approved in chat; it will be committed
here when the UI phase starts.

## Layout

- **Left — Channels.** A `+ Create channel` list (NOT auto-discovered cameras).
  Each row: channel name (renameable), connection dot, mini spec, tally state.
  Creating a channel opens a receiver slot + Bonjour advert the iPhone connects to.
- **Center — Selected channel.** Preview (16:9) with tally border + ON AIR badge
  and a **hide-preview** toggle (stop rendering to save CPU/GPU; if only
  SRT/RTSP outputs are active, decoding can be skipped entirely via remux).
  Below: tally (Program/Preview/Off), camera control (AE/AWB/AF toggles grey out
  their manual sliders; ISO/shutter/WB/tint/focus/zoom; lens pills), delay preset.
- **Right — Publish to.** One card per output (NDI / SRT / RTSP) with an on/off
  switch, a **renameable output label** ("what it sends", e.g. NDI source name),
  config field, and a LIVE/OFF status pill.

## Approved feedback (from mockup review)

1. Channels are **created**, not pre-listed — the iPhone connects to a slot you make.
2. Each output's **label is renameable** to say what it sends.
3. A **hide-preview** control to avoid loading the system with video it doesn't need.
