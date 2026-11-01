# LLM Quota Checker

> **[2026-10-31]** In accordance with Codex's policy on using multiple paid accounts on a single device, registering multiple accounts for the same service in this app is not recommended.

[KOR](README.md) | **ENG**

- Connect up to four Codex and Claude accounts in total, in any combination
- View connected accounts' quotas, session activity, and token usage in the macOS menu bar and notch
- An unofficial, independent app built with Codex/Claude
- Stable release: [0.6.5](https://github.com/jh-shi-n/llm_quota_checker/releases/tag/0.6.5), build `35`

## Screenshots

- Captured from the current UI using sample account and usage data

### Menu bar and notch account display

- Choose a slot style: ring, number + horizontal bars, number + vertical bars, or stacked numbers

<img src="assets/screenshots/quota-cluster.png" alt="Codex and Claude slots showing remaining five-hour and weekly quotas in four styles" width="424">

### Account details

- Five-hour and weekly account quotas, 24-week token usage grid, session activity, and reset-time controls

<img src="assets/screenshots/account-detail.png" alt="Account details showing quota rings and the token usage contribution grid" width="640">

### Settings

<img src="assets/screenshots/settings.png" alt="Accounts settings tab for per-slot account folders, visibility, names, and order" width="560">

## Features

| Feature | Description |
|---|---|
| Quota monitoring | Remaining five-hour and weekly account quotas, reset times, and countdowns |
| Account management | Connect accounts; configure names, visibility, and order |
| Token usage | Weekly bar or line charts, or a 24-week contribution grid; lifetime and peak daily totals |
| Usage information | Hover over `(i)` beside the token usage heading for calculation rules and query status |
| Session activity | Recent CLI sessions and subagent activity from the connected account |
| Reset times and notifications | Check whether quota times are fixed; advance, scheduled reset, and schedule-change notifications |
| Reset credits | View remaining credits and expiration dates, and approve credit use in a confirmation dialog |
| Service status and updates | View OpenAI and Claude service status; install updates and restart from the app |

### Token usage rules

- Dates use UTC, with missing data distinct from zero
- Shows the last 12 months by default; change it with the date range setting
- Codex
  - Earlier dates: server-provided history
  - Today: server value first; local records from the connected account folder when it is zero or unavailable
- Claude
  - Aggregated from the connected folder's Stats cache and session records
  - Excludes web usage, other devices, and account-wide server statistics
  - Switching accounts in the same folder may include the previous account's records

### Notes

- Reset-time checks may consume usage
- Notifications depend on macOS notification permissions and system settings

## Requirements

- macOS 14 or later
- Install and sign in to the CLI for each provider you connect: Codex CLI or Claude Code CLI (both are required for a mixed setup)
- Release ZIPs target Apple Silicon (arm64); Intel Macs require a source build

## Installation

1. Download the app ZIP from the [latest release](https://github.com/jh-shi-n/llm_quota_checker/releases/latest).
2. Extract it, move `CodexQuotaChecker.app` to `/Applications`, and launch it.
3. If macOS blocks the first launch, verify the source and allow it under **System Settings → Privacy & Security → Open Anyway**.
4. In the app's connection guide, select the signed-in Codex or Claude account folder and check the connection.

- Codex account folder: `CODEX_HOME`, or `~/.codex` when unset
- Claude account folder: `CLAUDE_CONFIG_DIR`, or `~/.claude` when unset
- Ad-hoc signed; Developer ID signing and notarization are not included. See [Apple's first-launch guide](https://support.apple.com/en-us/102445).
- Subsequent updates: **App Settings → App Update → Check for Updates → Install Update and Restart** (buttons currently shown in Korean)

- App display name: **LLM Quota Checker**. The `CodexQuotaChecker.app` filename and internal identifiers are retained for compatibility with existing in-app updates, settings, and usage data.
- Release ZIPs use `LLMQuotaChecker-<version>-macos-arm64.zip`; a `CodexQuotaChecker-...zip` compatibility copy is also provided for earlier clients.
- Apps from before the repository rename (0.6.4 and earlier) may fail update checks because they validate the previous repository URL. Version 0.6.5 supports both current and previous URLs.

### Build from source

- Requires a toolchain supporting Swift tools 6.0 and the macOS SDK
- The packaging script includes the executable, icon, and resources, and applies ad-hoc signing

```bash
git clone https://github.com/jh-shi-n/llm_quota_checker.git
cd llm_quota_checker
scripts/package_app.sh --output "$PWD/dist" --configuration release
open "$PWD/dist/CodexQuotaChecker.app"
```

## Usage

- **Register local LLM service folders:** add Codex (`~/.codex`) and Claude (`~/.claude`) account folders in the connection guide or settings
- **View usage:** click a slot to see the connected service's quotas, token usage, and session activity
- **Slot numbers:** remaining five-hour usage / weekly account usage
- **Notifications:** get notified when a quota resets

## License

- [MIT](LICENSE)
