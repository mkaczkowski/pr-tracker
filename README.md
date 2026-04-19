# PRTracker

macOS menu bar app for GitHub PR review triage: **Awaiting your review** and **Reviewed, not currently approved** (same idea as `gh-pending-reviews`). One GraphQL request per refresh; approvals, stale pushes, and age are computed locally.

**Needs:** macOS 14+, [GitHub CLI](https://cli.github.com/) (`brew install gh`) with `gh auth login` (use `--hostname` for GitHub Enterprise; set the host in app Settings).

## Install a release

Official macOS zips are published on **[GitHub Releases](https://github.com/mkaczkowski/pr-tracker/releases)** (built by CI when a maintainer pushes a version tag—see [`CONTRIBUTING.md`](CONTRIBUTING.md)).

1. Download **`PRTracker-macos-*.zip`** from the latest release and **double-click it** (Finder expands it; no Terminal needed).
2. Drag **`PRTracker.app`** to **Applications** (or run it from the folder).
3. **First launch:** unsigned builds may be blocked until you **right-click the app → Open → Open**, or approve under **System Settings → Privacy & Security**.
4. After launch, look in the **menu bar** (no Dock icon).

Optional: verify the zip with `shasum -a 256` if a SHA-256 was published with the release.

## Build from source

Open `PRTracker.xcodeproj` in Xcode and run the **PRTracker** scheme.

## Privacy

- No telemetry.
- Auth uses `gh auth token`; tokens stay **in memory** for the session and are **not** written to disk by PRTracker.

## Packaging

- **Official release assets:** pushing a git tag named `v*` runs [`.github/workflows/release.yml`](.github/workflows/release.yml) on macOS and uploads the same unsigned zip as `./scripts/package-unsigned.sh` would produce locally.
- **Local zip** (manual / pre-tag test): `./scripts/package-unsigned.sh` ([details](CONTRIBUTING.md))
- **Notarize** a signed artifact: `scripts/notarize.sh`
- Homebrew cask `pr-tracker`: optional / planned

For contributors: [`CONTRIBUTING.md`](CONTRIBUTING.md). Security reports: [`SECURITY.md`](SECURITY.md). MIT — [`LICENSE`](LICENSE).
