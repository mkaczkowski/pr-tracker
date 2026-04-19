## Contributing

PRTracker welcomes small, reviewable pull requests.

## Development Setup

1. Install the GitHub CLI: `brew install gh`
2. Authenticate with GitHub:
  - `gh auth login`
  - For GitHub Enterprise Server: `gh auth login --hostname github.example.com`
3. Open `PRTracker.xcodeproj` in Xcode.

## Build And Test

Run the full test suite with:

```bash
xcodebuild -project PRTracker.xcodeproj -scheme PRTracker -destination 'platform=macOS' test
```

## Official GitHub Releases (CI)

Pushing a git tag whose name starts with **`v`** (for example `v1.0.1`) triggers [`.github/workflows/release.yml`](.github/workflows/release.yml) on **macOS 14**. It runs `./scripts/package-unsigned.sh`, attaches `build/PRTracker-macos-*.zip` to a [GitHub Release](https://github.com/mkaczkowski/pr-tracker/releases), and prepends generated release notes with the zip’s **SHA-256**.

**To cut a release:**

1. In Xcode, bump **Marketing Version** and **Build** (`PRTracker` target → General). The git tag **`v…` must match Marketing Version** (without the `v`): e.g. tag `v1.0.2` requires Marketing Version `1.0.2`. CI enforces this before running tests or building the zip.
2. Commit the version bump on `master`.
3. Optional but recommended — fail fast before pushing:

```bash
./scripts/check-release-tag.sh v1.0.2   # use the tag you are about to push
```

4. Tag and push the tag (starts the workflow):

```bash
git tag -a v1.0.2 -m "Release v1.0.2"
git push origin v1.0.2
```

The workflow runs **tests**, then **`package-unsigned.sh`**, then publishes the GitHub Release.

Pushing commits **without** a new tag does not publish a release asset. Fix a bad release manually in the GitHub UI if needed; avoid reusing the same tag name.

## Unsigned builds (local)

Use this for a Release build **without** Apple Developer ID signing or notarization—teammates, QA, or testing before you tag.

From the repository root:

```bash
./scripts/package-unsigned.sh
```

What it does:

1. Builds **Release** with **ad hoc** code signing (`CODE_SIGN_IDENTITY=-`). That is not a Developer ID certificate; it produces a normal `.app` you can copy to other Macs without your personal development provisioning profile.
2. Writes `**build/PRTracker.app`** (drag to `/Applications` or run from the folder).
3. Writes `**build/PRTracker-macos-<version>-b<build>.zip**` (same artifact CI attaches to releases).
4. Prints **SHA-256** of the zip.

Intermediate Xcode output is under `**build/DerivedData/`** (ignored by git). For a clean rebuild, remove the whole `build/` directory and run the script again.

**Installers need** the GitHub CLI and `gh auth login`; see the main README.

**Gatekeeper:** Downloaded zips are usually **quarantined**. Recipients should **right-click the app → Open → Open** the first time, or use **System Settings → Privacy & Security** if macOS blocks launch. Do not suggest stripping quarantine for sources they do not trust.

For installs without Gatekeeper friction for the general public, use **Developer ID**, **notarization**, and `scripts/notarize.sh` (see `README.md`).

## Pull Request Notes

- Keep changes focused.
- Add or update tests when behavior changes.
- Avoid committing secrets, tokens, local build products, or personal `gh` configuration.
- If you change auth, host defaults, or packaging behavior, update `README.md` too.

