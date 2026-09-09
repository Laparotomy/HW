# Video Mapper

An iPhone app for projection mapping: warp videos and images onto real surfaces,
stack them in layers, shape how each one looks, and run the whole thing in time
with music — including music playing on other iPhones in the room.

## What it does

**Map video and images.** Each layer is a quad you drag by its corners. Corner
dragging applies a true projective transform (a homography), so pulling one corner
foreshortens the whole image the way a real projector does — which is what makes an
image sit flat on an angled wall instead of looking like a skewed rectangle.

**Manage media.** Import clips and stills from the photo library or the Files app.
Each show keeps its own copy of its media in its own folder, so a show is
self-contained and can be moved or shared without breaking links.

**Change size, colour, texture and intensity.** Per layer:

| Control | Range | Notes |
| --- | --- | --- |
| Size / position / rotation | free | Pinch and twist on stage, or use the sliders |
| Corner warp | free | Four pins; folded quads are rejected |
| Intensity | 0–4x | Above 1 deliberately blows out highlights for dark surfaces |
| Opacity | 0–100% | |
| Colour + mix | any colour | Tints the layer, or paints a solid colour layer |
| Saturation / contrast | 0–200% | |
| Texture | 6 patterns + your own image | Tiling, amount, and scroll speed |
| Edge feather | 0–50% | Soft edges for blending overlapping projections |
| Blend mode | normal, add, screen, multiply | |

**Layer up.** Any number of layers per show, reorderable, with visibility and lock
toggles. A locked layer ignores stage gestures, so a finished mapping cannot be
nudged mid-set.

**Sync to music.** Three clock sources:

- **Track** — load an audio file; the visuals follow its playback position.
- **Listen** — the microphone drives the show, so it locks to music from a PA
  system or anything else this app has no digital link to.
- **Free run** — a plain timer, for programming in silence.

Audio is analysed on device (FFT into bass/mid/treble bands, plus onset-based beat
and tempo detection). Any band can be routed to any parameter — bass to intensity,
beat to size, treble to texture — with adjustable depth and release.

**Sync across devices.** One device hosts; others join over Wi-Fi with no pairing
step. Joined devices receive the show, follow the host's clock, and play their own
copy of the same track, started together. Two phones side by side stay locked to
each other rather than drifting apart over a set.

## Building

Open `VideoMapper.xcodeproj` in Xcode 16 or later, set your development team in the
target's Signing settings, and run on an iPhone with iOS 17 or later.

Run the tests with `⌘U`, or:

```
xcodebuild test -scheme VideoMapper -destination 'platform=iOS Simulator,name=iPhone 15'
```

Use a physical device for real work: multi-device sync needs the local network, and
Listen mode needs the microphone. The simulator can run the renderer and the tests.

### Permissions

On first use the app asks for the photo library (importing media), the microphone
(Listen mode only), and the local network (device sync only). Denying any of them
leaves the rest of the app working.

## Running a two-device show

1. Put both devices on the same Wi-Fi network.
2. Import the same music file onto both. The app warns you if the files look
   different, since sync quality depends on them matching.
3. On one device, open **Sync** and choose **Host**. On the other, choose **Join**.
4. Wait for the follower's clock status to read **Locked**. Round trip under 30 ms
   is comfortable; that is the range where two speakers still sound like one.
5. Press play on the host.

The host's layer edits appear on joined devices live. If a follower is missing a
video file, that layer is drawn as a colour block so the mapping stays visible and
you can see what is missing.

### Latency

Every projector and speaker adds delay, and no two are the same. **Visual delay**
in the Audio tab shifts the visuals against the music by ±500 ms, per device. Set it
by eye during soundcheck.

## Layout

```
VideoMapper/
  App/      ShowController — owns the project, clock, audio and peer link
  Model/    Project, layers, transforms, homography maths, persistence
  Render/   Metal renderer, shaders, video/image texture sources
  Audio/    Playback, FFT analysis, beat tracking, modulation routing
  Sync/     Multipeer transport, clock estimation, message types
  UI/       SwiftUI screens
VideoMapperTests/
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for how the pieces fit together and why.

## Status

Builds clean and all 28 unit tests pass on CI (`.github/workflows/ios.yml`, Xcode on
a macOS runner). Every push also uploads an unsigned `.ipa` artifact.

Still unverified: nothing has been run on real hardware. Rendering, media capture,
microphone analysis and multi-device sync all need a device — a green build says the
code compiles and its maths is right, not that the show looks correct on a wall.
