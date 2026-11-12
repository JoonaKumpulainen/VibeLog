# Log sharing: test logs sorted by phone, without knowing who sent them

Agreed on 2026-11-12. Testers' phones send their test logs to a small service on the owner's
Cloudflare account, and the owner's computer pulls them, sorted by phone model. It's how the
friends' 15 Pro, 16 Pro and 17 Pro can send benchmark, probe and take results without anyone
asking for files, which [per-phone-fitting.md](per-phone-fitting.md) depends on.

## What the tester controls

- **Off until turned on,** in Settings, **Advanced**, **Diagnostics**, **Log sharing**, after a
  confirmation that says what goes. It also needs an invite code from the owner.
- **Gyro logs** have their own switch, off: they describe how the phone moved.
- **Use mobile data**, off: lets uploads go over cellular and hotspots too.
- **New anonymous ID** starts afresh, so what was sent can't be linked to what's sent next.
- Turning it off stops everything from then on.

## What goes, and when

- Session logs, `exports.csv`, take sidecars (`.mov.json`), probe and test reports, lens
  profiles, `capture_support.json`, `encoder_support.json` and `benchmarks.csv`. Files over
  1.5 MB are left out. Never videos, stills, previews or RAW clips.
- Only files new or grown since the last upload, in batches under 2.5 MB.
- Thirty seconds after launch and on leaving the app, never during a take. On Wi-Fi only,
  unless the tester turns on **Use mobile data** (added on 2026-11-12 at the owner's request),
  which also allows a hotspot. Never in Low Data Mode.

## Anonymous

`LogSanitizer` in VLCore changes every file before it leaves the phone:

- Dates in names and text, such as `20261112_140255`, become a short code from the install's
  own salt, the same in every file, so a log still names its take's sidecar.
- Full dates, such as a lens profile's measurement time, become `<date>`.
- Web and network addresses, such as the test link's server or a tunnel, become `<address>`.
- A gyro log's Unix time becomes 0.
- Names the owner typed, of LUTs, presets and styles, become `<name 1>` and on, whole words of
  four letters or more.
- The phone is known by its model, iOS and app version, and a random install ID.

What stays: settings, frame counts, heat, errors and times of day. The service sees each
request's IP address, as every web server does, and stores nothing but what the app sent.

## The service

`tools/log_service`, a Cloudflare Worker with Workers KV, on the free plan. `POST /upload` takes
an upload with an invite code, after checking the model, versions, ID, file names (text kinds
only) and sizes, and at most ten uploads a minute per install. `/list`, `/get` and `/delete` are
for the owner's key only. Uploads are kept until the owner deletes them.

The invite codes and the owner's key are secrets on the Worker, never in the repo or the app.
The owner's computer keeps its key in `~/.vibelog_logs`.

`python3 tools/pull_logs.py` fetches new uploads into `<results folder>/phones/<model>/<iOS>/
<app>/<install>/` and writes `phones/report.md`, one section per phone model. `--delete` removes
each upload from the service once it's saved.

## Removing it

Delete `App/LogUploader.swift`, `Modules/VLCore/LogSharing.swift`, `LogSharingSection` in
`App/DiagnosticsView.swift` with its line in the form, `logUploader`, `privateNames`,
`shareLogs` and their two calls in `App/AppModel.swift`, `LogSharingTests`, `tools/log_service`
and `tools/pull_logs.py`. Delete the Worker with `cf workers delete vibelog-logs` and its KV
namespace in the Cloudflare dashboard.
