# PRTracker

PRTracker is a macOS status bar app for pull-request review triage. It mirrors the logic from `gh-pending-reviews`:

- `Awaiting your review` (`user-review-requested:@me`)
- `Reviewed, not currently approved` (`reviewed-by:@me -review-requested:@me`, filtered to latest review state not approved)

It uses a single GitHub GraphQL request, then computes approvals, stale push markers, and review request age in-app.

## Requirements

- macOS 14+
- GitHub CLI: `brew install gh`
- Authenticated GitHub CLI session:

```bash
gh auth login
```

For GitHub Enterprise Server, configure the host in Settings and authenticate with:

```bash
gh auth login --hostname github.example.com
```

## Build

Open `PRTracker.xcodeproj` in Xcode and run the `PRTracker` scheme.

## Security and privacy

- No telemetry is sent.
- The app retrieves a token by running `gh auth token --hostname ...`.
- Tokens are cached in memory only for the current app session.
- Token values are never written to disk by PRTracker.
- The repo's sample data is synthetic and does not contain real production PR data.

## Packaging

- Notarization scaffold: `scripts/notarize.sh`
- Optional distribution: Homebrew cask `pr-tracker`

## Open-source notes

- The default host is `github.com`, but GitHub Enterprise hosts are supported.
- Before distributing a signed build, set your own bundle identifier and Apple signing credentials.
- Contributor guidance lives in `CONTRIBUTING.md`.
- Security reporting guidance lives in `SECURITY.md`.

## License

MIT. See `LICENSE`.

