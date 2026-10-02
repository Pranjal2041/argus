# Usage in Argus

Argus embeds the native Usage dashboard on macOS 14 or later. Open **View → Usage**, the **Open Usage** command-palette action, or **All usage** in Command Center. `argus app show usage` uses the same workspace navigation contract. Terminal selection and other workspace destinations leave Usage normally.

## Preserved dashboard

`clients/macos/Sources/UsageKit` imports the core, SwiftUI views, provider adapters, and tests from `/Users/pranjal/Developer/usage`. The standalone app's window and application lifecycle are not imported. The original project is unchanged.

- Codex and Claude Code: independent accounts, quota windows, resets, model-specific limits, account details, sign-in and reconnect.
- Daytona: sandbox inventory, capacity, billing and spending charts.
- Modal: workspace containers and billing.
- OpenAI API: organization costs and local monthly budgets.
- Storage: separate local Mac volumes and remote Windows drives through UT.
- Full and compact layouts, account search and filters, activity, connection editor, appearance, cached readings and per-source errors.

Command Center uses Argus's existing theme. The complete dashboard retains Usage's compact/full design and supports light, dark, or inherited appearance. While Usage is open, ⌘N connects an account, ⌘R refreshes usage, and ⌘K searches sources. Sign-in links open Argus-hosted UT Browser, never the system-default browser.

## Shared refresh and warnings

One app-owned `UsageController` refreshes all enabled connections even when the dashboard is closed. Opening multiple views does not create additional polling loops. The default interval is two minutes; **Warnings & refresh** offers one, two, five, or fifteen minutes. Refreshes query provider status/billing APIs or read-only CLI commands; no agent prompt or model run is started.

Command Center shows per-provider quota averages with account coverage, per-account cloud/API spending, separate drives, and connection issues. Providers, billing accounts, and storage capacities are not pooled together.

Warnings are based on normalized measurements, not provider-specific UI logic:

- Default threshold: 10% remaining for quota, monthly budget, or drive capacity.
- Each category can be disabled or assigned its own threshold; individual sources can be muted.
- Model-specific windows are opt-in. Every main quota window is evaluated independently, even if the summary displays a weekly average.
- Dismissals persist across refresh and relaunch until reset or a fresh recovery above the threshold. A later critically low reading can re-alert.
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

Background reading executes only `devin auth status` with a timeout and `NO_COLOR=1`. Each connection supplies its own `HOME` and XDG data/config/cache directories. Ambient provider tokens are not inherited. A missing private profile requires sign-in and never falls back to the account in the user's terminal.

The default executable is `~/.local/bin/devin`, configurable through `executables.devin`. Connections supports **Sign in with Devin CLI**, **Change account**, and separate account identities. Sign-in opens a link in UT Browser; the user pastes its code into Argus's secure code field. The CLI handles PKCE, token exchange, and enterprise routing through `devin auth login --force-manual-token-flow` in a private, owned prompt terminal. That terminal is not a tmux/broker session, never receives global keyboard input, and has no model run. Argus does not read the CLI API key or call undocumented endpoints.

Every attempt uses a new owner-only profile directory. Only verified identities are committed. The shared profile-commit contract, also used by Codex, rejects duplicate identities, shared roots, stale configuration, and disabled/removed connections. A failed or cancelled attempt stops its owned process and deletes only its temporary profile; the previous account and other connections remain unchanged. New private profiles and identity metadata survive Argus restarts. Changing the terminal's default Devin login no longer changes these connections.

Existing Devin connections from the initial integration retain their labels but need **Sign in** once to establish an independent account. No default CLI credentials are copied, overwritten, or signed out.

Only explicit daily/weekly remaining percentages or a reported consumed/limit ACU pair become quota measurements. Missing reset times stay unknown. Unrecognized output and quota failures use the shared unavailable/cached-reading behavior, never a fabricated balance.

Account visibility is independent of measurement availability for every provider. Full and compact dashboards retain accounts without readings in a shared status card, or in their existing provider card when other accounts have quota readings. Command Center retains a navigable status tile. Saved identity remains visible, missing usage is not labeled as missing authentication, and enabled connections appear after relaunch even before a successful reading exists. Unknown measurements never contribute to averages or usage warnings.

During implementation on October 1, 2026, the installed CLI reported successful enterprise authentication but **Failed to fetch quota**. The failure path was checked live; successful quota normalization is fixture-tested, not verified against a successful live response on this account. `/usage` reports session consumption and is not a substitute for account quota. See the official [CLI command reference](https://docs.devin.ai/cli/reference/commands) and [usage documentation](https://docs.devin.ai/admin/billing/usage).

## Automated verification

```sh
swift test --package-path clients/macos --filter 'UsageKitTests|UsageIntegrationTests'
UT_USAGE_VISUAL_QA=1 swift test --package-path clients/macos --filter UsageIntegrationTests
```

The opt-in visual test opens real native windows, mounts the actual SwiftUI views with fixture data, presses native accessibility controls, and captures `/tmp/argus-usage-*.png`. Run it only after arranging an approved desktop-testing window with the user. It covers Command Center dismissal/open, card-arrangement controls and reset, full and compact account navigation, warning restoration, provider selection, Devin code entry, verified account replacement and cancellation. It does not use real credentials or contact providers. `UT_DEVIN_CLI_PROBE=1` additionally starts and cancels the installed CLI's sign-in prompt in an empty private profile, without opening a browser or entering a login code.

The shared tests cover independent accounts, partial failures, credentials and rollback, quota/billing normalization, migration, alert reset/recovery/freshness, persistent settings, and single-loop ownership. The source app's tests are preserved alongside the new integration tests.
