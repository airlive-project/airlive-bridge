# Apple Developer release — master checklist (all Mac products)

**Purpose:** one place that says exactly what to do to ship every Mac product
signed + notarized once the paid **Apple Developer Program** account is active.
Until then everything below runs in an *interim* mode (signed with the free
**Apple Development** cert, or unsigned → right-click → Open). Nothing here is
forgotten: the whole pipeline is already wired; the account just flips it on.

Covers THREE separate products (the old combined `Airlive-OBS.pkg` is superseded):
| Product | OBS source name(s) | Repo | Artifact | Packager |
|---|---|---|---|---|
| **Airlive Bridge** (Mac app) | — | `airlive-bridge` | `Airlive-Bridge-<ver>.dmg` | `scripts/package.sh` |
| **Airlive for OBS** | "Airlive Camera" + "Airlive Bridge" | `app-to-obs` (obs-airlive-source) | `Airlive-for-OBS.pkg` | `scripts/make-installer.sh` |
| **Airlive Screen Mirroring for OBS** | "Airlive Screen Mirroring" | `obs-airlive` (obs-airplay-git) | `Airlive-Screen-Mirroring-for-OBS.pkg` | `make-installer.sh` |

The two OBS pkgs install to the **USER** OBS folder (`~/Library/Application Support/obs-studio/plugins/`)
with **NO admin**, via `<domains enable_currentUserHome="true" enable_localSystem="false"/>` — this is
the OBS-plugin standard (DistroAV/obs-ndi ships the identical config; installing into system `/Library`
is treated as a bug upstream, DistroAV issue #904). GUI: the wizard's "Install for me only"; CLI:
`installer -pkg X.pkg -target CurrentUserHomeDirectory`. Each pkg ships its own per-product
`uninstall.command` (removes just its plugin + receipt, no admin). Bridge is a normal drag-install app;
its uninstaller ships in the DMG.

---

## What we HAVE vs what we NEED

**Have now (free, no paid program):**
- `Apple Development: <your-apple-id> (N824A65FF7)` — Team **XWBJP49FTR**.
  Can *sign* an app for local use + right-click-Open on other Macs. **Cannot notarize.**

**Need (all gated on the paid Apple Developer Program — ~$99/yr):**
1. **Developer ID Application** cert → signs the `.app` + its dylibs for distribution.
2. **Developer ID Installer** cert → signs the `.pkg` (this is `productsign`; the
   "Apple Development" cert does NOT work for pkgs).
3. **notarytool credentials** → an app-specific password stored as a keychain profile.
4. **Real Sparkle EdDSA key** (`SUPublicEDKey`) — currently a placeholder in
   `project.yml`; `package.sh` ABORTS a Developer-ID build until it's a real key.

---

## THE SWAP (do this once the account is live)

### 0. One-time account setup
```bash
# In Xcode → Settings → Accounts → add the Apple ID, then "Manage Certificates" →
# +  → "Developer ID Application"  AND  "Developer ID Installer".
# Confirm both landed:
security find-identity -v            | grep "Developer ID"

# notarytool credentials (app-specific password from appleid.apple.com):
xcrun notarytool store-credentials airlive-notary \
  --apple-id <your-apple-id> --team-id XWBJP49FTR --password <APP_SPECIFIC_PW>

# Real Sparkle key (Bridge auto-update). Prints a public key → paste into
# project.yml SUPublicEDKey, then re-run xcodegen:
"$(find ~/Library/Developer/Xcode/DerivedData -path '*/artifacts/sparkle/Sparkle/bin' -type d | head -1)/generate_keys"
```

### 1. Airlive Bridge → notarized DMG
`package.sh` already does the whole chain (sign helpers → sign app hardened-runtime
→ DMG → notarize → staple → EdDSA-sign for the appcast). Just give it the certs:
```bash
DEVELOPER_ID_APP="Developer ID Application: David Evsukov (XWBJP49FTR)" \
NOTARY_PROFILE="airlive-notary" \
./scripts/package.sh
```
Ships `build/Airlive-Bridge-<ver>.dmg`, stapled. Uninstaller (`Uninstall Airlive
Bridge.command`) is copied into the DMG automatically.

### 2 & 3. OBS pkgs → Developer ID Installer + notarize
Both OBS packagers take `INSTALLER_ID` (Developer ID Installer). After `productbuild`,
notarize + staple the pkg:
```bash
INSTALLER_ID="Developer ID Installer: David Evsukov (XWBJP49FTR)" ./make-installer.sh
xcrun notarytool submit dist/obs-airlive.pkg --keychain-profile airlive-notary --wait
xcrun stapler staple dist/obs-airlive.pkg
```
(Same for the combined `make-obs-installer.sh` with `INSTALLER_ID` set.)

---

## Interim (NOW, no paid account)

- **Bridge:** sign with the Apple Development cert — real cert chain → the DMG opens
  on other Macs via **right-click → Open** (no "damaged"). Signed, NOT notarized:
  ```bash
  DEVELOPER_ID_APP="Apple Development: <your-apple-id> (N824A65FF7)" ./scripts/package.sh
  # (no NOTARY_PROFILE → signs + DMGs, skips notarization. SUPublicEDKey may stay
  #  placeholder for a non-distributed interim build — package.sh only WARNS then.)
  ```
  Or the fully-clean fallback (memory `obs-installer-macos14`): ad-hoc app + a
  `pkgbuild --install-location /Applications` pkg (pkg payloads aren't quarantined,
  so a non-quarantined ad-hoc app just launches).
- **OBS pkgs:** unsigned (Apple Development can't sign pkgs). Recipient: right-click
  → Open. Fully functional; only the Gatekeeper prompt differs.

---

## Invariants (keep these true regardless of signing)

- **Self-contained:** every product carries its own dylibs (`@loader_path` /
  `@executable_path`), zero absolute `/opt/homebrew` or `/usr/local` paths baked in.
  Verify: `otool -L` the binary; the OBS packagers already fail the build on a leak.
- **User domain for OBS:** plugins install to **`~/Library/Application Support/
  obs-studio/plugins/`** — no admin, no system directories touched, trivially removed.
- **No system hooks:** no LaunchDaemon/Agent, no kernel ext, no PATH/shell edits.
- **Uninstallers ship with every product** and remove 100% of traces (app-support,
  prefs, Keychain, pkg receipt).
- **Hardened runtime needs `disable-library-validation`** (already in
  `AirliveBridge.entitlements`) so the notarized Bridge can `dlopen` libndi (NDI
  Tools, different Team ID) and a bundled/Homebrew libsrt.
