# Codex Quota Checker

[KOR](README.md) | **ENG**

- View quotas and local activity for up to four Codex accounts in the macOS menu bar and notch
- An unofficial, independent app built with Codex

![Example app view](resource/images/app-example.png)

## Features

| Feature | Description |
|---|---|
| Quota monitoring | Remaining five-hour and weekly quotas, expected reset times, and countdowns |
| Account display | Register up to four accounts and configure their visibility and order |
| Token usage | Weekly bar or line charts, or a 24-week contribution grid, with totals for today, seven days, and 30 days |
| Session activity | Recent CLI sessions and subagent activity recorded in registered account folders |
| Reset-time setup | Send a minimal request, then fetch the latest quotas and reset times |
| Reset notifications | Advance and scheduled reset notifications, plus early-reset detection |
| Reset credits | View remaining credits and expiration dates; select a row → Use → approve the confirmation dialog |
| Service status | Public OpenAI service status and access to the official status page |

## Requirements

- macOS 14 or later
- Codex CLI installed and signed in
- Run the `.app` bundle and allow macOS notifications to use system notifications

## Installation

### Download a release

- Available package: a ZIP for macOS 14 or later on Apple Silicon (arm64)
- Intel Macs require a source build; no separately validated Intel binary is provided

1. Download the app ZIP from [GitHub Releases](https://github.com/jh-shi-n/codex_quota_checker/releases).
2. Extract the ZIP and move `CodexQuotaChecker.app` to Applications.
3. Launch the app.
4. If macOS blocks it because the developer cannot be verified or Apple cannot check it for malicious software, choose **System Settings → Privacy & Security → Open Anyway**, only if you trust the source.
5. Confirm that you want to open the app.

- Ad-hoc signing is applied; Developer ID signing and notarization are not included
- Ad-hoc signing does not bypass macOS approval on first launch
- No manual signing command is required
- First-launch approval steps: [Apple's official guide](https://support.apple.com/en-us/102445)

### Build from source

- Requires a toolchain supporting Swift tools 6.0 and the macOS SDK
- Ad-hoc signing is applied automatically during packaging; no paid Apple Developer account or certificate is required

```bash
git clone https://github.com/jh-shi-n/codex_quota_checker.git
cd codex_quota_checker
scripts/package_app.sh --output "$PWD/codex/CodexQuotaChecker.app" --configuration release
open "$PWD/codex/CodexQuotaChecker.app"
```

- If you already have the repository, start with the packaging command from the repository root
- Move the generated app to Applications for regular use
- Source builds may also require approval under macOS security settings
- An app transferred to another Mac may require first-launch approval on that Mac
- Run development tests with `swift test` from the repository root

## Getting started

1. Sign in to the account you want to use in Codex CLI.
2. Launch the app and select that account's folder in the setup guide.
3. Check the connection and complete registration.
4. Configure additional accounts and their display order in Settings.

- Account folders correspond to the Codex CLI `CODEX_HOME` path
- Click an account's quota donut to open its details
- Center number: remaining five-hour quota; outer ring: remaining weekly quota
- Collect token usage with the **Update (`업데이트`)** button in account details
- If you defer setup, reopen the guide from the menu bar icon

### Add a Claude account

1. Sign in to a subscription account in Claude Code (`claude auth login --claudeai`).
2. In the app settings, select `Claude` for an empty slot.
3. Set its account folder to `~/.claude` and apply the path.

- Shows five-hour and weekly remaining quotas and reset times; mix Codex and Claude within the four slots.
- Usage queries send no model requests and consume no additional model tokens. Subscription charges are separate.
- Uses the existing Claude Code Keychain login without copying credentials into settings, caches, or logs. Sign in again in Claude Code when credentials expire. Custom folders use their own `.credentials.json`.
- Queries are limited to once per minute, with a five-minute pause after errors.
- Integration depends on an undocumented usage endpoint and may need updates when the service changes.
- Reads Claude live session descriptors (`sessions/*.json`) every two seconds to show main-conversation work, response completion, waiting, and session exit, including activity toasts.
- Never reads conversation bodies, transcript JSONL, or session keys. Existing completion states are not replayed at startup.
- Responses that start and finish between polls may show completion only. Requires a Claude Code version that writes live session metadata.
- Claude subagent activity is not supported. Token charts, reset credits, and model pings remain Codex features. Codex pings can consume model tokens.

## Settings

- Account folders and displayed accounts
- Account names: up to 14 letters, numbers, or spaces; C1–C4 are shown when names are blank
- Account order: drag a row or its right-hand handle to reorder
- Refresh interval: 1–60 minutes, five minutes by default
- Advance reset notification: off, three, five, or ten minutes before reset
- Activity notification duration: 1–10 seconds, three seconds by default
- Account name visibility
- Enable weekly token charts and choose bars or lines; disabling charts restores the contribution grid
- Daily aggregate retention: three months, six months, or one year; one year by default
- Confirm the date range to delete when reducing retention; changing the display format preserves existing data
- Launch automatically at macOS login
- Check or request system notification permission and send a test notification

![Example settings view](resource/images/settings-example.png)

## Data and display scope

- Authentication uses Codex CLI sign-in information in the registered account folder
- Account authentication files, API keys, and OAuth tokens are not copied into settings or caches
- Diagnostic logs: JSONL records of key operations and errors in `~/Library/Logs/CodexQuotaMonitor/`
- Log files: one `diagnostic-YYYY-MM-DD.jsonl` per local date, reused across restarts and concurrent writes on the same day
- Log retention: the most recent seven days, with a 10MB total limit; older records are removed automatically when either limit is exceeded
- Log contents: account slot, operation ID, processing stage, reset-credit result, error category, and reset times; credentials, email addresses, reset-credit IDs, and raw CLI output are excluded
- User settings and initial registration history are stored locally
- Quota and token-usage caches restore the last successful results
- Daily numeric aggregates are stored separately in `~/Library/Application Support/CodexQuotaMonitor/token-history.sqlite`
- Daily aggregates are retained for three calendar months, six calendar months, or one year; the UI offers Monday–Sunday weekly navigation or a contribution grid for the most recent 24 weeks
- Daily aggregates survive expiration of the 14-day snapshot cache; valid older caches are migrated automatically
- Reducing retention removes older daily aggregates; after increasing retention, **Update (`업데이트`)** recollects data from any remaining source records
- Changing or removing an account path clears that slot's aggregates while preserving other accounts
- Recollecting a date replaces its values without adding them again; existing aggregates are kept for past dates whose source records are missing
- Complete historical recalculation cannot be guaranteed if some source records have been deleted
- Measured daily aggregate DB size for four accounts: approximately 32KiB for three months, 52KiB for six months, and 84KiB for one year; source logs, the 14-day cache, and temporary journals are excluded
- The initial collection range depends on available local records; each update is limited to 4,096 files and 256MiB of reads
- Cache expiration does not delete source session files
- Token usage and session activity come from local records in registered account folders and may differ from complete server-side history
- Codex Desktop app activity may not appear
- Reset-time setup may consume usage through an actual request and does not guarantee a change to server reset times
- Reset-credit details and expiration dates are shown only to the extent provided by the server
- Selecting a reset-credit row reveals **Use (`사용`)** and a confirmation dialog labeled **Are you sure? (`정말 사용하시겠습니까?`)**
- Approving **Use (`사용`)** in the confirmation dialog consumes the selected credit, then refreshes quotas and the remaining credit count
- Duplicate clicks during processing and use of expired credits are blocked; retries after a lost response reuse the same request key
- Notification banners depend on macOS permissions, Focus mode, and system settings

## Notes

- An unofficial, independent project with no affiliation with OpenAI
- Codex CLI, credentials, signing keys, and certificates are not included
- Accounts and usage shown in screenshots are sample data

## License

- [MIT](LICENSE)
