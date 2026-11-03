# Test link: privacy, the server and removing it

The test link lets a computer you control run tests on the phone: change settings, start takes and collect logs. It's a developer tool. You don't need it to record, and nothing in the camera depends on it.

This guide covers what it sends, how to run the server, how to keep it private, and how to remove it from the app completely.

## The short version

- The link is off at every launch, and only you can turn it on, in Diagnostics. The server can't turn it on.
- If you never turn it on, the app sends nothing. There are no accounts, analytics or cloud services, and the test link is the only network code in the app.
- For full privacy, you can leave it off, deny Local Network permission or build the app without it.

## What the link can do

The phone connects out to the server, and the app opens no port of its own. Once connected, the server can use only the commands in `App/TestCommands.swift`:

| It can | It can't |
|---|---|
| Read the app's status | Delete takes or any other file |
| Change capture, format, exposure, white balance, focus and viewfinder settings | Change settings during a take, other than tools, look and punch-in |
| Start and stop takes and the stream, including RAW clips | Turn the link on, or stay connected after the app restarts |
| Run the control test, the encoder test and both probes, some of which capture test pictures | Reach files outside `videos/`, `logs/`, `probes/`, `clips/` and `stills/` |
| List files in those folders and fetch them | Watch the viewfinder live |
| Apply and save presets, and set the default | Delete presets |
| Take a picture of what the camera sees while no take is running, and fetch it | Fetch a picture during a take |

A take started by the server records video and sound like any other, and the server can then fetch it. It can also ask for a still of the scene at any moment outside a take, without any sign on the phone. Only turn the link on when you're happy for your computer to do that.

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

No location is sent, because the app doesn't record it. Video files can still hold whatever the camera saw and the microphone heard.

Turning off the two **Send** switches stops the automatic files. It doesn't stop the server asking for a file by name, or for a log, preview or status, so turn off **Connect** if you don't want that.

Traffic is **plain HTTP**. The token controls who may connect, but nothing is encrypted, so anyone able to watch your network could read the token and the data. That's why it belongs on a network you trust.

## What stays on each device

- **Phone:** the server address and token stay in `VibeLog.config.json` in the VibeLog folder, as plain text. They can be read in the Files app, and they go into any phone backup.
- **Computer:** the results folder holds everything received, including previews and any fetched videos, plus the token, `replies.jsonl`, which is a log of every reply, including status, and each suite's `suite_*.csv` and `heat_*.csv`. It stays there until you delete it.

Nothing is sent to the VibeLog project or to anyone else.

## Running the server

It needs Python 3 and nothing else. These commands run from the repository's folder.

### Start it

```bash
python3 tools/test_server.py serve
```

It prints the address and token to enter in the app, and where files go. The token is six random digits, kept in a `token` file in the results folder. That folder is `~/VibeLogTest` unless you set another: put its path in `~/.vibelog_test_folder`, set `VIBELOG_TEST_FOLDER`, or pass `--folder` before `serve`. Videos are large, so choose a drive with room. The server refuses a file that would leave under 2 GB free.

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

The server prints `phone connected` when the phone reaches it, and `refused a wrong token` on a bad token.

If a firewall blocks the phone on Linux with `ufw`, allow only your own network, changing the range to match yours:

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
| `controlTest`, `encoderTest`, `probe` | Run the Diagnostics tests |
| `sendPreview` | Sends a small JPEG of the scene |
| `saveStill`, `sendStill` | Saves a full still, and sends the newest one |
| `sendReference` | Sends the newest RAW clip's reference frame and metadata |
| `sendLog`, `listFiles`, `sendFile <name>` | Fetch logs and files |

A suite runs a list of takes and cooling breaks from a JSON file, and writes `suite_*.csv` and `heat_*.csv` to the results folder. It refuses to start unless the phone is on the camera screen with room for its takes:

```bash
python3 tools/test_server.py suite tools/suites/ultra_wide.json
```

`send status` also reports which screen is open and why the camera is busy. A wrong setting replies with the values it accepts. `send` and `suite` only work from the computer running the server.

### Stop it

Press Ctrl+C in its terminal. The phone then shows **Waiting for the server** until you turn off **Connect**.

## Keeping it private

From least to most effort:

1. **Connect only when testing.** Turn **Connect** off and stop the server when you finish. Restarting the app also turns it off.
2. **Never expose the server to the internet.** Don't forward port 8765 on your router, and don't run it on public or shared Wi-Fi.
3. **Listen on one address only.** By default the server listens on every network the computer has. Name the one you want:

   ```bash
   python3 tools/test_server.py serve --bind 192.168.1.20
   ```

4. **Replace the token.** Six digits are easy to type and easy to guess, so they only suit a network you trust. For a longer one, stop the server, write your own to the file and restart it:

   ```bash
   python3 -c "import secrets; print(secrets.token_urlsafe(24))" > ~/VibeLogTest/token
   ```

5. **Send less.** Turn off both **Send** switches, and leave **Log capture timing** off.
6. **Encrypt the connection.** Plain HTTP can't be made private on an untrusted network. A private VPN between the phone and computer encrypts the traffic: run the server with `--bind` on the computer's VPN address and enter that address in the app. This setup hasn't been tested.
7. **Deny the permission.** iOS Settings > Privacy & Security > Local Network > VibeLog, turned off, stops the app reaching local devices at all. It hasn't been tested on a VPN address.

## Erasing what it left behind

**On the phone:** clear the server and token fields in Diagnostics, or edit `VibeLog.config.json` in the Files app and empty `testServer` and `testToken`. Use a new token afterward if you ever reuse the server.

**On the computer:** stop the server, then delete its folder. If you chose another one, delete that too:

```bash
rm -rf ~/VibeLogTest ~/.vibelog_test_folder
```

If you opened the firewall, close it again with the same rule:

```bash
sudo ufw delete allow from 192.168.1.0/24 to any port 8765 proto tcp
```

## Removing it from the app completely

This builds an app with no network code and no Local Network permission. Recording doesn't use any of it. Line numbers change, so find each item by name.

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

An older config file that still has these keys keeps working, and they're dropped the next time the app saves.

### 4. Remove it from `App/AppModel.swift`

Delete these properties:

```swift
/// Where the test link connects, kept between launches. The link itself never is.
@Published var testServer = ""
@Published var testToken = ""
@Published var testLinkOn = false { didSet { if testLinkOn != oldValue { updateTestLink() } } }
@Published var testLinkState = "Off"
@Published var testSendsResults = true
@Published var testSendsGyro = true
let testLink = TestLink()
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

Delete the whole `record(seconds:)` function, `diagnosticsClosed()` and `sendPreview()`, each with its comment.

Delete the `openScreen` property, with its comment, and the three lines that set it in `settingsOpened()`, `settingsClosed()` and `diagnosticsOpened()`.

In `saveCaptureTiming(for:)`, delete `self.sendTimingFile(url)`.

Delete `takeSeconds = nil` after the `Recording ... for ...` log line in `startRecording()`, and restore `rawDumpSeconds`:

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

In `App/DiagnosticsView.swift`, delete the whole `Section` whose header is `Text("Test link")`, and the `.onDisappear { model.diagnosticsClosed() }` line.

In `Modules/VLProcessing/StillExporter.swift`, delete the `preview` function, which nothing uses once the link is gone.

### 6. Remove its tests

In `Tests/VLTests/VLTests.swift`, delete the `TestLinkTests` class, and this line in `testOlderFilesKeepThirtyFramesAndNoPresets`:

```swift
XCTAssertEqual(config.testServer, "")
```

### 7. Update the docs

Delete this file, and the **Test link** row in `README.md`. In `HANDOFF.md`, delete the `tools/test_server.py` row, the **Test link** section, its item in the new-build list and its phone test.

### 8. Check nothing is left

This should print nothing:

```bash
grep -rnE 'testLink|TestLink|testServer|testToken|testSends|sessionStamp|TestCommand|TestReply|sendTakeFiles|sendTimingFile|sendPreview|updateTestLink|takeSeconds|openScreen|NSLocalNetwork|NSAllowsLocalNetworking' App Modules Tests project.yml
```

This should print nothing too, which confirms the app has no network code left:

```bash
grep -rlE 'URLSession|URLRequest|NWConnection|NWListener|WebSocket' App Modules
```

Then build as usual. CI should pass, with 5 fewer tests. To check a finished build, this should print `0`:

```bash
unzip -p VibeLog-unsigned.ipa 'Payload/*.app/Info.plist' | grep -ac NSLocalNetworkUsageDescription
```

The app's own **Share** button and the Files app still work, because iOS handles those, and they only send what you choose. After installing, also clear the old server and token as described under **Erasing what it left behind**.
