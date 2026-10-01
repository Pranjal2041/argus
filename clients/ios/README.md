# Argus for iPhone

A native SwiftUI + SwiftTerm client for Argus brokers.

- **Command Center** — every foreground session across your machines, grouped
  *Needs you / Working / Done & idle*, with the Mac's model summaries (`/ccstatus`).
- **Machines** — sessions per machine; create (＋) and kill (swipe).
- **Terminal** — live tmux over the broker WebSocket, pinned to the pane's
  authoritative grid, with SwiftTerm's esc/ctrl/tab/arrow key bar.

## Networking

The iPhone joins your tailnet through the **Tailscale iOS app** (DESIGN.md's iOS
plan: rely on the system Tailscale app, don't embed tsnet). Enter your Mac's
tailnet name or 100.x address once; Argus asks that broker for `/mesh/peers` —
as the macOS app asks its local broker — and dials each broker directly
(https brokers by MagicDNS name for TLS, http brokers by tailnet IP).

## Build

```sh
brew install xcodegen
cd clients/ios
ARGUS_IOS_TEAM=<your Apple team id> xcodegen generate
open ArgusiOS.xcodeproj          # pick your iPhone and Run
```

SwiftTerm needs Xcode's Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`).

## Tests

```sh
xcodebuild test -project ArgusiOS.xcodeproj -scheme Argus \
  -destination 'platform=iOS Simulator,name=<simulator>' -only-testing:ArgusTests
```

`ArgusUITests` drives a live fleet end to end (open a session, type, read the
reply). It is skipped unless `ARGUS_UITEST_HUB` names a reachable hub broker
when the project is generated.

## App Store submission

- **Review access:** Argus needs a private tailnet, so App Review uses the
  built-in demo. Review notes: *"Tap **Explore the demo** on the first screen.
  It is a self-contained sample fleet (no account or network needed): open a
  session, swipe a card for Quick Reply, try the Lab inbox and Files."*
- **Privacy:** `Resources/PrivacyInfo.xcprivacy` declares no tracking and no
  collected data — every request goes to brokers on the user's own tailnet.
  Required-reason APIs: UserDefaults (CA92.1), file timestamps in the app's
  own cache (C617.1). App Store privacy label: *Data Not Collected*.
- **Encryption:** only Apple's TLS (HTTPS/WSS) — `ITSAppUsesNonExemptEncryption = NO`.
- **App Transport Security:** `NSAllowsArbitraryLoads` is required because Mac
  brokers serve plain HTTP on their 100.x tailnet address; the WireGuard tunnel
  is the transport security. Explain this in the review notes if asked.
- **Background:** `fetch` (BGAppRefresh) checks for agents waiting on the user;
  notifications are local only (no push server).
- **Still needed in App Store Connect:** a privacy-policy URL, screenshots
  (6.7" and 6.5" iPhone; iPad if keeping the iPad target), and a Release
  archive signed with a distribution certificate.
