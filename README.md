# FlowDroid

Automations that run on your Android phone. No server, no subscription.

You build a workflow by connecting steps on a canvas. The first step waits
for something to happen. The steps after it do things.

## Examples

- At 7 a.m., read out the weather and today's calendar.
- When a text from your bank arrives, forward it to Telegram.
- Switch to vibrate when you get to work.
- Share a PDF to the app and ask questions about it later.
- Check a website every hour and tell you when something changes.

## What it can do

- **Start on:** a schedule, a text, a notification, a place, a calendar event, a web request, a shared file
- **Phone:** notifications, speech, alarms, contacts, camera, location, sound mode
- **Services:** any web API, Telegram, Discord, email, Google, Notion, Airtable, Supabase
- **AI:** Claude, OpenAI, Gemini or a local model, plus your own searchable notes
- **Websites:** a built-in browser that clicks, types and reads pages for you
- **Code:** JavaScript, Python, shell commands and a full Ubuntu inside the app

A built-in assistant can also build the workflow for you from a plain description.

Full list: [docs/features.md](docs/features.md)

## Why on the phone

- **Private.** Your data and passwords stay on the device.
- **Free.** Nothing to host or pay for.
- **Closer.** It can read texts, know where you are and buzz your pocket.
- **Always on.** It keeps running in the background and after restarts.

## Get started

Build the APK and install it on your phone:

```sh
make apk
```

Then tap **New workflow**, add steps, tap **Run** to test, and switch it on.

Build tools and details: [docs/development.md](docs/development.md)

## Good to know

- Android only.
- Early software, so back up your workflows.
- Some phone brands stop background apps. The app shows how to prevent it.
- Give webhooks a key and turn them off on public Wi-Fi.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report security problems privately as described in [SECURITY.md](SECURITY.md).

## License

MIT
