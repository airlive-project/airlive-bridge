# Packaging — Airlive Bridge

Distribution model (same as Studio / OBS): a **downloadable, notarized DMG** from
the site. **Not** the Mac App Store — the sandbox would reject the raw sockets,
Bonjour and `dlopen` of libndi/libsrt this app needs.

## One-time setup (your Apple Developer account)

1. **Developer ID Application certificate** in your login keychain (Xcode →
   Settings → Accounts → Manage Certificates → + → Developer ID Application).
2. **notarytool credentials** stored as a keychain profile:
   ```bash
   xcrun notarytool store-credentials airlive-notary \
     --apple-id you@example.com --team-id TEAMID \
     --password <app-specific-password>   # appleid.apple.com → App-Specific Passwords
   ```

## Build the icon (once you have the logo)

```bash
./scripts/make-icon.sh ~/Downloads/airlive-bridge-1024.png
```
Generates every size into `Sources/Assets.xcassets/AppIcon.appiconset`. Until you
run it the app simply builds without a custom icon.

## Build the release DMG

```bash
DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="airlive-notary" \
./scripts/package.sh
```
Produces `build/Airlive Bridge.dmg` — signed (Hardened Runtime), notarized and
stapled, ready to upload. Run with no env vars for an unsigned smoke-test build.

## Why the entitlement matters

`AirliveBridge.entitlements` sets `com.apple.security.cs.disable-library-validation`.
Under the Hardened Runtime (required for notarization) `dlopen` of a dylib signed by
a **different** Team ID is blocked — that's exactly libndi (NDI Runtime) and libsrt
(brew). Without this entitlement **NDI and SRT silently fail on the notarized build**
even though they work in debug. Keep it.

## Runtime dependencies on the user's Mac

- **NDI output:** the free **NDI Runtime / NDI Tools** (ndi.video). Without it the
  NDI output is disabled (logged), the rest works.
- **SRT output:** `brew install srt`. Without it the SRT output is disabled
  (logged), the rest works.
- **OBS / RTSP:** no extra install — OBS uses the Airlive plugin; RTSP is built in.

## Checklist before a release

- [ ] `make-icon.sh` run with the final logo.
- [ ] `MARKETING_VERSION` bumped in `project.yml`.
- [ ] `package.sh` produces a **notarized + stapled** DMG (`stapler validate` passes).
- [ ] Smoke-test the DMG on a **second** Mac (no dev tools) — app launches, NDI/SRT
      degrade gracefully if their runtimes are absent.
- [ ] Reliability soak (see ROADMAP) before calling a build production-ready.
