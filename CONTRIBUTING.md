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

## Pull Request Notes

- Keep changes focused.
- Add or update tests when behavior changes.
- Avoid committing secrets, tokens, local build products, or personal `gh` configuration.
- If you change auth, host defaults, or packaging behavior, update `README.md` too.
