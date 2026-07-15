# Third-party notices

Airlive Bridge is licensed under the **GNU General Public License v3.0** (see
[`LICENSE`](LICENSE)). It incorporates or bundles the following third-party
components, each under its own license (all compatible with GPLv3 for
distribution):

| Component | Role | License |
|---|---|---|
| **UxPlay** (`Vendor/UxPlay/`) | AirPlay Screen-Mirroring receiver | **GPL-3.0** — this is why Bridge as a whole is GPL-3.0 |
| **libsrt** (SRT) | SRT output (bundled dylib) | MPL-2.0 |
| **OpenSSL** (libcrypto / libssl) | crypto for AirPlay + SRT | Apache-2.0 |
| **libplist** | AirPlay property-list parsing | LGPL-2.1 |
| **llhttp** (`Vendor/UxPlay/lib/llhttp/`) | HTTP parsing (UxPlay) | MIT |
| **playfair** (`Vendor/UxPlay/lib/playfair/`) | FairPlay handshake (UxPlay) | see `Vendor/UxPlay/lib/playfair/LICENSE.md` |
| **Sparkle** | in-app update framework | MIT |

Each component's full license text is in its own source tree (e.g.
`Vendor/UxPlay/LICENSE`) or its upstream project.

## Trademarks

- **NDI®** is a registered trademark of **Vizrt NDI AB**. Airlive Bridge is not
  affiliated with, sponsored by, or endorsed by Vizrt/NDI. The NDI runtime is
  **loaded at runtime** from the user's own NDI Tools install — it is **not**
  bundled or redistributed here. "NDI" is used only to describe interoperability.
- **AirPlay** is a trademark of **Apple Inc.**; used descriptively for the
  screen-mirroring interoperability.
- **OBS**, **OBS Studio** are trademarks of their respective owners.
- All other product names, logos, and brands are property of their respective
  owners and are used for identification only.
