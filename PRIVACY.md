# Privacy

What VibeLog keeps, what can leave the phone, and how to stop it. Short version: by default
nothing leaves the phone. Two developer features can send data, both off until you turn them on.

## On the phone

Everything VibeLog makes stays in its own folder, which the Files app shows under **On My
iPhone**, **VibeLog**: takes and their details, gyro logs, session logs, test reports, lens
profiles, LUTs, stills and settings. Deleting the app deletes all of it. The app records no
location and has no accounts, ads or analytics. It uses the camera and microphone only to
record, and Local Network only for the test link.

**Share** in the library and the Files app send only what you pick, where you pick, through iOS.

## The test link, for test sessions

Off at every launch, and only you can turn it on, in Diagnostics. While connected, a computer
you choose can change settings, start takes, take stills of what the camera sees and fetch files.
It sends only to that computer, over your own network or a tunnel you set up, and nothing at
all while it's off.

## Log sharing, for testers

Off until you turn it on in Diagnostics and enter an invite code from the developer. It then
sends test logs to the VibeLog test service, a small service on the developer's Cloudflare
account.

**What goes:** session logs, each take's details (its format, settings and frame counts), test
and benchmark reports, lens profiles, and what the app measured about your phone's camera and
encoders, including the benchmark's results. Gyro logs, which describe how the phone moved, only
with their own switch on.

**What never goes:** videos, sound, stills, previews, RAW frames, or anything else the camera
saw or the microphone heard.

**Made anonymous first, on the phone:**

- Your phone is known only by its model (such as `iPhone15,2`), its iOS and app versions, and a
  random ID that has nothing of you or the phone in it.
- Dates in file names and text become a code that can't be worked back. Times of day stay, since
  they order what happened.
- Network addresses, such as a test server's, are taken out.
- Names you typed, for LUTs, presets and styles, are replaced.

**When:** 30 seconds after the app opens, and when you leave it after a take or at most once
every 15 minutes otherwise, never during a take; and whenever you tap **Send now**. Only what's
new since the last time. The log of the session still running only goes after a take or when you
tap **Send now**; otherwise it goes whole at the next launch. Uploads are compressed. On Wi-Fi only, unless you turn on **Use mobile data**, which
also allows a hotspot. Never in Low Data Mode. Uploads are small: a session's logs are usually
under 1 MB.

**On the service:** each upload is kept, sorted by phone model, until the developer downloads
and deletes it. The service sees your IP address while it answers, as every web server does,
and doesn't store it. Cloudflare runs the service, under its own privacy policy. Only the
developer can read the uploads; nothing is published, sold or shared.

**Stopping and deleting:** turn **Share test logs** off and nothing more goes. **New anonymous ID**
means what you sent before can't be linked to what you send next. To have what you sent deleted,
send the developer the **Anonymous ID** shown in Diagnostics; they delete every upload with it,
on the service and their computer.

## In this repository

The repository is public. Secrets, such as tokens, invite codes and the service's keys, are kept
on the developer's computer and never committed: `tools/check_secrets.py` refuses them in a
pre-commit hook and on every push in CI. No tester's logs are ever committed.

## Questions

Open an issue on GitHub, or ask the developer directly if you're a tester.
