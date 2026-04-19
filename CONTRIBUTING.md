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

## Unsigned distribution (informal builds)

Use this when you want to share a Release build **without** Apple Developer ID signing or notarization—for example teammates or testers who accept Gatekeeper prompts.

From the repository root:

```bash
./scripts/package-unsigned.sh
```

What it does:

1. Builds **Release** with **ad hoc** code signing (`CODE_SIGN_IDENTITY=-`). That is not a Developer ID certificate; it only produces a normal `.app` suitable for copying to other Macs without using your personal development provisioning profile.
2. Writes `**build/PRTracker.app`** (ready to drag to `/Applications` or run from the folder).
3. Writes `**build/PRTracker-macos-<version>-b<build>.zip**` for attaching to a release, chat, or internal storage.
4. Prints **SHA-256** of the zip so recipients can verify integrity if you publish the hash.

Intermediate Xcode output lives under `**build/DerivedData/`** (ignored by git). To force a fully clean rebuild, remove the whole `build/` directory and run the script again.

**Installers need** the GitHub CLI and an authenticated session (`brew install gh`, `gh auth login`); see the main README.

**Gatekeeper:** Downloaded zips are usually **quarantined**. Recipients should **Control-click (or right-click) the app → Open → Open** the first time, or use **System Settings → Privacy & Security** if macOS blocks the launch. Do not suggest removing quarantine for people who do not trust the source.

For builds that strangers can run without security friction, use **Developer ID**, **notarization**, and `**scripts/notarize.sh`** instead (see `README.md`).

## Pull Request Notes

- Keep changes focused.
- Add or update tests when behavior changes.
- Avoid committing secrets, tokens, local build products, or personal `gh` configuration.
- If you change auth, host defaults, or packaging behavior, update `README.md` too.

