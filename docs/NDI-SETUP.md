# NDI® output — setup

Airlive Bridge can re-publish each channel's decoded video as an **NDI source**
on your local network, so any NDI receiver — OBS Studio (with the NDI plugin),
vMix, NDI Studio Monitor, Wirecast, TriCaster, etc. — can pick the camera up by
name.

## You do NOT need the NDI SDK to build the app

Airlive Bridge loads `libndi` **at runtime** with `dlopen`. There is **no
build-time link** against the NDI SDK and **no entry in `project.yml`** for it.

What this means:

- The app **builds and launches** on any Mac, with or without NDI installed.
- If the NDI runtime is **not** present, NDI outputs simply stay offline — you
  see a log line like
  `[NDIOutput] libndi not found. Install the free NDI Tools / NDI Runtime …`
  and the rest of the app (preview, recording, other outputs) works normally.
- The moment the runtime is installed, NDI outputs start working — no rebuild.

## Install the NDI runtime (free)

NDI is **not on Homebrew**. Get it from NDI directly:

1. Go to **https://ndi.video** → Tools / Download.
2. Install either:
   - **NDI Tools** (free) — includes the runtime plus Studio Monitor / Scan
     Converter / Test Patterns. Recommended; Studio Monitor is the easiest way
     to confirm Bridge's source is visible.
   - **NDI SDK for Apple** (free, requires a quick registration) — if you want
     the headers/libs in a known location. Not required for Bridge.

The free **NDI Runtime** alone is also sufficient if you only want to *send*.

## Where `libndi` lands, and where Bridge looks

Bridge searches these locations, in order, the first time an NDI output starts:

1. Environment overrides (if set):
   - `$NDI_RUNTIME_DIR_V6/libndi.dylib`
   - `$NDI_RUNTIME_DIR_V5/libndi.dylib`
   - `$NDI_RUNTIME_DIR/libndi.dylib`
2. Fixed locations:
   - `/usr/local/lib/libndi.dylib`, `/usr/local/lib/libndi.4.dylib`
   - `/opt/homebrew/lib/libndi.dylib`, `/opt/homebrew/lib/libndi.4.dylib`
   - `/Library/NDI SDK for Apple/lib/macOS/libndi_advanced.dylib`
   - `/Library/NDI SDK for Apple/lib/macOS/libndi.dylib`
3. Bare names resolved via the dynamic loader path
   (`libndi.4.dylib`, `libndi.dylib`).

The **NDI Tools** installer typically drops the runtime so it is reachable via
the loader path and/or `/usr/local/lib`. The **NDI SDK for Apple** installer
puts the libs under `/Library/NDI SDK for Apple/lib/macOS/`. Both are covered.

If your install put `libndi` somewhere unusual, point Bridge at it explicitly:

```bash
export NDI_RUNTIME_DIR_V6="/path/to/the/folder/containing/libndi.dylib"
open -a "Airlive Bridge"
```

(Set the variable in the environment the app launches from. The folder, not the
file — Bridge appends `/libndi.dylib`.)

## Verifying it works

1. Start an NDI output on a channel in Airlive Bridge.
2. Open **NDI Studio Monitor** (from NDI Tools) on the same network.
3. The source appears as **`<this Mac's name> (<the output's label>)`**.
   Renaming the output in Bridge renames the NDI source live.

If the source doesn't appear, check:

- The Bridge log for `Loaded NDI runtime from …` (runtime found) vs.
  `libndi not found` (runtime missing — install NDI Tools).
- Both machines are on the **same subnet**; NDI discovery uses mDNS/Bonjour.
  Some managed/guest Wi-Fi networks block it — use a wired LAN or an NDI
  Discovery Server if so.
- macOS Local Network permission is granted to Airlive Bridge
  (System Settings → Privacy & Security → Local Network).

## NDI® trademark & licensing note

**NDI® is a registered trademark of Vizrt NDI AB.** Airlive Bridge is **not
affiliated with, sponsored by, or endorsed by Vizrt/NDI.** "NDI" is used here
only to describe interoperability.

Airlive Bridge **does not bundle, redistribute, or build against** the NDI SDK
or runtime. You obtain and install the NDI runtime yourself from
https://ndi.video, under **NDI's own license terms** (the NDI SDK License
Agreement / NDI Tools EULA). Review and accept those terms when you install.
Using NDI in your productions is subject to NDI's branding and licensing
requirements — see https://ndi.video for the current terms.
