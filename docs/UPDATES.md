# Updates

DNP Remote Mac uses [Sparkle 2](https://sparkle-project.org/) to deliver
in-app updates from GitHub Releases. The runtime side lives in
`apps/DNPRemoteMac/DNPRemoteMac/Updates/UpdateService.swift`; the
release side lives in `.github/workflows/release.yml` and
`scripts/generate-appcast.sh`.

## How it works

```
push to main ──▶  (no auto-release on main)
manual `Release` workflow ──▶  build x86_64 + arm64 ──▶
       sign + notarize each DMG ──▶
       sign each DMG with Sparkle Ed25519 private key ──▶
       generate / merge appcast-arm64.xml + appcast-x86_64.xml ──▶
       publish GitHub Release with tag vX.Y.Z attaching:
         · DNPRemoteMac-X.Y.Z-arm64.dmg
         · DNPRemoteMac-X.Y.Z-x86_64.dmg
         · appcast-arm64.xml
         · appcast-x86_64.xml
```

The shipped Mac app polls
`https://github.com/rotem221/DNPRemoteIDE/releases/latest/download/appcast-<arch>.xml`
once a day in the background (and on demand when the user clicks
"Check for Updates"). Sparkle compares the version in the appcast to
the running build, verifies the Ed25519 signature on the DMG enclosure,
and offers the user an install dialog when there's something newer.

## One-time setup before the first release

You only need to do this once per product line.

### 1. Generate the Sparkle keypair

```sh
swift scripts/generate-sparkle-key.swift
```

The private key is written to `~/.dnp-sparkle-private-key` (chmod 600).
Both halves are also printed to stdout. Keep the private key safe —
losing it means you can't sign future updates and existing installs
will refuse to upgrade.

### 2. Add GitHub repository secrets

In **Settings → Secrets and variables → Actions** add:

| Secret name                              | What it is                                                    |
| ---------------------------------------- | ------------------------------------------------------------- |
| `SPARKLE_PRIVATE_KEY`                    | The base64 private key from step 1.                           |
| `DEVELOPER_ID_APPLICATION_CERTIFICATE`   | Base64-encoded `.p12` of your "Developer ID Application" cert.|
| `DEVELOPER_ID_APPLICATION_PASSWORD`      | Password used when exporting the `.p12`.                      |
| `KEYCHAIN_PASSWORD`                      | Any non-empty string — used to lock the CI keychain.          |
| `APPLE_ID`                               | Apple ID email used for notarization.                         |
| `APPLE_APP_SPECIFIC_PASSWORD`            | App-specific password from appleid.apple.com.                 |
| `APPLE_TEAM_ID`                          | Your 10-character team id.                                    |

To export the `.p12`: open Keychain Access → My Certificates → right-click
"Developer ID Application: YOUR NAME" → Export → save as `.p12`. Then:

```sh
base64 -i path/to/cert.p12 | pbcopy
```

Paste that into the `DEVELOPER_ID_APPLICATION_CERTIFICATE` secret.

### 3. Local Sparkle public key (optional)

If you want the local Debug build to also know how to verify updates
(e.g. for testing the install flow against a real release), edit
`apps/DNPRemoteMac/project.yml` and replace the empty
`SPARKLE_PUBLIC_KEY: ""` line with your base64 public key from step 1,
then run `xcodegen generate`. CI overrides this for release builds, so
this is purely a local-dev convenience.

## Cutting a release

1. Make sure `main` is green and the changelog/tag-relevant work is
   merged.
2. Open **Actions → Release → Run workflow** in the GitHub UI.
3. Enter the new version in `X.Y.Z` form (e.g. `0.2.0`).
4. Wait for both build matrix shards to finish (~25 min). The
   workflow notarizes each DMG, signs them with Sparkle, builds an
   appcast that prepends the new entry on top of the existing release
   notes, and creates a GitHub Release.
5. Existing installs pick up the update within 24h, or immediately if
   the user clicks **Settings → Updates → Check Now**.

## What the user sees

* **Settings → Updates** card surfaces:
  - Current version + relative "last checked" timestamp.
  - "Update available" banner with Install / Release Notes buttons,
    visible only when Sparkle has a fresh item.
  - Manual "Check Now" button.
  - Toggle for daily background checks (defaults on).
  - Stable / Beta channel picker.
* **DNP Remote Mac → Check for Updates…** in the application menu —
  same as the Settings button, just lives where Apple's HIG expects it.
* On a successful probe Sparkle's standard installer dialog appears
  with release notes pulled from `<sparkle:fullReleaseNotesLink>`,
  download progress, and a "Install and Relaunch" button.

## Channels

| Channel | Tag pattern         | Appcast filename                  |
| ------- | ------------------- | --------------------------------- |
| stable  | `vX.Y.Z`            | `appcast-<arch>.xml`              |
| beta    | `vX.Y.Z-beta.N`     | `appcast-beta-<arch>.xml` (under tag `beta-channel`) |

Only stable is wired up out of the box; the runtime + scripts already
support beta. To enable beta, add a `release-beta.yml` workflow that
attaches DMGs to a fixed `beta-channel` tag and calls
`scripts/generate-appcast.sh` with `CHANNEL=beta`.

## Troubleshooting

**"Sparkle updater failed to start"** in the Mac app log on launch:
Info.plist is missing `SUFeedURL` or the bundle isn't code-signed.
Debug builds always log this — it's expected when neither
`SPARKLE_FEED_URL` nor `SPARKLE_PUBLIC_KEY` is set in `project.yml`.

**The install button does nothing**: the released app's embedded
public key doesn't match what the workflow signed with. Generate a
fresh keypair, update both the GitHub secret and Info.plist, ship a
new release. Existing users may need a one-time manual download from
the Releases page to pick up the new public key.

**`sign_update` not found in CI**: SwiftPM didn't resolve Sparkle.
Re-run the workflow — the resolve step is idempotent.
