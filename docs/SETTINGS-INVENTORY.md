# Bridge settings inventory (2026-10-06, Bridge 1.4.2)

Step 1 of the unified Settings window (ROADMAP "Next - planned 2026-10-05", item 1). Every setting
Bridge has today: where it lives, how it is opened, where it is stored. The window must reach all of
them and must not change how any of them works today.

Storage legend: **App** = this Mac (UserDefaults / Keychain), the same for every show. **Profile** =
saved in the `.airliveprofile` show file (Profiles menu, ⌘S / ⌘O).

## Global settings (same for every show)

| Setting | Where today | How it opens | Stored |
|---|---|---|---|
| Latency buffer (Unbuffered / Low 60 / Normal 120 / High 200 / Safe 400 ms) + lock | Channels rail, footer | always visible | Profile (one value applied to every channel), lock in App |
| Bridge password (set / change / remove) | Channels rail, footer | click → sheet | App (Keychain) |
| Enable shortcuts | Shortcuts window | menu Shortcuts → Customize Shortcuts… (⌘K) | App |
| Show key hints on buttons | Shortcuts window | ⌘K | App |
| Work in other apps (needs Input Monitoring) | Shortcuts window | ⌘K | App + macOS permission |
| Key bindings: switcher, lenses, channels | Shortcuts window | ⌘K | App |
| Allow Stream Deck control | Shortcuts window, STREAM DECK | ⌘K | App |
| Auto Cut range FROM / TO | gear next to AUTO | click → panel | App |
| Recordings folder (recorder hidden) | Outputs rail footer (hidden) | - | App |
| Check for Updates | app menu | Airlive Bridge → Check for Updates… | Sparkle |
| Remove Virtual Camera | app menu | Airlive Bridge → Remove Virtual Camera… | - |
| About | app menu | Airlive Bridge → About | - |

## Per channel (one camera / source)

| Setting | Where today | Stored |
|---|---|---|
| Name | channel row, inline rename | Profile |
| Additional delay (ms), Reset, ±10 | channel row → gear | Profile |
| Preview on / off | channel row | Profile |
| Capture device (HDMI / USB channels) | chosen when the channel is added | Profile |
| Shortcut key | Shortcuts window, CHANNELS | App |

## Per output (one program output)

| Setting | Where today | Stored |
|---|---|---|
| Label | output row, inline rename | Profile |
| SRT destination / NDI name / config | output row, inline field | Profile |
| RTSP port + copy URL | output row | Profile |
| HDMI display | output row, dropdown | Profile |
| On / off | output row | never saved (outputs come back OFF on purpose) |

## Not settings (stay where they are)

- Camera controls (ISO, shutter, WB, tint, focus, zoom, EV, lenses): live control of the phone, the
  camera panel. Not Bridge settings.
- Profiles (New / Save / Save As / Open): show files, menu Profiles.
- Full-Screen / Detach multiview: actions, top bar.

## Coming with the next steps

- Program and preview: frame guides (ratio, style; Preview + Program + fullscreen wall, never on air).
- Outputs → Virtual Camera: resolution 1080p / 4K (default 1080p).
- Recording: folder, format, button (after the OBS research).
