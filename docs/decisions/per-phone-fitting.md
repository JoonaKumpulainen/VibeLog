# Fitting each phone without costing the others

Agreed on 2026-11-10, after the first iPhone 16 logs. One phone's drawbacks must not interfere
with, or cut quality on, phones that work well.

- **One standard:** every phone starts on the setup proven on the iPhone 14 Pro. Nothing is
  switched by model name or guessed ahead of time.
- **A phone only moves on its own evidence:** a workaround applies after that phone's own stream
  has stalled, or its own encoder trial has measured too slow. It's kept per phone model and iOS
  version, so an iOS update is measured again.
- **Least cost first:** fallbacks are tried in order of what they cost, and the first that works
  is kept. For capture that is `CaptureSetup.ladder`: Apple's preview connected, then fast capture
  off, then both, then one request at a time.
- **Pixels before codec:** when the wanted codec can't hold 30 fps at full size with room to spare,
  the default goes to the codec that keeps the most pixels, then the one with room to spare, then
  the same chroma. A phone with a fast ProRes encoder keeps ProRes at full size.
- **Only defaults move:** a codec or size the owner chose stays, with a warning at record if its
  trial was under 30 fps.
- **It says what it did:** each move is logged with the phone model, the take's sidecar and the
  test link's status carry `captureSetup`, and **Reset all settings** forgets the capture setup so
  the phone finds it again.
