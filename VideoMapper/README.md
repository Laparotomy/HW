# Video Mapper

An iPhone app for projection mapping: warp videos and images onto real surfaces,
stack them in layers, shape how each one looks, and run the whole thing in time
with music — including music playing on other iPhones in the room.

## What it does

**Map video and images.** Each layer is a quad you drag by its corners. Corner
dragging applies a true projective transform (a homography), so pulling one corner
foreshortens the whole image the way a real projector does — which is what makes an
image sit flat on an angled wall instead of looking like a skewed rectangle.

**Built-in source library.** Twelve abstract sources, generated on the GPU rather
than played back from video files:

| | | |
| --- | --- | --- |
| **Plasma** — flowing colour field | **Clouds** — drifting fractal smoke | **Tunnel** — receding depth |
| **Kaleidoscope** — mirrored symmetry | **Cells** — organic cracked cells | **Rings** — outward pulses |
| **Waves** — interfering wavefronts | **Grid** — perspective horizon | **Starfield** — streaming points |
| **Aurora** — swaying curtains | **Metaballs** — merging blobs | **Strobe** — beat-locked flashes |

Each has a palette (8 ramps), speed, detail size, complexity and variation, and can
be driven directly by the music. Because a source is computed rather than decoded,
it has no resolution limit, never loops, adds nothing to the size of a show, and
needs no transfer to a second device — a follower phone reproduces it exactly from
the show clock alone. **Layers → Sources** opens the library.

**Manage media.** Import clips and stills from the photo library or the Files app.
Each show keeps its own copy of its media in its own folder, so a show is
self-contained and can be moved or shared without breaking links.

### Adding your own footage

The library covers abstract backdrops; for real footage, import your own. Anything
AVFoundation can open works (H.264/HEVC in `.mov` or `.mp4`, ProRes). Sites with
genuinely free, commercially usable clips — check the licence on each file, it
varies per upload:

| Source | Licence |
| --- | --- |
| [Mixkit](https://mixkit.co/free-stock-video/) | Mixkit licence, free for commercial use, no attribution |
| [Pexels Videos](https://www.pexels.com/videos/) | Pexels licence, free for commercial use |
| [Pixabay](https://pixabay.com/videos/) | Pixabay content licence |
| [Videvo](https://www.videvo.net/) | Mixed; filter to "Free" and read the per-clip terms |
| [Internet Archive](https://archive.org/details/movies) | Mixed; public-domain collections are the useful part |

Download on the Mac or the phone, drop the files into Photos or Files, then import
them through **Layers → Media**. For projection, dark clips with a few bright
elements read far better on a wall than bright, busy ones.

**Change size, colour, texture and intensity.** Per layer:

| Control | Range | Notes |
| --- | --- | --- |
| Size / position / rotation | free | Pinch and twist on stage, or use the sliders |
| Corner warp | free | Four pins; folded quads are rejected |
| Intensity | 0–4x | Above 1 deliberately blows out highlights for dark surfaces |
| Opacity | 0–100% | |
| Colour + mix | any colour | Tints the layer, or paints a solid colour layer |
| Saturation / contrast | 0–200% | |
| Texture | 5 procedural overlays + your own image | Tiling, amount, and scroll speed |
| Source controls | generator layers only | Palette, speed, detail, complexity, variation |
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
beat to size, treble to texture — with adjustable depth and release. Generator
layers additionally have their own **Driven by** control, which feeds the audio
into the pattern itself rather than into the layer's shape.

**Sync across devices.** One device hosts; others join over Wi-Fi with no pairing
step. Joined devices receive the show, follow the host's clock, and play their own
copy of the same track, started together. Two phones side by side stay locked to
each other rather than drifting apart over a set.

## Running it on your iPhone

You need a Mac with Xcode 16 or later and an iPhone on iOS 17 or later. A free Apple
ID is enough; a paid developer account only changes how long the app stays installed.

```
git clone https://github.com/Laparotomy/HW.git
cd HW/VideoMapper
open VideoMapper.xcodeproj
```

1. Select the **VideoMapper** target → **Signing & Capabilities** → tick *Automatically
   manage signing* and choose your team. With a free Apple ID, add it first under
   Xcode → Settings → Accounts.
2. **Change the bundle identifier.** `app.videomapper.VideoMapper` is a placeholder,
   and Apple will refuse to register it if anyone else already has. Use your own
   reverse-domain name, e.g. `com.yourname.VideoMapper`. Do the same for the test
   target if you plan to run tests on the device.
3. Plug in the iPhone. On the phone, enable **Settings → Privacy & Security →
   Developer Mode**, then restart it.
4. Pick your iPhone in the run-destination menu and press **⌘R**.
5. The first launch is blocked as an untrusted developer. Clear it on the phone at
   **Settings → General → VPN & Device Management** → trust your certificate, then
   open the app again.

A free Apple ID signs the app for **7 days**; after that, re-run from Xcode. A paid
Apple Developer account extends this to a year and allows TestFlight distribution.

### Building without a Mac

CI builds an unsigned `.ipa` on every push (Actions → latest run → Artifacts). It
cannot be installed as-is: sign it with your own Apple ID using Sideloadly or
AltStore, which run on Windows as well as macOS. The same 7-day limit applies.

## Testing

`⌘U` in Xcode, or on the command line:

```
xcodebuild test -project VideoMapper.xcodeproj -scheme VideoMapper \
  -destination "id=$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}')"
```

CI resolves a simulator the same way rather than hardcoding a device name, so it
keeps working when the runner image changes.

Use a physical device for real work: multi-device sync needs the local network,
Listen mode needs the microphone, and only a projector shows whether a mapping
actually lands on the surface. The simulator runs the renderer and the tests.

### Permissions

On first use the app asks for the photo library (importing media), the microphone
(Listen mode only), and the local network (device sync only). Denying any of them
leaves the rest of the app working.

## Connecting a projector

The app gives the projector a **clean feed**: the mapped canvas on black, with no
panels, handles or status bar, while the phone keeps the editing interface. Connect
the projector and the second window appears on it automatically.

| Connection | How | Notes |
| --- | --- | --- |
| **HDMI** | USB-C to HDMI (iPhone 15 and later) or Lightning Digital AV Adapter | Lowest latency; the reliable choice for a show |
| **AirPlay** | Screen mirroring to an AirPlay projector or an Apple TV | Same clean feed, no cable. Adds latency and depends on Wi-Fi |
| **Bluetooth** | Not possible for video | See below |

**Bluetooth cannot carry video to a projector.** Its bandwidth is orders of magnitude
short of what video needs, iOS exposes no video-out API over Bluetooth, and projectors
do not accept video that way — a projector's Bluetooth is for audio. Wireless video
from an iPhone means AirPlay.

Bluetooth is still useful here, for sound: pair a Bluetooth speaker (or the
projector's own speaker) in iOS Settings and the show's audio follows the system
route with no setup in the app. Note that Bluetooth audio adds 100-200 ms of latency
of its own — use **Visual delay** in the Audio tab to line the visuals back up, or
run audio over a cable when timing matters.

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
  Render/   Metal renderer, shaders, generator library, texture sources
  Audio/    Playback, FFT analysis, beat tracking, modulation routing
  Sync/     Multipeer transport, clock estimation, message types
  UI/       SwiftUI screens
VideoMapperTests/
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for how the pieces fit together and why.

## Status

Builds clean and all 54 unit tests pass on CI (`.github/workflows/ios.yml`, Xcode on
a macOS runner), which also launches the app in a simulator to catch crashes that
compile fine. Every push uploads an unsigned `.ipa` artifact.

Verified on device: the app builds, installs and runs on an iPhone.

Still unverified on hardware: how each generator actually looks projected, media
capture, microphone analysis, projector output and multi-device sync. A green build
says the code compiles and its maths is right, not that the show looks correct on a
wall.
