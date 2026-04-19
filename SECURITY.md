## Security Policy

If you discover a security issue, please do not open a public issue with exploit details.

Use one of these private channels:

- GitHub private vulnerability reporting for this repository, if enabled
- direct email to the maintainer address listed in the repository profile or release metadata

Include:

- affected version or commit
- reproduction steps
- impact
- any suggested mitigation

## Security Notes

- PRTracker does not ship telemetry.
- Authentication is delegated to the GitHub CLI (`gh`).
- Access tokens are kept in memory for the current app session and are not intentionally written to disk by PRTracker.
- The app is intentionally not sandboxed because it shells out to the locally installed `gh` binary and reads its output.

## Disclosure Expectations

Please allow time for investigation and remediation before public disclosure.
