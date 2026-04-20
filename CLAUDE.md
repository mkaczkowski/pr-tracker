# PR-Tracker

Guidance for AI agents when working in this repository.

## Project overview

PRTracker is a macOS menu-bar (`MenuBarExtra`) SwiftUI app that surfaces
action-oriented GitHub PR buckets for the signed-in user:

- **Needs your review** — `user-review-requested:@me`
- **Needs re-review** — `reviewed-by:@me -review-requested:@me -author:@me`,
filtered to PRs that changed since the user's latest review
- **Your PRs blocked on you** — latest non-author review is
`CHANGES_REQUESTED` and the author has not pushed since
- **Your PRs waiting on reviewers** — authored PRs that still need approvals
or another review after a follow-up push
- **Your PRs with enough approvals** — authored PRs that currently meet the
configured approval threshold

It pulls data with a single GitHub GraphQL request (`PendingReviews.graphql`)
via the token returned from `gh auth token --hostname <host>`, then computes
approvals, stale-push markers, and review-request age in app code
(`ReviewBucketsBuilder`).

- Target: macOS 14+
- UI: SwiftUI + `@Observable` (`AppModel`)
- App is `LSUIElement` (no Dock icon); UI lives in the menu bar popover and the
`Settings` scene.
- Default GitHub host: `github.com`. Other hosts use
`https://<host>/api/graphql`; `github.com` is special-cased to use
`https://api.github.com/graphql`.

## Repository layout

```
PRTracker/
  PRTrackerApp.swift          # @main, MenuBarExtra + Settings scene
  AppModel.swift              # @MainActor @Observable app state + refresh orchestration
  Models/                     # AppSettings, LoadState, PullRequestModels, ReviewBuckets
  Services/                   # GHAuthService, PendingReviewsService, ReviewBucketsBuilder,
                              # RefreshScheduler, Reachability, SeenStateStore,
                              # NotificationService, LaunchAtLoginService, ProcessSpawning
  Views/                      # MenuBarLabel, MenuBarPopover, SettingsView, state views, rows
  Utilities/                  # DateDecoding, RelativeTime, LoggerCategories, TitleParser
  Resources/PendingReviews.graphql
  Info.plist
PRTrackerTests/               # XCTest target with JSON fixtures under Fixtures/
PRTracker.xcodeproj/          # Single shared scheme: PRTracker
scripts/notarize.sh           # notarytool submit + stapler staple wrapper
```

## Build, run, test

There is no SwiftPM `Package.swift`; everything is driven by the Xcode project.

```bash
# Build (Debug)
xcodebuild -project PRTracker.xcodeproj -scheme PRTracker -configuration Debug build

# Run unit tests on the default macOS destination
xcodebuild -project PRTracker.xcodeproj -scheme PRTracker -destination 'platform=macOS' test

# Run a single test
xcodebuild -project PRTracker.xcodeproj -scheme PRTracker -destination 'platform=macOS' \
  -only-testing:PRTrackerTests/ReviewBucketsBuilderTests/testBuilderMatchesFixtureSemantics test
```

For interactive development, open `PRTracker.xcodeproj` in Xcode and run the
`PRTracker` scheme.

The app requires the GitHub CLI to be installed and authenticated against the
configured host before it can fetch:

```bash
brew install gh
gh auth login

# For GitHub Enterprise Server
gh auth login --hostname github.example.com
```

`GHAuthService` shells out to `gh auth token --hostname <host>` via
`ProcessSpawning` and caches the token in memory only.

## Architecture notes

- **Concurrency:** `AppModel` is `@MainActor`. `PendingReviewsService` and
`GHAuthService` are `actor`s. Always hop to the main actor before touching
`AppModel` state from background callbacks (`Reachability`,
`SleepWakeObserver`, `RefreshScheduler` already do this — follow the
existing pattern with `Task { @MainActor [weak self] in ... }`).
- **Single source of truth:** All UI reads from `AppModel` (`buckets`,
`loadState`, `lastRefreshedAt`, `rateLimitRemaining`, `isOnline`,
`settings`). Don't introduce parallel state in views.
- **Refresh orchestration:** Refreshes funnel through `AppModel.refresh(reason:)`,
which is reentrancy-guarded by `isRefreshing` and respects `isOnline`.
Triggers: app launch, `RefreshScheduler` timer, popover open, manual,
reachability-restored, did-wake. Add new triggers by calling `refresh`
with a descriptive `reason` (used in logs).
- **Settings:** `AppSettings` is a value type read from `UserDefaults` via
`AppSettings.fromUserDefaults`. Keys live in `AppSettings.Keys`. Defaults
(host, required approvals, refresh interval, etc.) are static constants on
`AppSettings`. `refreshIntervalSeconds` is clamped to a minimum of 60s.
- **GraphQL query:** Edit `PRTracker/Resources/PendingReviews.graphql` (must be
bundled — `PendingReviewsService.loadGraphQLQuery` reads it from
`Bundle.main`). If you add new fields, update both `PullRequestNode` /
`GitHubGraphQLResponse` and `ReviewBucketsBuilder`.
- **Bucket logic:** `ReviewBucketsBuilder` is the canonical place for
approval counting, "updated since review" detection, and review-request
age. It is pure and `Sendable`; keep it free of side effects so tests can
drive it from JSON fixtures (`PRTrackerTests/Fixtures/graphql-response.json`).
- **Error model:** `PendingReviewsService` distinguishes `AuthError` (401s,
surfaced as `LoadState.unauthenticated`) from generic failures
(`LoadState.error`). On 401 it invalidates the cached token and retries
once. Preserve this shape when adding new error paths.
- **Truncation:** GitHub search is capped at 100 results. The builder sets
`awaitingTruncated` / `reviewedTruncated` when `issueCount > 100`; the
`TruncationBanner` view surfaces this to users.

## Coding conventions

- Swift 5.9+ features in use: `@Observable`, typed throws, `Sendable`
conformance on models and services, `actor` for I/O components.
- Prefer value types (`struct`) for models; mark them `Sendable` and `Codable`
where they cross actor or persistence boundaries.
- 4-space indentation, no trailing whitespace, no semicolons.
- Logging goes through `AppLog` categories in `Utilities/LoggerCategories.swift`
(`AppLog.refresh`, `AppLog.auth`, `AppLog.network`, `AppLog.ui`). Don't use
`print` in app code.
- No third-party network or auth libraries — `URLSession` only.
- Token values must never be written to disk or logged.
- Keep view files small and per-component (one view per file under `Views/`).

## Tests

- Framework: `XCTest`. Target: `PRTrackerTests` (uses `@testable import PRTracker`).
- Fixtures live in `PRTrackerTests/Fixtures/` and are loaded via
`fixtureURL(named:)` (defined in the test target — reuse it instead of
hardcoding paths).
- When changing `ReviewBucketsBuilder` or the GraphQL response shape, update
`graphql-response.json` and `pending-reviews.json` together so the
fixture-driven test stays meaningful.
- Add new tests next to existing ones; mirror the file naming
(`<TypeName>Tests.swift`).

## Packaging

- `.github/workflows/release.yml` runs on push of tags `v`* and uploads the same
zip produced by `scripts/package-unsigned.sh` to GitHub Releases.
- `scripts/package-unsigned.sh` builds Release with ad hoc signing, writes
`build/PRTracker.app` and `build/PRTracker-macos-<version>-b<build>.zip`.
- `scripts/notarize.sh <artifact>` wraps `xcrun notarytool submit --wait` and
`xcrun stapler staple`. It requires `APPLE_TEAM_ID`, `APPLE_ID`, and
`APPLE_APP_SPECIFIC_PASSWORD` in the environment.
- An optional Homebrew cask `pr-tracker` is on the roadmap.

## Things to be careful of

- Don't bypass `AppModel.refresh` — it owns reentrancy, online/offline gating,
and the `LoadState` transitions that the UI binds to.
- Don't introduce blocking work on the main actor (network, `Process`
invocations, file I/O on large data). Push it into the appropriate `actor`.
- Don't change the default host or org without updating `AppSettings`
defaults, the README, and any user-visible copy in `SettingsView`.
- Leave `LSUIElement = true` in `Info.plist` — the app intentionally has no
Dock presence.
- Don't commit `xcuserdata/` or `DerivedData/` (already covered by
`.gitignore`). If Swift packages are added again later, commit the resulting
`Package.resolved` file.

