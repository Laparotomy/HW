import XCTest
@testable import VideoMapper

/// What happens to a show on disk.
///
/// This is the layer with the worst failure mode in the app: everything else draws
/// the wrong thing until you fix it, and this loses work that cannot be got back. The
/// store writes into a temporary directory here rather than the real Documents
/// folder, because it is a class that deletes folders.
final class ProjectStoreTests: XCTestCase {

    private var root: URL!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoMapperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ProjectStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        store = nil
    }

    /// Writes a file of `bytes` bytes and hands back a reference to it, as if it had
    /// been imported.
    @discardableResult
    private func plant(_ name: String, in projectID: UUID, bytes: Int = 8) throws -> MediaReference {
        try store.prepareFolders(for: projectID)
        let data = Data(repeating: 0x2a, count: bytes)
        try data.write(to: store.mediaFolder(for: projectID).appendingPathComponent(name))
        return MediaReference(kind: .video, filename: name, displayName: name,
                              pixelSize: .zero, duration: 1)
    }

    private func files(in projectID: UUID) -> Set<String> {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: store.mediaFolder(for: projectID), includingPropertiesForKeys: nil)) ?? []
        return Set(urls.map(\.lastPathComponent))
    }

    // MARK: - Round trip

    func testASavedShowComesBackWithItsLayers() throws {
        var project = MappingProject(name: "Round trip")
        project.canvasSize = CGSize(width: 1280, height: 1024)
        project.layers = [MappingLayer.make(generator: .nebula), MappingLayer(name: "Wash")]
        project.layers[0].transform.setMeshDivisions(columns: 3, rows: 2)
        try store.save(project)

        let loaded = try store.load(id: project.id)
        XCTAssertEqual(loaded.id, project.id)
        XCTAssertEqual(loaded.name, "Round trip")
        XCTAssertEqual(loaded.layers, project.layers)
        XCTAssertEqual(loaded.canvasSize, CGSize(width: 1280, height: 1024))
    }

    /// Saving stamps the modification date. It is what the browser sorts on, so a
    /// save that left it alone would bury the show you just worked on.
    func testSavingStampsTheModificationDate() throws {
        var project = MappingProject(name: "Stamped")
        project.modifiedAt = Date(timeIntervalSince1970: 0)
        try store.save(project)

        let loaded = try store.load(id: project.id)
        XCTAssertGreaterThan(loaded.modifiedAt.timeIntervalSince1970, 1_000_000)
        // The caller's own copy is untouched: save takes a value, not a reference.
        XCTAssertEqual(project.modifiedAt, Date(timeIntervalSince1970: 0))
    }

    func testLoadingAShowThatWasNeverSavedThrows() {
        XCTAssertThrowsError(try store.load(id: UUID()))
    }

    // MARK: - Listing

    func testEveryShowIsListedNewestFirst() throws {
        var older = MappingProject(name: "Older")
        older.modifiedAt = Date(timeIntervalSince1970: 100)
        var newer = MappingProject(name: "Newer")
        newer.modifiedAt = Date(timeIntervalSince1970: 200)

        // Saved in the wrong order on purpose: the sort must come from the stamp.
        try store.save(newer)
        try store.save(older)

        let all = store.loadAll()
        XCTAssertEqual(all.count, 2)
        XCTAssertGreaterThanOrEqual(all[0].modifiedAt, all[1].modifiedAt)
    }

    func testAnEmptyStoreListsNothingRatherThanFailing() {
        XCTAssertTrue(store.loadAll().isEmpty)
    }

    /// One corrupt show must not take the rest of someone's work down with it.
    func testACorruptShowIsSkippedAndTheOthersStillLoad() throws {
        let good = MappingProject(name: "Good")
        try store.save(good)

        let broken = UUID()
        try store.prepareFolders(for: broken)
        try Data("this is not json".utf8)
            .write(to: store.folder(for: broken).appendingPathComponent("project.json"))

        let all = store.loadAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "Good")
    }

    /// A stray folder that is not a show id is not a show.
    func testAFolderThatIsNotAShowIsIgnored() throws {
        try store.save(MappingProject(name: "Real"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("not-a-uuid"), withIntermediateDirectories: true)
        XCTAssertEqual(store.loadAll().count, 1)
    }

    // MARK: - Deleting

    func testDeletingTakesTheWholeFolder() throws {
        let project = MappingProject(name: "Doomed")
        try store.save(project)
        try plant("clip.mov", in: project.id)

        try store.delete(id: project.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(for: project.id).path))
        XCTAssertTrue(store.loadAll().isEmpty)
    }

    // MARK: - Media

    func testImportingCopiesTheFileAndLeavesTheOriginal() throws {
        let project = MappingProject(name: "Import")
        let source = root.appendingPathComponent("outside.mov")
        try Data(repeating: 1, count: 32).write(to: source)

        let ref = try store.importMedia(from: source, kind: .video, displayName: "Clip",
                                        pixelSize: CGSize(width: 1920, height: 1080),
                                        duration: 12, projectID: project.id)

        XCTAssertEqual(ref.displayName, "Clip")
        XCTAssertEqual(ref.duration, 12, accuracy: 1e-9)
        XCTAssertTrue(ref.filename.hasSuffix(".mov"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.mediaURL(for: ref, projectID: project.id).path))
        // The source is the user's own file, wherever it came from.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    /// Two clips called `IMG_0001.mov` is the normal case, not the odd one.
    func testTwoImportsOfTheSameNameBothSurvive() throws {
        let project = MappingProject(name: "Collide")
        let source = root.appendingPathComponent("IMG_0001.mov")
        try Data(repeating: 2, count: 16).write(to: source)

        let first = try store.importMedia(from: source, kind: .video, displayName: "A",
                                          pixelSize: .zero, duration: 1, projectID: project.id)
        let second = try store.importMedia(from: source, kind: .video, displayName: "B",
                                           pixelSize: .zero, duration: 1, projectID: project.id)

        XCTAssertNotEqual(first.filename, second.filename)
        XCTAssertEqual(files(in: project.id).count, 2)
    }

    func testWritingBytesDirectlyLandsInTheMediaFolder() throws {
        let project = MappingProject(name: "Scan")
        let name = try store.writeMedia(Data(repeating: 9, count: 4), extension: "jpg",
                                        projectID: project.id)
        XCTAssertTrue(name.hasSuffix(".jpg"))
        XCTAssertEqual(files(in: project.id), [name])
    }

    // MARK: - Pruning

    func testPruningKeepsWhatIsReferencedAndDropsWhatIsNot() throws {
        var project = MappingProject(name: "Prune")
        let used = try plant("used.mov", in: project.id)
        try plant("orphan.mov", in: project.id)
        project.layers = [MappingLayer(name: "Clip", content: .video(used, VideoPlayback()))]

        store.pruneMedia(for: project)
        XCTAssertEqual(files(in: project.id), ["used.mov"])
    }

    /// A texture overlay and the audio track are references too. Pruning that only
    /// looked at layer content would delete the music out from under a show.
    func testPruningCountsTexturesScansAndTheTrack() throws {
        var project = MappingProject(name: "Everything")
        let texture = try plant("overlay.png", in: project.id)
        let track = try plant("song.m4a", in: project.id)
        try plant("wall.jpg", in: project.id)
        try plant("orphan.mov", in: project.id)

        var layer = MappingLayer(name: "Wash")
        layer.appearance.texture.pattern = .custom
        layer.appearance.texture.image = texture
        project.layers = [layer]
        project.audio.track = track
        project.scans = [SurfaceScan(name: "Wall", imageFilename: "wall.jpg",
                                     camera: ScanCamera(focalX: 1, focalY: 1,
                                                        principalX: 1, principalY: 1,
                                                        imageWidth: 2, imageHeight: 2),
                                     depth: nil)]

        store.pruneMedia(for: project)
        XCTAssertEqual(files(in: project.id), ["overlay.png", "song.m4a", "wall.jpg"])
    }

    func testPruningAProjectWithNoMediaFolderIsSafe() {
        store.pruneMedia(for: MappingProject(name: "Nothing on disk"))
    }

    // MARK: - Paths

    func testAShowIsOneSelfContainedFolder() throws {
        let project = MappingProject(name: "Self contained")
        try store.save(project)
        let ref = try plant("clip.mov", in: project.id)

        let folder = store.folder(for: project.id)
        XCTAssertEqual(store.mediaFolder(for: project.id).deletingLastPathComponent(), folder)
        XCTAssertTrue(store.mediaURL(for: ref, projectID: project.id).path.hasPrefix(folder.path))
    }

    func testTwoShowsDoNotShareAFolder() {
        XCTAssertNotEqual(store.folder(for: UUID()), store.folder(for: UUID()))
    }
}
