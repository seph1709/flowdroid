# Development guide

How FlowDroid is put together, how to build it, and the technical limits to
know about. For what the app does, see the [README](../README.md) and the
[feature list](features.md).

## Layout

```
engine-ts/            TypeScript reference engine (the spec), with tests and a case generator
core/
  flowcore-engine/    The Rust engine: expressions, cron, node types, executor (no unsafe, no bindings)
  flowcore/           rust-anything bridge crate: recordings (cases.jsonl) and the diff/gate proof
  flowcore-ffi/       C ABI (flowcore_call / flowcore_free) that the app loads with dart:ffi
app/                  Flutter Android app
  lib/core/           FFI binding and models
  lib/runtime/        Runner, device effects, scheduler, webhook server, browser driver, WorkManager hook
  lib/assistant/      The in-editor AI assistant and the tools it uses to edit workflows
  lib/data/           On-device storage (one JSON file per workflow and execution), templates
  lib/ui/             Home, canvas editor, node sheets, executions
  packages/phone_bridge/  Android plugin: phone actions, triggers, the in-app browser
scripts/              proot download, icon builder
docs/                 Feature list and this guide
```

## How a run works

The engine is a pure, deterministic state machine. Nodes that need the outside
world (HTTP, notifications, sensors, waits) don't perform anything themselves.
They return an **effect**, such as `{ "type": "http", "requests": [...] }`, and
the execution pauses. The Dart runner performs the effect with the matching
plugin and resumes the engine with the result. That split is why the whole
engine could be recorded and checked against the TypeScript reference: none of
its behavior depends on the network or the device.

## Build

Requirements: Node 22+, Rust (rustup) with the Android targets, `cargo-ndk`,
`rust-anything`, Flutter 3.50+, JDK 17, and the Android SDK (platform 37) and NDK.

```sh
make check          # TS tests, Rust fmt/clippy/tests, rust-anything proof, Flutter analyze/tests
make apk            # Rust for arm64-v8a, armeabi-v7a and x86_64, then the release APK
```

The APK is written to `app/build/app/outputs/flutter-apk/app-release.apk`.

## Changing the engine

1. Change the TypeScript in `engine-ts/src` and its tests.
2. Port the change to `core/flowcore-engine`.
3. Run `make port-verify`. It re-records the TypeScript behavior (generated
   edge cases, `scripts/gen-cases.ts` and the test suite), then runs
   `rust-anything diff` and `gate`. Every recorded case must match.

## Icons

The app's icons are its own: drawn in `scripts/icons/build_icons.py` on a
24-unit grid with a 1.6 stroke and a small filled "port dot", then built into
`app/assets/fonts/FlowIcons.ttf` and `app/lib/ui/icons.dart` with `make icons`.
The launcher and status-bar icons use the same mark.

## Known limits

- **Keep running** (Settings) starts a foreground service. It owns the webhook
  server and checks schedules every minute, survives the app being swiped away,
  app updates, reboots and Doze, and shows a permanent notification. Tested on
  an Android 15 emulator. With it off, webhooks work only while the app is
  open, and schedules fall back to WorkManager (about every 15 minutes).
- Some phone brands add their own app killers on top of Android's. If
  workflows stop in the background on yours, allow "autostart" or set the app's
  battery setting to "Unrestricted".
- A webhook without a key accepts any caller on the same network. Set a key on
  the Webhook trigger (and on MCP tools), use hard-to-guess paths, and don't
  leave webhook workflows active on untrusted Wi-Fi.
- Background schedules use WorkManager, so they fire at most every 15 minutes
  and may be late on battery saver. While the app is open, it checks every minute.
- Strings are UTF-8 in Rust. A `slice` that cuts an emoji in half yields U+FFFD.
  The reference defines it the same way. A JSON `\ud800` escape (a lone surrogate)
  becomes U+FFFD in Rust, but stays a lone surrogate in TypeScript.
- Phone triggers (SMS, notifications, phone events, tile, place) work while
  FlowDroid runs: turn on Keep running. Android delivers the events to
  FlowDroid's receivers, which queue them as files until a workflow engine
  picks them up. Notification access and "location all the time" are granted
  in Settings → Phone access.
- n8n import is best effort: node types FlowDroid has are mapped with their
  main parameters; others become No Op placeholders. Credentials must be
  chosen again, and n8n Code node scripts need adjusting (`items` / `item`
  instead of `$input` / `$json`).
- The AI Agent uses Claude's tool use (Anthropic credential). Each tool call
  is one round trip through the engine, so runs are fully recorded and
  survive the app pausing between steps.
- The built-in Ubuntu downloads about 30 MB on first use (Settings → Terminal)
  and runs through proot, which ships in the APK as `libproot.so`
  (`scripts/fetch-proot.sh`, pinned Termux packages). Each command runs on its
  own with no interactive TTY, so full-screen programs (vim, top) don't work.
  proot is slower than native Linux and can't run anything needing real root
  (mounting, kernel modules, systemd).
- Google nodes need your own Google Cloud OAuth clients (an Android client for
  `dev.flowdroid.flowdroid` with your signing SHA-1, plus a Web client whose ID
  goes in the credential). Sign in once in the app; background runs reuse it.
- The Telegram trigger polls only while FlowDroid runs (Keep running on, or the
  app open). A bot can have one poller, so don't also set a webhook on it.
- Speak Text and Get Location may not work from a background schedule. That
  depends on Android's background limits.
