import XCTest
@testable import VideoMapper

/// A looping clip that reaches the end of its file is a case the drift corrector
/// cannot see: folding the error across the loop seam makes "a whole duration behind"
/// read as "in sync", and a player parked on its last frame ignores both `play()` and
/// a rate write. These pin the test that catches it, because the symptom on a wall is
/// a clip that holds one frame rather than anything that looks like a bug.
final class VideoTransportTests: XCTestCase {

    private let duration = 8.0

    func testAClipPartwayThroughHasNotRunOut() {
        XCTAssertFalse(VideoTextureSource.hasRunOut(actual: 0, duration: duration, loops: true))
        XCTAssertFalse(VideoTextureSource.hasRunOut(actual: 4, duration: duration, loops: true))
        XCTAssertFalse(VideoTextureSource.hasRunOut(actual: 7.9, duration: duration, loops: true))
    }

    func testAClipOnItsLastFrameHasRunOut() {
        XCTAssertTrue(VideoTextureSource.hasRunOut(actual: duration, duration: duration, loops: true))
    }

    /// AVPlayer stops a hair short of the nominal duration often enough that an exact
    /// comparison would never fire. The deadband is what makes this reliable.
    func testTheLastFrameIsRecognisedJustShortOfTheEnd() {
        XCTAssertTrue(VideoTextureSource.hasRunOut(actual: duration - 0.001,
                                                   duration: duration, loops: true))
    }

    /// A clip that is meant to stop at the end must be left alone there: seeking it
    /// back would turn "play once" into a loop.
    func testANonLoopingClipIsLeftAtTheEnd() {
        XCTAssertFalse(VideoTextureSource.hasRunOut(actual: duration, duration: duration,
                                                    loops: false))
    }

    /// A still has no duration to run out of, and `currentTime` on an item that has
    /// not loaded yet is not a number.
    func testUnknownDurationAndTimeAreNotMistakenForTheEnd() {
        XCTAssertFalse(VideoTextureSource.hasRunOut(actual: 3, duration: 0, loops: true))
        XCTAssertFalse(VideoTextureSource.hasRunOut(actual: .nan, duration: duration, loops: true))
        XCTAssertFalse(VideoTextureSource.hasRunOut(actual: .infinity, duration: duration,
                                                    loops: true))
    }
}
