# FlowDroid

An n8n-style workflow automation app that runs entirely on an Android phone.
You connect triggers, logic and actions on a canvas. Workflows run on the
device, with no server.

The workflow engine is written in Rust. It was ported from a TypeScript
reference implementation with [rust-anything](https://github.com/erkamyaman/rust-anything),
which recorded what the TypeScript does and checks that the Rust matches it on
every recorded case.

## Features

| Area | What you get |
| --- | --- |
| Editor | Pannable, zoomable canvas; drag nodes; tap an output dot, then a node, to connect; per-node sheet with Input, Parameters and Output tabs; live `{{ }}` expression preview against the last run's data |
| Mapping | Tap a value in the Input tab (or the braces button on any field) to insert it as an expression; `$json.` / `$node["X"].json.` autocomplete field names from real data; snippets for common expressions |
| JSON | Foldable tree with indent guides, colored JSON text, table view for lists of objects, full-screen viewer with search, copy value or expression on long-press; syntax highlighting in expression, JSON and code fields; Format JSON (keeps `{{ }}`) |
| Pickers | No typing what you can't know: installed-app picker with icons for the Notification Trigger (recent senders first), contact picker for SMS numbers and email addresses, "use where I am now" for Place, cron presets with a plain-English description and the next run times, date/time picker for Calendar, model suggestions per AI provider, IDs taken from pasted Google/Notion/Airtable links, field names from the incoming data, "find my chats" for Telegram, FlowDroid's files; steps that need a permission say so with an Allow button |
| Files | Files travel between steps as references `{path, name, mimeType, size}` in FlowDroid's folder (any type). Share Trigger: one item per shared file, text files read into `fileText`/`text`. HTTP Request: send a file as the body, save a response as a file. Telegram/Discord: send photos and documents. Send Email: attachments. Google Drive: upload/download any file. AI Chat: look at an image. Extract Text: PDF (pdftotext in Ubuntu, installed on first use), Word .docx, HTML, Markdown, CSV, JSON, plain text. Output tab: file cards with image previews, tap to open, Share |
| HTTP | Import a cURL command (as a new step or into an HTTP Request), copy a request as cURL |
| Triggers | Manual, Schedule (every few minutes, or a calendar picker for hourly/daily/weekly/monthly with weekday and day-of-month choices; cron under Advanced; times follow the phone's 12/24-hour setting), Webhook (port 5678, optional key), Telegram, SMS, Notification (any app), Phone event (power, Wi-Fi, screen, battery low, boot), Place (arrive/leave), Share (from any app), Quick Settings tile, RSS, Email (IMAP), Called by a workflow, Error, Calendar Event (minutes before an event starts or after it ends, filtered by calendar and title), MCP Tool (the workflow becomes a tool on FlowDroid's MCP server at `/mcp` on the webhook port, for Claude Code or any MCP client; optional key per tool) |
| Flow | If, Filter, Switch, Merge (append / pair by index / choose branch), Loop Over Items (batches), Execute Workflow (sub-workflows), Wait, No Op, Respond to Webhook |
| Data | Edit Fields (Set), Code (JavaScript or Python, run in the built-in Ubuntu), Split Out, Aggregate, Sort, Remove Duplicates, Limit |
| Network | HTTP Request (API key, bearer, basic or OAuth2 sign-in; headers, JSON or text body, full response, ignore 4xx/5xx, timeout), RSS Read |
| Knowledge (RAG) | Add to Knowledge Base (chunks text with overlap; re-adding a source replaces it), Search Knowledge Base (best chunks plus a ready `context` for an AI step), Knowledge Base Info (list, sources, delete). Search by words offline with no key (BM25), or by meaning with OpenAI, Gemini or OpenAI-compatible (Ollama) embeddings. Stored on the phone; Settings → Knowledge bases to browse, try a question and delete. Templates: “Save shared text to my notes” and “Ask my notes” |
| AI | AI Agent: Claude with tools (web APIs, shell commands, other workflows, phone tables, web search, and every tool of an MCP server), looping until it answers; or Claude Code in the built-in Ubuntu with your own Claude plan (no API key): read-only, edit or shell access, a working folder, its own MCP servers (a server can name a saved credential instead of holding keys), a step limit, and a conversation key that continues the same session across runs. AI Chat: Claude (Anthropic), OpenAI, Gemini, any OpenAI-compatible server (Ollama, OpenRouter, …) or Claude Code; optional JSON replies. MCP Client: call a tool, read a resource or get a prompt (or list them) from any MCP server, on the web (Streamable HTTP, with API key, bearer, basic or OAuth2 sign-in), as a command run in Ubuntu (stdio), or a saved MCP server; "Find tools" lists what the server offers and fills in the arguments; sessions stay open between items |
| Communication | Telegram send, Discord (webhook or bot), Send Email (SMTP), Send SMS |
| Databases | Supabase (select / insert / update / delete), Airtable, Notion, Phone Table (rows stored on the phone, no account) |
| Productivity | Google Sheets (read / append), Gmail (send), Google Calendar (create event), Google Drive (list / upload / download), via Google sign-in |
| System | Files (read, write, list, delete in FlowDroid's folder, also /root/files in Ubuntu), Execute Command on the phone's shell or in a built-in Ubuntu 24.04 (proot, no other app or root; `apt` works); Terminal screen in Settings is a real terminal (pty): programs can ask y/n, passwords and menus, with a key bar for Esc, Tab, Ctrl, arrows and Ctrl+C; it installs Ubuntu (step list, percent, MB, speed and time left) and shows output live; the Code node shows Node.js or Python install progress over the canvas |
| Credentials | API keys and tokens in Android's encrypted storage (including saved MCP servers: a URL with its sign-in header, or a command with its environment); nodes refer to them by name and the host fills them in at send time, so secrets never enter the engine or run history |
| Android | Phone Calendar (list events, find free time within working hours, add events, in any calendar the phone syncs), Ask Me (a notification with up to 3 buttons and/or a reply box; the workflow waits for the answer), Speech to Text (Android's speech box on screen, the microphone in the background), Sound Mode (silent, vibrate, normal, Do Not Disturb levels; returns the previous mode to restore later), Contacts (find by name or number, add), Alarm & Timer (through the phone's clock app), Photo & Scan (camera, gallery picker, Google's document scanner with a PDF), Show Notification, Speak Text (phone voices with a picker and samples, or OpenAI `gpt-4o-mini-tts` and ElevenLabs voices with speaking style and speed; cloud audio is cached), Vibrate, Open URL, Copy to / Read Clipboard, Battery Status, Get Location |
| Expressions | `$json`, `$node["Name"].json`, `$items`, `$index`, `$vars`, `$now`, `$workflow`; operators, ternary, `??`; string, list, `Math` and `JSON` helpers |
| Background | Foreground service with boot/update restart, wake lock and battery-optimization exemption. If the phone stops it anyway: an incoming SMS, notification or phone event restarts it, an exact wake-up alarm fires for the next schedule (and every 15 min as a watchdog), and WorkManager restarts it too. Background setup screen: Android checks, the live, community-kept steps for the phone's maker from dontkillmyapp.com (cached for offline; a short built-in version as fallback) with a button to the maker's launch manager, and a log of when the phone paused FlowDroid |
| Runs | Run this step: tests one step on the output its earlier steps produced last time (or their pinned data), without running them again; `$node["…"]` references keep working; not saved to history. Per-node output and errors on the canvas, live step count while running, pinned test data (from a run, or typed as JSON), retry on fail, error workflows, execution history (last 50 per workflow), "continue on fail", disabled nodes |
| Editing | Undo and redo, tidy up, home-screen shortcut per workflow |
| Sharing | Copy a workflow as JSON, import FlowDroid or n8n JSON from the clipboard, encrypted backup and restore, nine starter templates |

## Icons

The app's icons are its own: drawn in `scripts/icons/build_icons.py` on a
24-unit grid with a 1.6 stroke and a small filled "port dot", then built into
`app/assets/fonts/FlowIcons.ttf` and `app/lib/ui/icons.dart` with `make icons`.
The launcher and status-bar icons use the same mark.

## Layout

```
engine-ts/            TypeScript reference engine (the spec), with tests and a case generator
core/
  flowcore-engine/    The Rust engine: expressions, cron, node types, executor (no unsafe, no bindings)
  flowcore/           rust-anything bridge crate: recordings (cases.jsonl) and the diff/gate proof
  flowcore-ffi/       C ABI (flowcore_call / flowcore_free) that the app loads with dart:ffi
app/                  Flutter Android app
  lib/core/           FFI binding and models
  lib/runtime/        Runner, device effects, scheduler, webhook server, WorkManager hook
  lib/data/           On-device storage (one JSON file per workflow and execution), templates
  lib/ui/             Home, canvas editor, node sheets, executions
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

## Background behavior of phone steps (tested on a device)

| Step | With FlowDroid closed |
| --- | --- |
| Show Notification, Speak, Battery, Send SMS | Work |
| Vibrate | Works (vibrates as an alarm, the only kind Android allows from the background) |
| Open URL | Shows a "Tap to open" notification, or opens directly if "Display over other apps" is allowed (Background setup) |
| Copy to Clipboard | Works |
| Read Clipboard | Fails with a clear message: Android only lets the app on screen read the clipboard |
| Get Location, Place Trigger | Need location "Allow all the time"; without it the step fails with a clear message; 30 s limit, then the last known position (`stale: true`) |
| Notification Trigger | One run per notification; re-posted old notifications are ignored; text Android hides as sensitive arrives with `hidden: true` |
| Phone Event Trigger | Charger, screen and Wi-Fi changes each run once |

No phone step can hang a run: each has a time limit and fails with a clear error.

## Known limits

- **Keep running** (Settings) starts a foreground service. It owns the webhook
  server and checks schedules every minute, survives the app being swiped away,
  app updates, reboots and Doze, and shows a permanent notification. Tested on
  an Android 15 emulator. With it off, webhooks work only while the app is
  open, and schedules fall back to WorkManager (about every 15 minutes).
- Some phone brands add their own app killers on top of Android's. If
  workflows stop in the background on yours, allow "autostart" or set the app's
  battery setting to "Unrestricted".
- Webhooks have no authentication. Any device on the same network can call an
  active webhook workflow. Use hard-to-guess paths, and don't activate webhook
  workflows on untrusted Wi-Fi.
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
