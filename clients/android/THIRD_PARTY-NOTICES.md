# Third-party code

## Termux terminal engine
`app/src/main/java/com/termux/{terminal,view}/**` is vendored from
[termux/termux-app](https://github.com/termux/termux-app) (Apache License 2.0).

Modifications by this project:
- `JNI.java` replaced with a no-op stub (we render remote sessions, never spawn a
  local subprocess — which also avoids the Android-12 phantom-process killer).
- `TerminalSession.java` given a "remote" mode: I/O is bridged to a broker over a
  WebSocket instead of a local PTY; output is appended directly to the emulator on
  the main thread.
