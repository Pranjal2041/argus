# Usage in Argus

Argus embeds the native Usage dashboard on macOS 14 or later. Open **View → Usage**, the **Open Usage** command-palette action, or **All usage** in Command Center. `argus app show usage` uses the same workspace navigation contract. Terminal selection and other workspace destinations leave Usage normally.

## Preserved dashboard

`clients/macos/Sources/UsageKit` imports the core, SwiftUI views, provider adapters, and tests from `/Users/pranjal/Developer/usage`. The standalone app's window and application lifecycle are not imported. The original project is unchanged.

- Codex and Claude Code: independent accounts, quota windows, resets, model-specific limits, account details, sign-in and reconnect.
- Devin: independent accounts and consumed ACUs for the provider's reporting period, without requiring a quota or reset date.
- Daytona: sandbox inventory, capacity, billing and spending charts.
- Modal: workspace containers and billing.
- OpenAI API: organization costs and local monthly budgets.
- Storage: separate local Mac volumes and remote Windows drives through UT.
- Full and compact layouts, account search and filters, activity, connection editor, appearance, cached readings and per-source errors.

Command Center uses Argus's existing theme. The complete dashboard retains Usage's compact/full design and supports light, dark, or inherited appearance. While Usage is open, ⌘N connects an account, ⌘R refreshes usage, and ⌘K searches sources. Sign-in links open Argus-hosted UT Browser, never the system-default browser.

## Shared refresh and warnings

One app-owned `UsageController` refreshes all enabled connections even when the dashboard is closed. Opening multiple views does not create additional polling loops. The default interval is two minutes; **Warnings & refresh** offers one, two, five, or fifteen minutes. Refreshes query provider status/billing APIs or read-only CLI commands; no agent prompt or model run is started.

All live HTTP clients share an in-process polling coordinator. Identical overlapping reads share one in-flight request; completed responses are not reused as fresh readings. A 429 pauses the affected origin/header scope, honors `Retry-After` (seconds or HTTP date), and backs off from two to thirty minutes on repeated failures. A longer server deadline is never shortened. Automatic and manual refreshes cannot bypass that pause, and unrelated accounts/providers continue refreshing. Explicit 5xx cooldowns are also honored. Connections reports rate limiting and the next eligible request time without asking for reauthentication; the last successful reading keeps its original timestamp until a new fetch succeeds. The coordinator does not control an independently running standalone app: the cutover step below is still required.

Command Center shows per-provider quota averages with account coverage, per-account consumed units and cloud/API spending, separate drives, and connection issues. Providers, billing accounts, and storage capacities are not pooled together.

The shared consumption payload represents a measured amount and unit, with an optional provider reporting interval. Full, compact, detail, and Command Center views display it without deriving a percentage or reset countdown. Zero is a valid measurement; a missing total is unavailable. Cached totals remain labeled, and consumption without a limit does not generate remaining-allowance warnings.

Warnings are based on normalized measurements, not provider-specific UI logic:

- Default threshold: 10% remaining for quota, monthly budget, or drive capacity.
- Each category can be disabled or assigned its own threshold; individual sources can be muted.
- Model-specific windows are opt-in. Every main quota window is evaluated independently, even if the summary displays a weekly average.
- Dismissals persist across refresh and relaunch until reset or a fresh recovery above the threshold. A later critically low reading can re-alert.
- Quota dismissals keep their original cycle boundary through reset-time estimate changes. With a reported period, the nearest nominal cycle determines renewal; without one, a changed deadline cannot rearm the warning before the original boundary passes. Missing reset metadata preserves the dismissal, and its first reported boundary is adopted without re-alerting.
- Snooze supports one, four, or twenty-four hours. **Restore dismissed warnings** clears all dismissals.
- Unavailable, stale, expired, or over-age readings never trigger warnings. Missing data does not erase an existing dismissal. Prior-month budget readings cannot be assigned to the new month's alert cycle.

The complete dashboard's existing attention/activity views remain available independently of Command Center warning preferences.

## Configuration and migration

On first launch, Argus imports `~/Library/Application Support/Usage/integrations.json` and last readings into `~/Library/Application Support/Argus/Usage/`. It never overwrites an existing Argus configuration. Imported readings are cached until refreshed. `--usage-config /absolute/path.json` selects an alternate configuration and skips automatic import.

Imported connections retain their credential references and Codex profile paths. The original configuration, credential files, and Keychain items are not deleted. New credentials use an `argus-usage-` reference prefix; replacing an imported credential cannot delete a standalone Usage key. New profiles live in Argus's own Usage directory. Configuration files are owner-readable/writable and contain references rather than secrets.

Warning preferences and dismissals use the `dev.universaltmux.usage` defaults suite. Existing Keychain access may require **Authorize saved key** in Connections; background checks do not display authorization dialogs. Background reads/token renewal run through the same signed executable in `--usage-keychain-worker` mode, before its app lifecycle. Private pipes carry requests/results; this isolates legacy process-wide Keychain prompt settings from Argus's browser and credential vault.

For cutover, quit standalone Usage before starting the new Argus build so both applications do not refresh the same imported OAuth profiles concurrently. Terminal sessions and brokers do not need restarting.

## Command Center card arrangement

Drag Usage cards to either side of another card to reorder them. **Arrange** exposes left/right buttons; the context menu also moves a card to either end. **Reset order** restores the default layout. The arrangement is saved separately from credentials and warning settings, survives refresh and relaunch, and retains positions for temporarily absent cards. New cards follow saved cards. Identity anchors keep accounts in place when their display changes between live and unavailable readings or between individual accounts and quota aggregates. Drag payloads are scoped to the current strip; unrelated or stale drops do not alter the layout.

## Devin CLI

Background reading first executes `devin auth status` with a timeout and `NO_COLOR=1` to verify the saved identity. Each connection supplies its own `HOME` and XDG data/config/cache directories. Ambient provider tokens are not inherited. A missing private profile requires sign-in and never falls back to the account in the user's terminal.

The default executable is `~/.local/bin/devin`, configurable through `executables.devin`. Connections supports **Sign in with Devin CLI**, **Change account**, and separate account identities. Sign-in opens a link in UT Browser; the user pastes its code into Argus's secure code field. The CLI handles PKCE, token exchange, and enterprise routing through `devin auth login --force-manual-token-flow` in a private, owned prompt terminal. That terminal is not a tmux/broker session, never receives global keyboard input, and has no model run.

After verifying identity, the adapter reads only that private profile's `credentials.toml` and sends a read-only `GET personal-analytics/consumption` to its declared HTTPS Devin API deployment with the saved bearer credential. This is the endpoint used by Devin's own My analytics page. Credential values remain in memory and are never included in configuration, snapshots, logs, or command arguments. Browser login is not needed for ongoing refreshes. The adapter selects the current `[start, end)` reporting interval and its `acus_consumed` value, preserving the provider's date offset and full numeric precision. Its card rounds for display (for example, `2,332 ACUs used · Sep 15 – Oct 14`), without displaying a limit or reset countdown.

Every attempt uses a new owner-only profile directory. Only verified identities are committed. The shared profile-commit contract, also used by Codex, rejects duplicate identities, shared roots, stale configuration, and disabled/removed connections. A failed or cancelled attempt stops its owned process and deletes only its temporary profile; the previous account and other connections remain unchanged. New private profiles and identity metadata survive Argus restarts. Changing the terminal's default Devin login no longer changes these connections.

Existing Devin connections from the initial integration retain their labels but need **Sign in** once to establish an independent account. No default CLI credentials are copied, overwritten, or signed out.

When personal consumption is unavailable, a valid explicit CLI usage reading remains a fallback for self-serve plans: standalone consumed ACUs (including the numerator of a reported used/limit pair) become consumed-unit readings, while daily/weekly remaining percentages remain quota readings. Missing values never become zero. Authentication, denied analytics access, and unavailable measurements retain distinct errors.

Account visibility is independent of measurement availability for every provider. Full and compact dashboards retain accounts without readings in a shared status card, or in their existing provider card when other accounts have quota readings. Command Center retains a navigable status tile. Saved identity remains visible, missing usage is not labeled as missing authentication, and enabled connections appear after relaunch even before a successful reading exists. Unknown measurements never contribute to averages or usage warnings.

On October 2, 2026, a signed-in enterprise account's CLI returned identity and plan metadata but no consumption. Its personal-consumption API returned an ACU total without an ACU limit, matching the My analytics page. `/usage` reports session consumption and is not used as an account total. See the official [CLI command reference](https://docs.devin.ai/cli/reference/commands) and [personal analytics documentation](https://docs.devin.ai/enterprise/security-access/personal-analytics).

## Automated verification

```sh
swift test --package-path clients/macos --filter 'UsageKitTests|UsageIntegrationTests'
UT_USAGE_VISUAL_QA=1 swift test --package-path clients/macos --filter UsageIntegrationTests
```

The opt-in visual test opens real native windows, mounts the actual SwiftUI views with fixture data, presses native accessibility controls, and captures `/tmp/argus-usage-*.png`. Run it only after arranging an approved desktop-testing window with the user. It covers Command Center dismissal/open, card-arrangement controls and reset, consumed-unit cards and details, full and compact account navigation, warning restoration, provider selection, Devin code entry, verified account replacement and cancellation. It does not use real credentials or contact providers. `UT_DEVIN_CLI_PROBE=1` additionally starts and cancels the installed CLI's sign-in prompt in an empty private profile, without opening a browser or entering a login code. `UT_DEVIN_USAGE_PROBE=1` enables a separate read-only test of the actual consumption adapter using a saved, enabled private account; it opens no windows and changes no connections.

The shared tests cover independent accounts, partial failures, credentials and rollback, quota/billing normalization, migration, alert reset/recovery/freshness, persistent settings, and single-loop ownership. The source app's tests are preserved alongside the new integration tests.
