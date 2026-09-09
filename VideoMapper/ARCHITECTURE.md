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
- Media is not transferred between devices; each needs its own copy.
- The host is authoritative. A follower can edit locally, but the next host broadcast
  replaces its project.
- Beat detection is unreliable on sparse or heavily rubato music.
- One canvas per show; there is no multi-projector edge-blend layout beyond the
  per-layer feather control.
