# Video Mapper

An iPhone app for projection mapping: warp videos and images onto real surfaces,
stack them in layers, shape how each one looks, and run the whole thing in time
with music — including music playing on other iPhones in the room.

## What it does

**Map video and images.** Each layer is a quad you drag by its corners. Corner
dragging applies a true projective transform (a homography), so pulling one corner
foreshortens the whole image the way a real projector does — which is what makes an
image sit flat on an angled wall instead of looking like a skewed rectangle.

**Correct what four corners cannot.** Four corners describe a flat surface exactly,
and nothing else. For a curved wall, a column, a sagging cloth or panels that do not
sit flush, the layer gains control points in between, each dragged on the stage in
Warp mode. Two ways to add them:

- **An even grid.** The inspector's **Correction grid** pickers lay out 2x2 up to
  8x8 in one tap.
- **One point where you want it.** In Warp mode, **double-tap the stage** and a point
  goes in under your finger; double-tap a point to take it away again. The grid keeps
  the positions of its dividing lines rather than a count, so the spacing can be
  uneven — crowd points where a surface bends, leave them sparse where it is flat, up
  to 12 divisions each way.

A point arrives with the rest of its row and column, not alone. That is deliberate:
the renderer draws every cell as a quad with its own homography, which is what keeps
perspective correct inside each one. Free-floating points would need the surface
triangulated, and a triangle can only carry an affine map — straight lines in the
content would kink at every shared edge.

Adding points never moves a mapping you have already aligned, by either route: the
points start exactly where the corner warp already puts them.

**Handles say what they are.** Corners are labelled TL/TR/BR/BL and interior points
by their column and row, so "pull 3·2 left a bit" means something across a room.

**Every layer shows its grid.** The stage draws the outline and correction grid of
every visible layer, the ones you are not editing knocked back, because surfaces
that have to meet cannot be lined up against each other while only one of them is on
screen. Handles stay on the selected layer alone — two dozen draggable-looking dots
that do not answer to a finger are worse than none.

**Switch between the picture and the mapping.** The Content / Grid / Both control
beside the transport decides what the stage shows:

| | |
| --- | --- |
| **Content** | Exactly what the projector puts on the wall, nothing drawn over it. |
| **Grid** | The mapping, over a dimmed picture — lines stay readable over a bright clip. |
| **Both** | The working default. |

The dimming is a property of the editing stage only. The projector's own window
draws the same renderer with no scrim, no outlines and no handles, whatever this is
set to.

**Points snap to each other.** Drag a control point near a point of another layer,
near another point of the same layer, or near an edge or centre line of the frame,
and it lands on it exactly, with a badge naming what it caught. This is not a
convenience: two mapped surfaces a pixel apart leave a black hairline on the wall and
two that overlap by a pixel leave a bright one, neither is fixable by eye from where
you stand next to a projector, and landing on the same coordinate is the only thing
that removes the seam outright. Turn it off in the inspector's **Correction grid**
section if you need free placement.

**Scan the surface you are projecting onto.** Stand where the projector is, aim the
phone the way it is aimed, and capture. The photo goes under the stage at an
adjustable strength, so you align layers against the actual wall instead of from
memory. That part works on every iPhone.

On an iPhone with a **LiDAR scanner** the shape of the surface is measured as well,
and a layer can be bent to follow it: tell the app the projector's throw ratio and
where the audience stands, and **Design → Bend this layer to the surface** curves the
correction grid so the content sits on a column or a curved wall the way it would sit
on a flat one. A flat wall produces no change at all, by construction — see
[ARCHITECTURE.md](ARCHITECTURE.md) for why, and for what this is not.

**Set the canvas to the projector's frame.** The toolbar's aspect-ratio button is a
menu: 16:9, 16:10, 5:4, square and portrait are one tap, and **Custom** opens the
stage settings for any size you type in. Layer positions are normalized, so changing
the canvas keeps the mapping and only changes the frame around it.

**Work full screen.** The expand button on the stage hands the whole screen to it,
with every gesture still live — corners dragged, points added, layers selected — so a
mapping is dialled in at a size where a few pixels of misalignment are actually
visible. The play button does the same for a show, and perform mode carries a
Move/Warp picker so a surface can be nudged mid-set without dropping back to the
editor. A new layer fills the frame, so its handles start at the edges of the picture
rather than somewhere in the middle of it.

**Swap content without rebuilding the mapping.** Aligning a surface is the slow part;
what plays inside it is not. The inspector's **Content** section shows a preview of
the layer and replaces it in place — a photo, a video, or a generated source — leaving
the quad, the grid, the blend and the audio routing untouched.

**Built-in source library.** Twenty-four abstract sources, generated on the GPU
rather than played back from video files, on five shelves:

| Shelf | | | |
| --- | --- | --- | --- |
| **Washes** — colour over the whole surface | Plasma, Clouds, Waves | Aurora, Metaballs, Liquid | Ripple, Nebula |
| **Structure** — lines, tiles, symmetry | Grid, Kaleidoscope | Cells, Moiré | Hexes |
| **Depth** — perspective on a flat wall | Tunnel | Spiral | |
| **Particles** — discrete points on black | Starfield, Fireflies | Confetti | Rain |
| **Hits** — built for the beat | Rings, Strobe | Lightning, Sweep | Bars |

Each has a palette (12 ramps), speed, detail size, complexity and variation, and can
be driven directly by the music. Because a source is computed rather than decoded,
it has no resolution limit, never loops, adds nothing to the size of a show, and
needs no transfer to a second device — a follower phone reproduces it exactly from
the show clock alone. **Layers → Sources** opens the library; the shelf chips and
the search field narrow it, and search reads the descriptions too, so "beat",
"columns" or "smoke" finds the thing you remember seeing.

Three of them are worth knowing about before you go looking: **Bars** is a level
meter that becomes one the moment you feed it audio, **Sweep** uses its Detail
control as the bar's *angle* rather than as detail, and **Rain**, **Confetti** and
**Bars** are laid out against the frame rather than around its centre, so they fill
a tall surface properly instead of being letterboxed into it.

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
| Correction grid | up to 12x12 cells | Even grids from the pickers, single points by double-tapping the stage |
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

**Run each layer at its own speed.** Every clip has its own playback speed, from
frozen (a still frame, without importing a still) to 4x, and every generated source
has its own rate. Two layers of the same clip at different speeds is a normal thing
to want and costs nothing.

**Sync to music.** Three clock sources:

- **Track** — load an audio file; the visuals follow its playback position.
- **Listen** — the microphone drives the show, so it locks to music from a PA
  system or anything else this app has no digital link to.
- **Free run** — a plain timer, for programming in silence.

**Move only while the music plays.** Audio → *While the music plays* holds the show
still until it hears something and picks up from the same frame when the music comes
back. On the Track clock that follows the transport exactly. On Listen it is a level
you set against the live meter — "music" from a microphone really means "louder than
this room's own floor", and that floor is different in a gallery and in a bar. Either
way the show keeps running for a moment after the music drops, so a gap between
tracks reads as a pause rather than a stutter.

### Where the music can come from

| Source | How |
| --- | --- |
| Files, AirDrop, iCloud Drive | **Audio → Choose → Files** |
| The device's music library | **Audio → Choose → Music library** |
| Apple Music, SoundCloud, Spotify, YouTube | **Listen** mode |

**Music library** reaches the songs the device holds unencrypted — what you bought,
synced, or ripped. Apple Music downloads are usually not among them: catalogue audio
is encrypted, only Apple's own player can decrypt it, and no app can read its samples.
The picker will tell you when a track is one of those rather than failing quietly.

There is no import for the streaming services, and this is not an oversight. Apple
Music, SoundCloud, Spotify and YouTube all decode audio inside their own player and
none of them expose the samples; SoundCloud has no third-party iOS playback SDK at
all. Nothing inside an app can change that.

Listen mode is the way round it and it is not a consolation prize: play the music
from any app or from the PA in the room, and the microphone gives the show its level,
its bands, its beat and its tempo. The one thing it cannot do is guarantee two phones
play the same thing at the same instant — for that the audio has to be a file both
devices hold, which is what **Music library** and **Files** are for.

Tempo is found automatically. The analyser estimates BPM from the audio and reports
how much the estimate agrees with itself; while that confidence is low — a rubato
piece, a quiet passage — the show falls back to the manual tempo rather than letting a
bad guess drive it. Switch to **Manual** to pin a fixed grid, tap it in by hand, or
press **Use detected** to freeze whatever the analyser found.

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

### Scanning, honestly

| | Any iPhone ARKit runs on | iPhone with LiDAR |
| --- | --- | --- |
| Reference photo under the stage | yes | yes |
| Surface shape measured | no | yes |
| Bend a layer to the surface | no | yes |

LiDAR is on the Pro and Pro Max models from the iPhone 12 onward. Without it the app
says so rather than producing a warp with nothing behind it.

The bend is a good starting point, not a calibrated solution. It assumes the phone was
where the projector's lens is, and takes the projector's frustum from a throw ratio
typed in by hand. Errors in either show up as the whole image being slightly shifted
or scaled, which the four corner handles fix in seconds; the curvature, which corners
cannot express, is what the scan recovers.

### Permissions

On first use the app asks for the photo library (importing media), the microphone
(Listen mode only), the camera (scanning only), the music library (choosing a track
from it only), and the local network (device sync only). Denying any of them leaves
the rest of the app working.

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
  Scan/     ARKit capture of a surface's photograph and depth
  Audio/    Playback, FFT analysis, beat tracking, modulation routing
  Sync/     Multipeer transport, clock estimation, message types
  UI/       SwiftUI screens
VideoMapperTests/
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for how the pieces fit together and why.

## Status

Builds clean and all 162 unit tests pass on CI (`.github/workflows/ios.yml`, Xcode on
a macOS runner), which also launches the app in a simulator to catch crashes that
compile fine. Every push uploads an unsigned `.ipa` artifact.

Verified on device: the app builds, installs and runs on an iPhone.

Still unverified on hardware: how each generator actually looks projected, media
capture, microphone analysis, projector output, multi-device sync, and every part of
surface scanning — ARKit does not run on a simulator, so the camera path has only
ever been compiled, never executed. The scan maths is exercised against synthetic
surfaces whose right answer is known, which is a different and weaker claim than
having pointed a phone at a wall. A green build
says the code compiles and its maths is right, not that the show looks correct on a
wall.
