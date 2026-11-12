# Test link: privacy, the server and removing it

The test link lets a computer you control run tests on the phone: change settings, start takes and
collect logs. It's a developer tool. You don't need it to record, and nothing in the camera depends
on it.

This guide covers what it sends, how to run the server, how to keep it private, and how to remove it
from the app completely.

## The short version

- The link is off at every launch, and only you can turn it on, in Diagnostics. The server can't
  turn it on.
- If you never turn it on, the app sends nothing through it. There are no accounts or analytics.
  The only other network code is **Log sharing**, also off until you turn it on: see
  [decisions/log-service.md](decisions/log-service.md).
- For full privacy, you can leave it off, deny Local Network permission or build the app without it.

## What the link can do

The phone connects out to the server, and the app opens no port of its own. Once connected, the
server can use only the commands in `App/TestCommands.swift`:

| It can | It can't |
|---|---|
| Read the app's status | Delete takes or any other file |
| Change capture, format, exposure, white balance, focus and viewfinder settings | Change settings during a take, other than tools, look and punch-in |
| Start and stop takes and the stream, including RAW clips | Turn the link on, or stay connected after the app restarts |
| Run the control test, the encoder test and both probes, some of which capture test pictures | Reach files outside `videos/`, `logs/`, `probes/`, `clips/` and `stills/` |
| Export a take with a look, which writes a new `_look.mov`, or `_look2.mov` and on, beside it | Export during a take |
| List files in those folders and fetch them | Watch the viewfinder live |
| Apply and save presets, and set the default | Delete presets |
| Take a picture of what the camera sees while no take is running, and fetch it | Fetch a picture during a take |

A take started by the server records video and sound like any other, and the server can then fetch
it. It can also ask for a still of the scene at any moment outside a take, without any sign on the
phone. Only turn the link on when you're happy for your computer to do that.

## What leaves the phone

Data only goes to the server you entered, and only while **Connect** is on.

| Data | When it's sent | What's in it |
|---|---|---|
| Status replies | On each command | Lens, format, exposure, white balance, focus and tools, which screen is open, preset names, LUT name, frame rate, heat, battery, free storage, the last take's result |
| File lists | When the server asks | The names of files in those five folders, which include the date and time of each take |
| Session log | After each take with **Send logs and sidecars** on, or whenever the server asks | Phone model, iOS version, camera settings, battery, heat, free storage, errors, take names and times |
| Sidecars (`.json`) | After each take, with **Send logs and sidecars** on | The take's format, settings and frame counts |
| Gyro logs (`.gcsv`) | After each take, with **Send gyro and timing files** on, or by name | How the phone moved during the take |
| Capture timing (`.timing.csv`) | After each take, with the same switch on, if **Log capture timing** is on | Timing of each frame request |
| Preview pictures and saved stills | Only when the server asks | What the camera sees at that moment |
| RAW clip references | Only when the server asks | One RAW frame of the newest clip, and its metadata |
| Videos and any other listed file | Only when the server asks for one by name | The full video and its sound |

No location is sent, because the app doesn't record it. Video files can still hold whatever the
camera saw and the microphone heard.

Turning off the two **Send** switches stops the automatic files. It doesn't stop the server asking
for a file by name, or for a log, preview or status, so turn off **Connect** if you don't want that.

Traffic is **plain HTTP**. The token controls who may connect, but nothing is encrypted, so anyone
able to watch your network could read the token and the data. That's why it belongs on a network you
trust. The one exception is a phone elsewhere through a tunnel: see **A phone elsewhere, through
ngrok** below.

## What stays on each device

- **Phone:** the server address and token stay in `VibeLog.config.json` in the VibeLog folder, as
  plain text. They can be read in the Files app, and they go into any phone backup.
- **Computer:** the results folder holds everything received, including previews and any fetched
  videos, plus the token, `replies.jsonl`, which is a log of every reply, including status, and each
  suite's `suite_*.csv` and `heat_*.csv`. It stays there until you delete it.

Nothing is sent to the VibeLog project or to anyone else.

## Running the server

It needs Python 3 and nothing else. These commands run from the repository's folder.

### Start it

```bash
python3 tools/test_server.py serve
```

It prints the address and token to enter in the app, and where files go. The token is six random
digits, kept in a `token` file in the results folder. That folder is `~/VibeLogTest` unless you set
another: put its path in `~/.vibelog_test_folder`, set `VIBELOG_TEST_FOLDER`, or pass `--folder`
before `serve`. Videos are large, so choose a drive with room. The server refuses a file that would
leave under 2 GB free.

### Connect the phone

1. In Settings, open **Advanced**, then **Diagnostics**.
2. Under **Test link**, enter the server address and token, then turn on **Connect**.
3. Allow Local Network if iOS asks.

The state line shows what happened:

| State | Meaning |
|---|---|
| **Connected** | It's working |
| **Waiting for the server** | The phone can't reach the computer: check the server, firewall, Wi-Fi and Local Network permission |
| **Token refused** | The token is wrong. Retype it, then turn **Connect** off and on |
| **Needs a server and a token** | A field is empty or the address is invalid |

The server prints `phone connected` when the phone reaches it, and `refused a wrong token` on a bad
token.

If a firewall blocks the phone on Linux with `ufw`, allow only your own network, changing the range
to match yours:

```bash
sudo ufw allow from 192.168.1.0/24 to any port 8765 proto tcp
```

### Send commands

```bash
python3 tools/test_server.py send status
```

```bash
python3 tools/test_server.py send set lens 0.5x
```

```bash
python3 tools/test_server.py send set tools peaking,grid
```

A setting's name and value go as two arguments. Settings added in November 2026 include
`hdrViewfinder`, `fineLookLUT`, `vignetteCorrection` and `bakeEffects`, all `true` or `false`.

```bash
python3 tools/test_server.py send record 20 --wait
```

Other commands:

| Command | What it does |
|---|---|
| `stop` | Ends the take |
| `stream on`, `stream off` | Starts or stops the camera, to save heat between takes |
| `focusAt 0.5,0.5` | Focuses and meters at a point |
| `applyPreset <name>`, `savePreset <name>`, `defaultPreset <name or none>` | Manage presets |
| `resetSettings` | Returns every setting to the app's own, keeping presets and the link |
| `controlTest`, `encoderTest`, `probe`, `costTest` | Run the Diagnostics tests |
| `measureLenses` | Saves this phone's lens profiles, as **Measure Lenses** does, and their Gyroflow profiles, `gyroflow-*.json`; `listFiles` and `sendFile` reach them |
| `sendPreview` | Sends a small JPEG of the scene |
| `saveStill`, `sendStill` | Saves a full still, and sends the newest one |
| `sendReference` | Sends the newest RAW clip's reference frame and metadata |
| `sendLog`, `listFiles`, `sendFile <name>` | Fetch logs and files |
| `export [file] [look=ACES 2.0;target=sdr;codec=hevc420]` | Bakes a take, the newest in log unless named. `look` is `monitor` or a look's name, `target` is `sdr`, `pq` or `hlg`, `codec` is `hevc420`, `prores422lt`, `prores422` or `prores422hq`, `size` is HEVC's `master`, `high` or `share`, `resolution` is `full`, `medium` (2880 wide) or `small` (1920 wide), `stabilize` is `on` or `off` with `smooth` its seconds, and with it on a baked take can be named, `crop` is `none`, `wide` (16:9) or `tall` (9:16) as the take plays, and `effects` is `none` or names and values such as `halation:1,bloom:0.5`. `log` writes log instead of a look, as `S-Log3` or `S-Log3/S-Gamut3`, and `shift` moves a crop, -1 to 1 across what it leaves out. Status reports `exporting`, `exports` and `lastExport` |
| `cancelExport` | Stops that export |

Every export, from the screen or the link, logs which step it stopped in and adds a row to
`logs/exports.csv`, which `sendFile exports.csv` fetches.

A suite runs a list of takes and cooling breaks from a JSON file, and writes `suite_*.csv` and
`heat_*.csv` to the results folder. It refuses to start unless the phone is on the camera screen
with room for its takes:

```bash
python3 tools/test_server.py suite tools/suites/ultra_wide.json
```

The export matrix records 2 seconds in every curve and gamut the app allows, 43 in all, and exports
each take with ACES 2.0 on its own. It comes in two parts, so neither fills the phone or runs too
long. Each part first cools the phone to nominal heat, and a failed export is written to
`exports_*.csv` and the suite moves on. At the end the phone sends its session log and
`exports.csv`:

```bash
python3 tools/test_server.py suite tools/suites/export_matrix_1.json
```

```bash
python3 tools/test_server.py suite tools/suites/export_matrix_2.json
```

Part 1 covers Apple Log, Apple Log 2, S-Log3 and S-Log2, and part 2 covers LogC3, LogC4 and Canon
Log 3. Between parts, delete the takes in the library if the phone is short of room.

### Rounds: tests that check themselves

A round is a suite that also judges its results, fetches what it needs, runs the analysis tools
and puts back every setting it changed, even after a failure. It writes `round_*.md` in the
results folder: each check as PASS or FAIL with its figure, the questions left for a person, and
the tools' reports. A round needs 0.1.117 or later, which reports its version and newest take.

```bash
python3 tools/test_server.py round tools/rounds/2026-11-13.json
```

Steps that need a person, such as pointing the phone at a scene or walking with it, wait for
Enter on this computer. With `--go`, they count down 5 seconds instead, for a test whose phone
is already set up, such as one lying still: `round --go tools/rounds/<plan>.json`. The step types are listed in the `Suite` class in `tools/test_server.py`.
The analysis tools also run on their own:

```bash
python3 tools/measure_steady.py ~/VibeLogTest/video_20261112_140255.mov --copy ~/VibeLogTest/video_20261112_140255_look.mov
```

```bash
python3 tools/read_log.py ~/VibeLogTest/session_20261112_134734.log
```

`send status` also reports which screen is open and why the camera is busy. A wrong setting replies
with the values it accepts. `send` and `suite` only work from the computer running the server.

### Stop it

Press Ctrl+C in its terminal. The phone then shows **Waiting for the server** until you turn off
**Connect**.

## A phone elsewhere, through ngrok

For a short session with a tester's phone that isn't on your network. ngrok gives the server a
public `https://` address and passes requests to it. Run it only while testing, and stop both
afterward.

### What changes, and the risks

- **Anyone with the address and the token** can do everything in **What the link can do**:
  change settings, start takes, take stills of whatever the phone sees with no sign on it, and
  fetch videos. So the token is long, and the address and token go only to the tester.
- **ngrok can see everything that passes.** HTTPS ends on ngrok's servers, so videos, stills,
  logs and status pass through them unencrypted. The tester should know this before connecting.
- **The address is public.** Tunnel addresses appear in public certificate logs and get scanned.
  Public mode refuses anything without the long token and locks out a sender after five wrong ones.

### What public mode does

`serve --public`:

- **Listens on this computer only,** `127.0.0.1`, since ngrok's agent connects from here. Nothing
  on your network can reach it.
- **Gives the tunnel its own token,** 32 random characters in `public_token` in the results folder.
  A request through the tunnel needs it; the six-digit token then only works from this computer.
- **Refuses commands and replies through the tunnel.** Queuing a command and reading a reply only
  work from this computer. ngrok's requests arrive from `127.0.0.1` too, so the server tells them
  apart by the `X-Forwarded-For` header ngrok adds.
- **Locks out a sender for 15 minutes after five wrong tokens,** by the address ngrok reports.
- The phone sends `ngrok-skip-browser-warning`, so ngrok's free tier doesn't put its warning page
  in front of the server.

**Over the internet** in Diagnostics is its own switch, from 0.1.116 on. Off, the link only takes a
plain address on your network; on, it only takes an `https://` address, so neither reaches the
wrong place by mistake. Like **Connect**, it's off at every launch, kept out of presets, and the
server can't turn it on. Switching it disconnects. 0.1.115 took `https://` addresses without the
switch; older builds only take plain HTTP.

### Run it

1. Start the server in public mode:

   ```bash
   python3 tools/test_server.py serve --public
   ```

   It prints the long token.

2. In a second terminal, start the tunnel:

   ```bash
   ngrok http 8765
   ```

   It prints a `Forwarding` address such as `https://abc-123.ngrok-free.app`.

3. Send the tester the address and the token, privately. In Diagnostics, they turn on **Over
   the internet**, enter the whole `https://` address as the server and the token, and turn on
   **Connect**. The state should read
   **Connected**, and the server prints `phone connected`.

4. Send commands from this computer as usual, `python3 tools/test_server.py send status`.

### End it

1. Ask the tester to turn off **Connect** and **Over the internet**, and clear the server and
   token fields.
2. Press Ctrl+C in both terminals: ngrok's first, then the server's.
3. Delete `public_token` from the results folder, so the next session gets a new one:

   ```bash
   rm ~/VibeLogTest/public_token
   ```

## Keeping it private

From least to most effort:

1. **Connect only when testing.** Turn **Connect** off and stop the server when you finish.
   Restarting the app also turns it off.
2. **Never expose the server to the internet** except through public mode and a tunnel, above.
   Don't forward port 8765 on your router, and don't run it on public or shared Wi-Fi.
3. **Listen on one address only.** By default the server listens on every network the computer has.
   Name the one you want:

   ```bash
   python3 tools/test_server.py serve --bind 192.168.1.20
   ```

4. **Replace the token.** Six digits are easy to type and easy to guess, so they only suit a network
   you trust. For a longer one, stop the server, write your own to the file and restart it:

   ```bash
   python3 -c "import secrets; print(secrets.token_urlsafe(24))" > ~/VibeLogTest/token
   ```

5. **Send less.** Turn off both **Send** switches, and leave **Log capture timing** off.
6. **Encrypt the connection.** Plain HTTP can't be made private on an untrusted network. A private
   VPN between the phone and computer encrypts the traffic: run the server with `--bind` on the
   computer's VPN address and enter that address in the app. This setup hasn't been tested.
7. **Deny the permission.** iOS Settings > Privacy & Security > Local Network > VibeLog, turned off,
   stops the app reaching local devices at all. It hasn't been tested on a VPN address.

## Erasing what it left behind

**On the phone:** clear the server and token fields in Diagnostics, or edit `VibeLog.config.json` in
the Files app and empty `testServer` and `testToken`. Use a new token afterward if you ever reuse
the server.

**On the computer:** stop the server, then delete its folder. If you chose another one, delete that
too:

```bash
rm -rf ~/VibeLogTest ~/.vibelog_test_folder
```

If you opened the firewall, close it again with the same rule:

```bash
sudo ufw delete allow from 192.168.1.0/24 to any port 8765 proto tcp
```

## Removing only the internet link

This keeps the test link on your own network and takes out everything that reaches a server over
the internet. Find each item by name.

1. **App, `App/DiagnosticsView.swift`:** delete the **Over the internet** toggle, and keep only the
   local wording of the server field's placeholder and the footer.
2. **App, `App/AppModel.swift`:** delete `testOverInternet` and its comment.
3. **App, `App/TestCommands.swift`:** in `updateTestLink`, call `TestLinkAddress.base(testServer)`
   without `overInternet`, set the state to "Needs a server and a token" on failure as before,
   delete the "connecting over the internet" log line, and call `testLink.start(base:token:)`
   without `overInternet`.
4. **App, `App/TestLink.swift`:** delete the `overInternet` property, the parameter of `start`,
   and the `ngrok-skip-browser-warning` line.
5. **`Modules/VLCore/TestLinkMessages.swift`:** in `base`, delete the `overInternet` parameter and
   the `secure` checks, so only plain addresses are taken.
6. **`Tests/VLTests/VLTests.swift`:** delete the five `overInternet` and `https` lines from the
   address test.
7. **Server, `tools/test_server.py`:** delete the `--public` argument, `public_token_for`, the
   public branch of `serve`, `public_token` on `Link`, and `"public_token"` from `safe_name`. Keep
   the forwarded-header and lockout checks: they cost nothing and still guard a local server.
8. **Docs:** delete **A phone elsewhere, through ngrok** from this file, its pointers in
   `docs/status.md` and `docs/next-tests.md`, and the line in `docs/how-it-works.md`.

## Removing it from the app completely

This builds an app with no network code and no Local Network permission. Recording doesn't use any
of it. Line numbers change, so find each item by name.

### 1. Delete these files

```bash
git rm -r App/TestLink.swift App/TestCommands.swift Modules/VLCore/TestLinkMessages.swift tools/test_server.py tools/suites
```

### 2. Remove the permission

In `project.yml`, delete these lines:

```yaml
NSLocalNetworkUsageDescription: The test link in Diagnostics talks to your own computer.
NSAppTransportSecurity:
  NSAllowsLocalNetworking: true
```

### 3. Remove the saved settings

In `Modules/VLCore/AppConfig.swift`, delete:

```swift
/// Where the test link connects. It's never switched on from here.
public var testServer = ""
public var testToken = ""
```

```swift
testServer = read(.testServer, defaults.testServer)
testToken = read(.testToken, defaults.testToken)
```

An older config file that still has these keys keeps working, and they're dropped the next time the
app saves.

### 4. Remove it from `App/AppModel.swift`

Delete these properties:

```swift
/// Where the test link connects, kept between launches. The link itself never is.
@Published var testServer = ""
@Published var testToken = ""
@Published var testLinkOn = false { didSet { if testLinkOn != oldValue { updateTestLink() } } }
@Published var testOverInternet = false { ... }
@Published var testLinkState = "Off"
@Published var testSendsResults = true
@Published var testSendsGyro = true
let testLink = TestLink()
/// Bakes the takes the test link asks for, one at a time. Only touched on the main thread.
private(set) lazy var testExport: LookExportJob = MainActor.assumeIsolated { LookExportJob() }
```

```swift
/// One take's length, instead of the owner's **Stop after**.
private var takeSeconds: Double?
```

```swift
/// Names the log the test link sends, so one session keeps one file.
let sessionStamp = Storage.timestamp()
```

In the `config` property and `loadConfig()`, delete:

```swift
config.testServer = testServer
config.testToken = testToken
```

```swift
testServer = loaded.testServer
testToken = loaded.testToken
```

Delete the whole `record(seconds:)` function, `diagnosticsClosed()` and `sendPreview()`, each with
its comment.

Delete the `openScreen` property, with its comment, and the three lines that set it in
`settingsOpened()`, `settingsClosed()` and `diagnosticsOpened()`.

In `saveCaptureTiming(for:)`, delete `self.sendTimingFile(url)`.

Delete `takeSeconds = nil` after the `Recording ... for ...` log line in `startRecording()`, and
restore `rawDumpSeconds`:

```swift
private var rawDumpSeconds: Double { recordSeconds > 0 ? recordSeconds : 3600 }
```

In `startEncoding()`, delete `testLink.holdFiles(true)`, and replace these two lines:

```swift
let seconds = takeSeconds ?? recordSeconds
takeSeconds = nil
```

with:

```swift
let seconds = recordSeconds
```

In `stopEncoding(_:)`, delete these two lines:

```swift
sendTakeFiles(video: Storage.videos.appendingPathComponent(result.file))
testLink.holdFiles(false)
```

and replace this:

```swift
guard result.framesWritten > 0 else {
    testLink.holdFiles(false)
    return
}
```

with:

```swift
guard result.framesWritten > 0 else { return }
```

### 5. Remove the screen

In `App/DiagnosticsView.swift`, delete the whole `Section` whose header is `Text("Test link")`, and
the `.onDisappear { model.diagnosticsClosed() }` line.

In `Modules/VLProcessing/StillExporter.swift`, delete the `preview` function, which nothing uses
once the link is gone.

### 6. Remove its tests

In `Tests/VLTests/VLTests.swift`, delete the `TestLinkTests` class, and this line in
`testOlderFilesKeepThirtyFramesAndNoPresets`:

```swift
XCTAssertEqual(config.testServer, "")
```

### 7. Update the docs

Delete this file, and the **Test link** row in `docs/using.md`. In `AGENTS.md`, delete the
`tools/test_server.py` row and the test link's row in the docs table. In `docs/how-it-works.md`,
delete **Test link, for test sessions** and the **Test link** row under **What presets keep**, and
in `docs/status.md`, any test that needs the link.

### 8. Check nothing is left

This should print nothing:

```bash
grep -rnE 'testLink|TestLink|testServer|testToken|testSends|sessionStamp|TestCommand|TestReply|sendTakeFiles|sendTimingFile|sendPreview|updateTestLink|takeSeconds|testExport|openScreen|NSLocalNetwork|NSAllowsLocalNetworking' App Modules Tests project.yml
```

After also removing **Log sharing**, as [decisions/log-service.md](decisions/log-service.md)
says, this should print nothing too, which confirms the app has no network code left:

```bash
grep -rlE 'URLSession|URLRequest|NWConnection|NWListener|WebSocket' App Modules
```

Then build as usual. CI should pass, with 5 fewer tests. To check a finished build, this should
print `0`:

```bash
unzip -p VibeLog-unsigned.ipa 'Payload/*.app/Info.plist' | grep -ac NSLocalNetworkUsageDescription
```

The app's own **Share** button and the Files app still work, because iOS handles those, and they
only send what you choose. After installing, also clear the old server and token as described under
**Erasing what it left behind**.
