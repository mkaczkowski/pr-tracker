# PRTracker

PRTracker is a small macOS menu bar app for staying on top of GitHub pull requests that need your attention. It keeps your review queue visible without needing to camp in GitHub all day.

It focuses on a few practical things:

- **Needs your review**: PRs where you are currently requested.
- **Needs re-review**: PRs where your non-approval review is stale after new commits.
- **Your PRs blocked on you**: authored PRs with requested changes you still need to address.
- **Your PRs waiting on reviewers**: authored PRs that still need reviewer attention.
- **Your PRs with enough approvals**: authored PRs that have met the configured approval threshold.
- **Per-PR reminders**: set quick or custom reminders to come back and review later.
- **System notifications**: optional review alerts and reminder notifications while the app is running.
- **Useful controls**: configure GitHub host/org, required approvals, refresh interval, and launch at login.

The app uses one GraphQL request per refresh, then computes approvals, stale pushes, and review age locally.

**Needs:** macOS 14+, [GitHub CLI](https://cli.github.com/) (`brew install gh`) with `gh auth login` (use `--hostname` for GitHub Enterprise; set the host in app Settings).

## Install a release

Official macOS zips are published on **[GitHub Releases](https://github.com/mkaczkowski/pr-tracker/releases)** (built by CI when a maintainer pushes a version tag—see [CONTRIBUTING.md](CONTRIBUTING.md)).

1. Download **PRTracker-macos-\*.zip** from the latest release and **double-click it** (Finder expands it; no Terminal needed).
2. Drag **PRTracker.app** to **Applications** (recommended before the next step).
3. **Clear quarantine** so Gatekeeper allows the unsigned build (this is the reliable fix when macOS shows *“could not verify… malware”* with only **Close** / **Move to Trash**). Only do this if you **trust** this zip (ideally compare **SHA-256** with the release page first):

   ```bash
   xattr -dr com.apple.quarantine /Applications/PRTracker.app
   ```

   If the app is still in Downloads, use that path instead, for example:

   ```bash
   xattr -dr com.apple.quarantine ~/Downloads/PRTracker.app
   ```

4. Open **PRTracker** from Applications or Spotlight. After launch, look in the **menu bar** (no Dock icon).

**Alternatives:** **Control-click → Open**, or **System Settings → Privacy & Security → Open Anyway** after a blocked launch—sometimes enough, but quarantine removal above matches what usually works when those options do not appear.

**Why:** downloads get **quarantine**; our GitHub builds are **not Apple-notarized** (Developer ID + `notarize.sh` avoids this). Clearing quarantine removes the “downloaded from internet” flag only—it does not audit the app; use trusted releases only.

Optional: verify the zip with `shasum -a 256` if a SHA-256 was published with the release.

## Build from source

Open `PRTracker.xcodeproj` in Xcode and run the **PRTracker** scheme.

## Privacy

- No telemetry.
- Auth uses `gh auth token`; tokens stay **in memory** for the session and are **not** written to disk by PRTracker.

## Packaging

- **GitHub Releases:** push a tag named `v*` (must match Xcode **Marketing Version**). CI runs [`check-release-tag.sh`](scripts/check-release-tag.sh), **tests**, then [`package-unsigned.sh`](scripts/package-unsigned.sh); see [`.github/workflows/release.yml`](.github/workflows/release.yml).
- **Local zip** (manual / pre-tag): `./scripts/package-unsigned.sh` ([CONTRIBUTING.md](CONTRIBUTING.md)).
- **Notarize** a signed artifact: `scripts/notarize.sh`
- Homebrew cask `pr-tracker`: optional / planned

For contributors: [CONTRIBUTING.md](CONTRIBUTING.md). Security: [SECURITY.md](SECURITY.md). MIT — [LICENSE](LICENSE).