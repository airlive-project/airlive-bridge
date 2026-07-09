# Handoff: port Airlive's AirPlay fixes + UI cleanup into the obs-airplay fork

For the chat that owns the **obs-airplay screen-mirroring fork** (mika314-derived OBS
plugin). This is a self-contained spec — you don't need the Airlive Bridge chat.

Reference implementation lives in **airlive-bridge** (our Mac app's AirPlay receiver,
same UxPlay stack mika uses):
- `Sources/AirPlay/bounded_queue.hpp`
- `Sources/AirPlay/AirPlayEngine.mm`
- `Vendor/UxPlay/lib/dnssdint.h`, `Vendor/UxPlay/lib/raop_handlers.h`
- the live rotation/audio patches are applied at build time by
  `scripts/build-airplay-lib.sh` (staged-copy patch — the submodule stays pristine)

---

## Fix 1 — the "growing latency" / smeared-picture fix (mika #265)

**Symptom in stock mika:** decode is coupled to the network read, so a slow decoder
back-pressures TCP → latency grows over a session; and any dropped **compressed**
frame smears/greens the picture until the next IDR.

**Fix (two parts):**

**(a) Decouple decode from the network thread** with a bounded queue between them.
The network callback only enqueues; a dedicated decoder thread pops + decodes.

**(b) H.264-aware overflow policy — NEVER drop a compressed frame from the middle
of the stream.** Dropping one P-frame breaks the reference chain → garbage until the
next IDR. So on overflow, purge the WHOLE queue in ONE critical section, and keep the
incoming item only if it is itself a sync point (SPS/IDR). Otherwise go "blind" (skip
every non-sync packet) until the next SPS/IDR restarts the chain — a brief freeze
instead of seconds of smear.

Queue depth **32** (not 2–3): Wi-Fi hands several NALUs at once; a shallow queue
overflows on every burst even with a fast HW decoder, and drop-oldest then eats
P-frames. Depth adds no steady-state latency (HW decode outruns 30 fps; the queue
idles near-empty).

`BoundedQueue::pushOrPurge(item, itemIsSync) -> {dropped, purgedNonSync}` — single lock:
```
room available        → plain push
overflow + sync item  → purge all, push the sync (chain restarts cleanly, 0 garbage)
overflow + non-sync   → purge all INCLUDING the item, report purgedNonSync
```
In `video_process`, decide sync per packet and drive a `needIdr_` atomic:
```cpp
const bool sync = containsSyncNalu(data->data, data->data_len);
if (needIdr_.load()) { if (!sync) return; needIdr_.store(false); }   // blind until a sync point
auto r = videoQueue_.pushOrPurge(std::move(pkt), sync);
if (r.purgedNonSync) needIdr_.store(true);                            // overflow, went blind
```

`containsSyncNalu` scans Annex-B start codes (both 3- and 4-byte) and returns true on
NAL type 5 (IDR) or 7 (SPS). **Watch the bounds** — a one-byte-too-strict guard makes
the minimal IDR `{00 00 00 01 65}` invisible and the freeze never heals:
```cpp
static bool containsSyncNalu(const uint8_t *d, size_t len) {
  size_t i = 0;
  while (i + 3 < len) {
    size_t hdr = 0;
    if (d[i]==0 && d[i+1]==0 && d[i+2]==1) hdr = i + 3;
    else if (i + 4 < len && d[i]==0 && d[i+1]==0 && d[i+2]==0 && d[i+3]==1) hdr = i + 4;
    if (hdr) { uint8_t t = d[hdr] & 0x1F; if (t==5 || t==7) return true; i = hdr + 1; }
    else ++i;
  }
  return false;
}
```
Copy `bounded_queue.hpp` and the `video_process`/`containsSyncNalu`/decoder-thread
logic from `AirPlayEngine.mm` verbatim; they're plain C++/ObjC++.

---

## Fix 2 — portrait rotation (iPhone rotates → OBS follows)

**Symptom:** stock UxPlay advertises "can't rotate", so iOS pins the mirror to the
orientation the session STARTED in — portrait never re-negotiates. (Field-verified
against Airlive Bridge 2026-07-04.)

**Fix — SPLIT the ScreenRotate feature bit between the two adverts:**
- **Bonjour TXT features: leave STOCK** (`0x5A7FFEE6`, bit 8 OFF) — `dnssdint.h` FEATURES_1 unchanged.
- **`/info` plist features: advertise WITH bit 8** — in `raop_handlers.h`, replace the
  echoed TXT features with the field-proven mask:
  ```c
  uint64_t features = ((uint64_t) 0x1E << 32) | 0x5A7FFFF7;   // bit 8 (ScreenRotate) + bits 0/4/33-36
  ```
- `displays.rotation` stays `false`.

Effect: TXT-without-bit-8 + /info-with-bit-8 makes iOS **re-encode the mirror upright
and re-negotiate dimensions on every rotation** — exactly what a switcher wants. Bit 8
in BOTH adverts instead makes the phone stream its native portrait buffer with sideways
content (receiver must rotate pixels — NOT what we want; tested, arrived sideways).

Because the UxPlay lib is prebuilt, edit the STAGED copy at build time (see our
`build-airplay-lib.sh`), not the submodule.

---

## Fix 3 — audio-off (OPTIONAL, postponed)

Bit 9 ("SupportsAudio") OFF in TXT features → the phone shouldn't even encode mirror
audio (small battery/thermal win; the receiver discards it anyway). We POSTPONED this
until rotation is soak-verified (one variable at a time), and some iOS versions may
refuse to mirror to a no-audio receiver. Apply only after rotation is confirmed, with a
one-shot "audio still arriving" log to check it took.

---

## UI changes (your requests)

1. **Drop the "Use Random MAC Address" checkbox.** It's effectively always-on and just
   adds noise. Hardcode random-MAC on (derive a stable-but-unique locally-administered
   MAC per source — e.g. FNV-1a of the source name, so each source is a distinct Apple TV
   yet stable across restarts), and remove the property + its text.

2. **Clean the property texts.** Remove the verbose explanatory blurbs; keep only a short
   **connection instruction**: "On the iPhone: Control Center → Screen Mirroring → pick
   this receiver's name." Keep the Server Name field + Apply button (that's useful — it's
   the receiver name the phone sees).

3. **Source persistence across OBS restart.** OBS already persists a source's SETTINGS in
   the scene collection, so the fix is: on source load (`.update` / create from saved
   settings) **actually start the AirPlay receiver with the saved server name**, instead
   of waiting for the operator to re-Apply. Read `server_name` from `obs_data` on create
   and bring the receiver up immediately, so a reopened scene reconnects without
   re-creating the source. (Model it on the "airplay" plugin that already persists.)

---

## Build gotcha (cost us an hour — put it in the README)

`obs_register_source` REFUSES a source whose `sizeof(obs_source_info)` doesn't match the
running OBS's libobs. Build against the **exact installed OBS version's headers (the
git TAG, e.g. 32.1.2), NOT master** — master's struct is bigger (424 vs 408) and the log
says `Tried to register obs_source_info with size 424 which is more than libobs currently
supports (408)`, the module loads but the source never appears in the "+" menu. Extract
tagged headers: `git archive 32.1.2 libobs | tar -x`.

Also: coddle doesn't quote the output name, so a plugin dir with a SPACE breaks the link
— either keep the dir space-free or link the final `.dylib` by hand.
