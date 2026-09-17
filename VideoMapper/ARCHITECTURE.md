# Architecture

Notes on the decisions that are not obvious from the code, and the reasoning behind
them.

## The show clock

Everything visual is a function of one number: `showTime`, in seconds. Videos seek
to it, texture scroll is derived from it, and beat animation is phased against it.
Nothing anywhere holds its own timer.

`ShowController.updateShowTime()` sources that number differently by role:

- **Solo or host, track clock** — the audio engine's playback position, derived from
  the render clock rather than a `Timer`, so it stays exact over a long set.
- **Solo or host, free run / listen** — an anchor plus elapsed wall time.
- **Follower** — always the host's anchor, converted through this device's clock
  offset estimate.

Because show time is derived rather than accumulated, a dropped frame or a busy
main thread cannot make the show slowly fall behind the music.

`showTime` is deliberately not `@Published`. It changes 60 times a second, and
publishing it would invalidate the whole SwiftUI tree at that rate; the transport
read-out polls it from a `TimelineView` instead.

## Why a homography

The core requirement of projection mapping is putting an image onto a surface that
is not square-on to the projector. An affine transform (translate, scale, rotate,
skew) keeps parallel lines parallel and therefore cannot do this: the image lands
skewed rather than foreshortened.

`Homography.unitSquare(to:)` solves for the 3x3 projective matrix mapping the unit
square onto four arbitrary corners, using Heckbert's closed form — exact, no
iterative solver, cheap enough to recompute every frame while a finger is moving.

Two details matter downstream:

- The vertex shader writes the homogeneous coordinate into `position.w` rather than
  dividing it out. That is what makes the rasterizer interpolate texture coordinates
  with perspective correction. Without it, a keystoned quad shows the classic seam
  across its diagonal where the two triangles disagree.
- Corner drags are rejected when they would make the quad non-convex, since a folded
  quad has no valid homography and the layer would turn inside out.

Layers store centre/size/rotation *and* four corner offsets separately. The offsets
are applied after rotation, so the size slider keeps working normally on a layer that
has already been warped by hand — otherwise every warp would have to be redone after
any size change.

## The mesh is additive, not a replacement

Four corners and a homography describe a flat surface exactly. Nothing they can do
describes a curved one, so the correction grid adds points — and the question that
decides the whole design is where an unwarped point sits.

The answer is: on the quad's own projective map of its (u, v), not on a bilinear
blend of the four corners. Those differ on any keystoned quad, and only the first has
the property that matters: with every offset at zero, the mesh reproduces the
homography *exactly*. Subdividing a surface someone spent twenty minutes aligning
moves it by nothing at all. A bilinear base would shift the interior the moment the
grid appeared, which would make the feature useless on the surfaces that need it most.

Each cell is then its own quad with its own homography, drawn as its own quad. The
uniform block carries a uv slice (`params6`) so the fragment stage still samples
layer space rather than cell space — which is why feather, texture overlay and the
generators all keep working across a subdivided layer without knowing it was
subdivided. At 1 x 1 the slice is (0, 0, 1, 1) and the whole path collapses to what
it was before.

The cost is draw calls: one per cell, so 8 x 8 is 64 for that layer. Textures and
pipeline state are set once per layer and only the uniforms change between cells, but
the ceiling is deliberate.

### The grid stores lines, not counts

The grid keeps the normalized positions of its dividing lines rather than a number of
divisions. That is what lets the spacing be uneven — points crowded where a surface
bends and left sparse where it is flat — and it is what makes a tap able to put a
point exactly under a finger: `insertColumn(at:)` and `insertRow(at:)` each take a
position, and `LayerTransform.insertMeshPoint(near:)` turns a canvas point into a
(u, v) through the inverse homography and inserts one of each.

A new point therefore arrives with the rest of its row and column. That is the price
of every cell being a quad: a quad carries a full projective map, so perspective stays
correct inside it. Points placed freely would need the surface triangulated, and a
triangle carries only an affine map — the content's straight lines would kink at every
shared edge, which is exactly the artefact the homography was chosen to avoid.

New points are not born flat. Their offsets are a bilinear sample of the field they
are inserted into, in the grid's own uneven spacing, so the surface does not jump
where the point appears; the existing points keep their offsets untouched. Both offset
fields are carried, hand and scan alike, or changing the density would silently throw
away whichever one it forgot.

Persistence writes both shapes: the line positions this version reads, and the counts
an older build reads. An older build opening a newer show gets an evenly spaced grid —
wrong in the spacing, but a show rather than a decoding failure. Decoding sanitises
what it reads (sorted, clamped, de-duplicated, capped, edges always present), because
a hand-edited file must not be able to hand the renderer an index it can run off the
end of.

### Snapping is a seam fix, not a convenience

Two mapped surfaces that meet on the wall have to meet exactly. A gap of one pixel is
a black hairline and an overlap of one pixel is a bright one; neither is fixable by eye
from where you stand next to a projector, and both are obvious to an audience sitting
in front of it. So a dragged point is pulled onto the nearest candidate within a
fingertip's radius — a point of another visible layer, another point of the same
layer, or an edge or centre line of the canvas — and it lands on that coordinate
exactly rather than near it.

The radius is measured in aspect-corrected units. Normalized coordinates are stretched
by the frame's shape, so without the correction a snap on a 16:9 canvas would reach
nearly twice as far sideways as vertically — lopsided in exactly the way a projector
makes obvious. Nearest wins rather than first: with several surfaces meeting at a
corner, the one under the finger is the one meant.

Snapping does not bypass the fold check. A snapped landing goes through
`meshIsDrawable(movingPointAt:to:)` like any other drag and is refused if it would
turn a cell inside out.

The correction is stored as *two* fields, not one. Hand-dragged offsets and
scan-derived offsets answer to different owners: the first is what the operator
dragged and must never be recomputed, the second is derived and has to be replaced
wholesale by each new solve. They were one array at first, and bending a layer twice
doubled the bend — an integration test caught it, and the separation is the fix. A
new solve measures from `handAuthored` (the mapping with the bend stripped), so
applying the same scan twice gives exactly what applying it once gives, and removing
a bend leaves the hand alignment underneath it intact.

Folding is refused rather than clamped. A folded cell has a degenerate homography and
the patch turns inside out or vanishes; `meshIsDrawable(movingPointAt:to:)` checks the
up-to-four cells touching the dragged point and the drag is simply not applied.

## A projector cannot see its own distortion

This is the fact the whole scanning feature is built around, and it is worth stating
before the code that follows it: **a projector's image is never distorted from the
projector's own position.** Whatever shape the surface is, each pixel's light goes
where that pixel points. Distortion is something other viewpoints see — light that
would have landed at one place on a flat wall lands nearer or further on a curved
one, and from the side that difference reads as the image sliding across the object.

Three consequences shape the design:

1. **A photo from the projector's position is the most useful thing a phone can
   capture.** It shows the surface exactly as the projector frames it, so aligning a
   layer against that photo aligns it against the wall. This needs no depth sensor,
   no calibration and no maths, and it is what the reference underlay is.
2. **Correction only means anything relative to a chosen viewpoint.** `AudienceOffset`
   is therefore not optional garnish; without it there is nothing to solve, and the
   solver refuses rather than returning zeros.
3. **Only the audience's *position* matters, not their orientation or field of view.**
   Making a lit point line up for a viewer means putting it on the right ray *from
   that viewer*, and which way their head is turned does not change which ray a point
   is on. That collapses what looked like a second camera calibration into three
   numbers.

### The solve

`ScanSolver` fits a reference plane to the surface under the layer, treats the
authored mapping as describing where content should sit on that plane, and moves each
control point so the light actually reaching the real surface lands on the audience's
line of sight to the plane point. Newton's method, 2x2 numerical Jacobian, six steps,
one depth lookup each.

The plane fit is worth a note. For a pinhole camera, a plane makes *inverse axial
depth* an exactly affine function of the tangent coordinates `x/-z` and `y/-z`, so
fitting `a*x + b*y + c` is a plane fit outright — no eigen decomposition and no
degenerate orientations. Fitting against the components of a *unit* ray instead looks
almost identical and is wrong: the third component is a square root of the other two,
so a flat wall comes back slightly curved at the edges of the frame. That mistake was
made and caught here by the test that a flat wall must produce no correction at all,
which is the property the whole feature stands on.

### What it is not

It is not projector calibration. The projector's pose is assumed to be wherever the
phone was held, and its frustum comes from a throw ratio read off the manual. Both
carry error, and both express it as a whole-image shift or scale — which is what the
four corner handles were always for. The curvature is the part corners cannot
express, and that is the part this recovers.

Depth needs a LiDAR scanner, which means a Pro iPhone. `SurfaceScanner.Capability`
reports what the hardware can actually do and the UI says it plainly, because an app
that quietly produced a flat warp on a phone that cannot measure would look broken
rather than limited.

## Holding the show for the music

"Animate only while music plays" freezes the show clock instead of stopping the
transport. The distinction matters: the clock is what every generator, every video
slave and every follower device reads, so holding it holds all of them in step, and
resuming continues from the same frame rather than jumping forward by the length of
the silence. The anchor is rewritten on every held frame, which is what makes that
true.

What counts as "playing" depends on where the audio comes from. A loaded track
answers from the transport and is exact. Everything else has to answer from the
microphone, where the real question is "is this room louder than its own floor" — and
that floor is a property of the room, not of the app, so the threshold is a slider
shown next to the live meter rather than a constant. A hold of `musicGateHold` keeps
the show moving through the break between two phrases or the half-second a DJ spends
cutting the bass; without it, the visuals would freeze and restart, which reads as a
glitch rather than as following the music.

Free-run is exempt outright. It has no music to wait for and its analyser is not even
running, so gating there could only ever freeze the show for good.

## Streaming audio cannot be analysed, and Listen mode is the answer

Apple Music catalogue audio is encrypted; only Apple's own player can decrypt it, and
`MPMediaItem.assetURL` is nil for it. SoundCloud has no third-party iOS playback SDK,
and Spotify's and YouTube's decode inside their own players. There is no API on iOS
that hands another app those samples, so there is no import for them and no amount of
app-side work would produce one.

What there is, is the microphone. Listen mode analyses whatever is audible — from
another app on the same phone, from a laptop, from the PA — and produces the same
level, bands, beat and tempo a loaded file would. `MPMediaPickerController` covers the
other half: the songs the device holds unencrypted, exported to m4a into the show's own
folder. The export is not a nicety. `AVAudioFile` cannot open an `ipod-library://` URL,
and a show that has to play in step on several phones needs the audio to be a file each
of them holds.

## Tempo is detected, and its confidence is the interesting part

`BeatTracker` always produces a BPM. The useful signal is `tempoConfidence` — the
spread of the detected inter-onset intervals about their median. A four-on-the-floor
track settles near 1; a rubato piano piece stays near 0.

Automatic mode adopts the detected tempo only above `AudioSettings.confidenceThreshold`
and falls back to the authored value below it. That is not timidity: a beat grid that
lurches is visibly worse than one that is slightly wrong but steady, and a show
programmed in silence has to look the same when the music starts.

## Rendering

One draw call per layer, blended in order, with no intermediate render target. Blend
modes are expressed as pipeline blend factors rather than a compositing pass, which
keeps a dozen layers inside a 60 fps budget on a phone.

Screen and multiply need the source pre-multiplied differently, so the fragment
shader prepares its output according to a blend index and the pipeline supplies the
matching factors. The two halves have to stay in agreement — that pairing is the
easiest thing to break here.

The uniform block is packed into `float4`s so Swift and MSL agree on layout without a
bridging header. `LayerUniforms` exists in both `MetalRenderer.swift` and
`Shaders.metal` and the two must be edited together.

`TextureStore` rebuilds a layer's GPU resources only when its *content* fingerprint
changes, so moving a slider never re-decodes a video.

## Abstract sources are generated, not shipped

The source library is twelve fragment-shader functions, not twelve video files. That
choice falls out of what projection mapping actually needs:

- **Resolution.** A generator is evaluated per pixel at whatever the output is. A
  1080p file fed to a 4K projector is an upscale; a generator is not.
- **Duration.** There is no clip to loop, so there is no loop point to hide and no
  seek to perform.
- **Size.** Twelve abstract loops at a usable quality is a few hundred megabytes in
  the app and in every backup of it. The library as written is about 300 lines of
  MSL.
- **Synchronisation, which is the real win.** A generator is a pure function of
  `(uv, showTime)`. Two devices given the same show time compute the same frame,
  bit for bit, with no seeking, no drift correction and nothing to transfer. A
  follower phone reproduces a generator-only show perfectly from a clock anchor and
  a few kilobytes of JSON — the media-distribution problem simply does not arise.
- **Licensing.** Nothing in the library belongs to anyone else.

The cost is fill rate. Every generator is evaluated for every covered pixel, every
frame, and the expensive ones (`clouds` domain-warps noise three times, `cells` runs
a 3×3 voronoi search) are meaningfully heavier than sampling a video texture. The
`complexity` control exists mostly as a fill-rate dial: octaves fade in with it
rather than switching on, so it can be pulled down on an older device without a
visible step.

Generators reuse the existing path rather than adding a second one. The layer still
binds the shared 1×1 white texture, still goes through one draw call, and the
fragment shader substitutes the generated colour for the sampled one before the rest
of the chain — saturation, tint, texture overlay, feather, blend — runs unchanged.
So a generator is adjustable in exactly the same ways a clip is, and none of the
compositing code knows generators exist.

Two indices have to stay stable: `GeneratorKind.shaderIndex` and
`GeneratorPalette.shaderIndex` are the dispatch values in `Shaders.metal`. Projects
store the kind by *name*, so renumbering would not corrupt a saved show, but it
would make a running shader draw the wrong pattern with nothing failing. The unit
tests pin the indices and the raw values for that reason.

Generator reactivity is deliberately not a modulation route. Routes drive a layer's
shape and look; a generator wants the audio inside the pattern, so
`GeneratorSettings` carries its own source and depth and `ModulationEngine` keeps a
separate envelope per layer for it. A beat-locked strobe is then a picker away
instead of a routing exercise.

## Video is slaved, not just played

`VideoTextureSource` does not simply call `play()`. Every frame it compares the
player's position against where the show clock says it should be, and corrects:

- error over 150 ms — seek
- error under 8 ms — leave it alone, since chasing jitter looks worse than the drift
- in between — trim the playback rate by up to 5%, which is imperceptible

This is what keeps two phones showing the same frame over a long run, and what makes
a clip land back in the right place after the transport is scrubbed.

## Clock synchronisation

`CACurrentMediaTime()` counts from boot, so two devices' readings are unrelated. Any
shared timestamp is meaningless until the offset between them is known.

`ClockSynchronizer` follows the NTP round-trip method: the follower stamps a probe,
the host stamps its receipt, and the follower stamps the reply. Assuming the probe
took half the round trip to arrive gives the offset.

It then keeps the sample with the **lowest** round-trip time from a recent window
rather than averaging. Wi-Fi delay is asymmetric and bursty; the quickest exchange is
the one least distorted by queueing, so the minimum is a better estimator than the
mean. `testRejectsSlowOutliers` covers exactly this: one clean probe among four badly
asymmetric slow ones still recovers the true offset.

Probes are sent unreliably. A dropped probe costs nothing; a retransmitted one
arrives late and skews the estimate. They are also answered on the receiving thread
rather than hopping to the main actor, which would add several milliseconds of error
to every measurement.

## Transport as an anchor, not a command

The host does not send "play now" — that arrives late, and differently late on each
device. It sends an anchor: *at host time T the show was at position P*. Any device
can then compute the current show time from its own clock, and a device joining
halfway through a set lands in the right place immediately with no special case.

Follower audio works the same way. No audio is streamed: each device plays its own
copy of the file, scheduled to begin at the host time the anchor implies, using
`AVAudioTime` for sample-accurate start. Drift is re-checked every two seconds and
corrected by rescheduling when it exceeds 40 ms — roughly where a listener starts to
hear two speakers as separate sources.

## Audio analysis

A tap on the mixer (or the microphone, in Listen mode) feeds a 1024-sample windowed
FFT, reduced to three bands plus spectral flux. Beats come from thresholding the flux
against its own rolling mean and deviation, so the threshold tightens in quiet
passages and loosens through a busy drop. Tempo is the median inter-onset interval,
folded into 70–180 BPM.

It is a modest algorithm, chosen because it has to share a phone with video decoding
and 60 fps rendering. It follows four-on-the-floor material well and is less certain
on sparse or rubato music; tap tempo and manual BPM are there for when it is wrong.

## Modulation is additive

Audio routes produce *offsets* applied on top of stored values, never writes back
into the project. Stop the music and every layer springs back to exactly what was
authored. This is also why `LayerTransform.quad(scale:)` takes the reactive scale as
an argument instead of mutating `size`.

Envelopes rise instantly and fall at the route's smoothing rate, so a peak reads on
the frame it happens and decays smoothly afterwards.

## The projector is a second scene, not a mirror

iOS mirrors the screen by default, which for this app would put sliders and corner
handles on the wall. Declaring a scene for
`UIWindowSceneSessionRoleExternalDisplayNonInteractive` replaces mirroring with a
window the app controls: the phone keeps the editor, the projector gets output only.
The same declaration serves HDMI and AirPlay — iOS presents both as an external
screen — so there is one code path, not two.

That scene is created and owned by UIKit, outside the SwiftUI hierarchy, and it has
to reach the same show the phone is editing. That is why `ShowController` is a
singleton: a `@StateObject` held in a view tree is not reachable from another scene's
delegate.

Both windows share one renderer and draw the same `RenderFrame`. `makeFrame()`
caches for a few milliseconds because two displays ask for a frame at nearly the
same instant, and building it twice would advance the audio modulation envelopes at
double rate — the projector and the phone would visibly disagree about how far a
beat had decayed.

## Storage

```
Documents/Shows/<uuid>/project.json
Documents/Shows/<uuid>/Media/<uuid>.<ext>
```

Media is copied into the show folder on import and referenced by relative filename,
so a show is one self-contained directory. Writes are atomic, and saves are debounced
so a slider drag produces one write rather than hundreds.

Because each device names imported files with its own UUID, a host's media reference
will not resolve on a follower. Followers therefore fall back to matching by display
name, and draw a colour block for anything still missing rather than dropping the
layer — the mapping stays visible so the operator can see what is absent.

## Known limits

- Multipeer Connectivity practically limits a session to around eight devices.
- Media is not transferred between devices; each needs its own copy. Generator
  layers are exempt — they carry no media at all.
- Generators are fill-rate bound. A stack of several full-canvas generators on an
  older device will cost frames where the same stack of video layers would not.
- The host is authoritative. A follower can edit locally, but the next host broadcast
  replaces its project.
- Beat detection is unreliable on sparse or heavily rubato music.
- One canvas per show; there is no multi-projector edge-blend layout beyond the
  per-layer feather control.
- The correction grid is a quad mesh with linear interpolation inside each cell. A
  tight curve needs more cells rather than smoother interpolation; there is no spline
  surface.
- Correction points are not free-floating: adding one adds its whole row and column.
  Free placement would require triangulation, which would trade perspective-correct
  cells for affine ones.
- Snapping only pulls control points. Dragging a whole layer by its middle has no one
  point to line up, so it is left alone.
- Apple Music, SoundCloud, Spotify and YouTube audio cannot be read by any app; only
  the microphone reaches it.
- Tempo detection is onset-based and reports low confidence rather than trying harder
  on music it cannot read.
- A scan is a single capture from one position, not a walk-around reconstruction. It
  describes the surface as the projector sees it, which is all the warp needs, and
  nothing about the sides of an object.
- Surface depth is stored as a 65 x 49 grid rather than a mesh. Fine relative to any
  warp grid, coarse relative to a real scan.
