# Standalone Usage baseline

These Swift files are unmodified copies from `/Users/pranjal/Developer/usage`, captured on October 12, 2026. `SHA256SUMS` records their contents. They are reference sources, not a second compiled implementation.

`Sources/UsageKit` compiles the original provider, HTTP, Keychain, CLI, normalization, and cache implementations. The registry's `fetchAll` and the store's `refreshFromUsage` contain the original fetch and refresh bodies. `OriginalUsageSourceTests` compares these with this baseline, removing only macOS availability annotations and the documented private-profile environment guard.

The Argus boundary retains:

- Argus-owned configuration, profile directories, credential names, and protection against deleting the standalone app's keys.
- UT Browser routing and remote-client login handoff.
- Existing account metadata, Devin support, warnings, and dashboard presentation.
- One lifetime owner for the original initial refresh, interval loop, and presentation clock. Broker publishing does not schedule or gate that loop.
- A private-profile environment guard for integrations added after standalone Usage. Original providers retain their original subprocess environment.

There is no Argus HTTP cooldown coordinator, fetch-result coordinator, or credential-worker subprocess. Reintroducing alternate collection behavior requires an explicit decision; passing a fixture for one account is not a substitute for preserving the original implementation.
