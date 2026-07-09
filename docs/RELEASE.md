# Releasing Airlive Bridge (Sparkle auto-update)

Airlive Bridge ships as a notarized Developer ID `.dmg` (the "OBS model", not the
App Store) and self-updates with **Sparkle**: the app checks an appcast feed,
downloads the new `.dmg`, **verifies an EdDSA signature**, replaces itself in
place, and relaunches. The user's settings survive (they live in Application
Support / UserDefaults / Keychain, outside the app bundle).

This doc is the runbook. The code side is already wired
(`SPUStandardUpdaterController` in `AirliveBridgeApp.swift`, the Sparkle keys in
`project.yml → Info.plist`, and the signing steps in `scripts/package.sh`).

---

## Prerequisites (blocked on the paid Apple Developer Program)

Everything below the "one-time setup" is ready. Two things need **David** and a
**paid Apple Developer Program** membership ($99/yr) before the first public
release:

- A **"Developer ID Application"** certificate for team `XWBJP49FTR` in the login
  Keychain (a *free* Apple ID only issues "Apple Development" — that can't
  notarize).
- A **notarytool keychain profile**:
  ```
  xcrun notarytool store-credentials airlive-notary \
    --apple-id you@example.com --team-id XWBJP49FTR --password <app-specific-pw>
  ```

The EdDSA update key (below) is **independent of Apple** — you can create it any
time.

---

## One-time setup (do once, ever)

**1. Build once so Sparkle's tools unpack.** Build the app in Xcode (or
`xcodebuild`); SPM unpacks Sparkle's tools into DerivedData. Find them:
```
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -path '*/artifacts/sparkle/Sparkle/bin' -type d | head -1)
xattr -dr com.apple.quarantine "$SPARKLE_BIN"   # if macOS quarantines them
```

**2. Generate the EdDSA key.** The private key goes into your login Keychain
(secure); the command prints the **public** key:
```
"$SPARKLE_BIN"/generate_keys
```
Paste the printed public key into `project.yml → SUPublicEDKey`, then `xcodegen`.

**3. Back up the private key — and treat it like a code-signing secret.** It is
the *sole* trust anchor for every installed copy and **can never be rotated for
existing installs**. If it leaks, an attacker can forge updates that all field
machines will trust (a full RCE channel into a non-sandboxed, library-validation-
disabled app). So:
```
"$SPARKLE_BIN"/generate_keys -x /Volumes/<encrypted>/airlive-bridge-sparkle-private-key.txt
```
- Export it onto an **encrypted volume** or straight into a password manager /
  offline secret store — **never** into `~`, iCloud Desktop&Documents, Time
  Machine, or any git working tree.
- Then **shred the plaintext**: `rm -P <the file>`.
- For CI, store it as an **encrypted secret** only.

**4. Decide the permanent appcast host — ONCE.** `SUFeedURL` is baked into every
build and can never change. Recommended: a path on the site you own
(`https://airlive.studio/bridge/appcast.xml` on Vercel — tiny XML). Lock the
domain registration (auto-renew + registrar lock) and the Vercel project against
subdomain takeover: whoever controls that URL controls what every install is told
is "the latest". Put the final URL in `project.yml → SUFeedURL`, then `xcodegen`.

**5. Prove the signature gate actually works (MANDATORY before first ship).**
A build with a wrong/blank key would *install updates without verifying them*.
Do the negative test once:
- Sign a throwaway `.dmg` with a **different** key, put its `edSignature` in a test
  appcast, and confirm Sparkle **REFUSES** it with an EdDSA verification error.
- Confirm `package.sh` aborts if `SUPublicEDKey` is missing/placeholder (it greps
  the built Info.plist — the guard is already in the script).

Only after the wrong-key `.dmg` is proven-rejected **and** the guard passes may an
update ship. (Automatic background checks stay **off** — `SUEnableAutomaticChecks:
false` — until this pipeline has run end-to-end at least once; then you may enable
them.)

---

## Per release (every new version)

**6. Bump BOTH versions** in `project.yml`, then `xcodegen`:
- `MARKETING_VERSION` — the marketing string (e.g. `1.0.1`).
- `CURRENT_PROJECT_VERSION` — the integer Sparkle compares; **strictly increase**
  (`1 → 2 → 3 …`). It becomes `CFBundleVersion` and must equal the appcast item's
  `sparkle:version`.

**7. Build + sign + notarize + sign the update:**
```
DEVELOPER_ID_APP="Developer ID Application: <name> (XWBJP49FTR)" \
NOTARY_PROFILE="airlive-notary" ./scripts/package.sh
```
This builds Release, signs Sparkle's nested helpers bottom-up + the app, makes
`build/Airlive-Bridge-<version>.dmg`, notarizes, staples, and — last — prints
`sparkle:edSignature="…" length="…"` from the **stapled** DMG.

**8. Publish the binary.** Create a GitHub Release tagged `v<version>`; upload the
`.dmg` as an asset. Its download URL **is** the appcast `<enclosure url>` — keep
the filename identical (`Airlive-Bridge-<version>.dmg`).

**9. Update the appcast** (`docs/appcast.xml` is the template): add an `<item>`
with `sparkle:version` = CURRENT_PROJECT_VERSION, `sparkle:shortVersionString` =
MARKETING_VERSION, the enclosure url (the GitHub asset), and the `edSignature` +
`length` from step 7. Upload it to the permanent feed host. *(Or run
`generate_appcast` on a folder of signed `.dmg`s and it writes the whole feed.)*

**10. Verify from an OLD install:** click **Check for Updates…** → Sparkle offers
the new version, downloads, verifies, replaces, relaunches. Also:
```
xcrun stapler validate "build/Airlive-Bridge-<version>.dmg"
spctl -a -t open --context context:primary-signature -vvv "build/Airlive-Bridge-<version>.dmg"   # → accepted
```

---

## Things that 404 or silently break an update (keep in lockstep)

- **DMG filename ≠ enclosure url** → Sparkle 404s. `package.sh` names it
  `Airlive-Bridge-<version>.dmg`; the GitHub asset and the appcast enclosure must
  match exactly.
- **`sparkle:version` ≠ CFBundleVersion** → "no update" or a re-offer loop.
- **`sign_update` run before stapling** → signature won't match the shipped bytes.
  It runs on the final stapled DMG (last step of `package.sh`).
- **`SUFeedURL` changed after ship** → older installs never see updates again.
