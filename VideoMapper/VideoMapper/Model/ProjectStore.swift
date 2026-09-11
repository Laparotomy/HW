import Foundation
import os

/// On-disk layout for shows.
///
/// ```
/// Documents/Shows/<uuid>/project.json
/// Documents/Shows/<uuid>/Media/<file>
/// ```
///
/// Keeping media beside the JSON means a show is a single self-contained folder
/// that can be zipped, AirDropped, or copied out over the Files app.
final class ProjectStore {
    static let shared = ProjectStore()

    private let log = Logger(subsystem: "app.videomapper", category: "ProjectStore")
    private let fileManager = FileManager.default

    private var showsRoot: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Shows", isDirectory: true)
    }

    func folder(for projectID: UUID) -> URL {
        showsRoot.appendingPathComponent(projectID.uuidString, isDirectory: true)
    }

    func mediaFolder(for projectID: UUID) -> URL {
        folder(for: projectID).appendingPathComponent("Media", isDirectory: true)
    }

    func mediaURL(for ref: MediaReference, projectID: UUID) -> URL {
        mediaFolder(for: projectID).appendingPathComponent(ref.filename)
    }

    private func projectFile(for projectID: UUID) -> URL {
        folder(for: projectID).appendingPathComponent("project.json")
    }

    func prepareFolders(for projectID: UUID) throws {
        try fileManager.createDirectory(at: mediaFolder(for: projectID),
                                        withIntermediateDirectories: true)
    }

    // MARK: - Load / save

    func save(_ project: MappingProject) throws {
        try prepareFolders(for: project.id)
        var copy = project
        copy.modifiedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(copy)
        // Atomic so a crash mid-write cannot leave a truncated show behind.
        try data.write(to: projectFile(for: project.id), options: .atomic)
    }

    func load(id: UUID) throws -> MappingProject {
        let data = try Data(contentsOf: projectFile(for: id))
        return try JSONDecoder().decode(MappingProject.self, from: data)
    }

    /// Every saved show, newest first. Unreadable folders are skipped rather than
    /// failing the whole listing.
    func loadAll() -> [MappingProject] {
        guard let entries = try? fileManager.contentsOfDirectory(at: showsRoot,
                                                                 includingPropertiesForKeys: nil)
        else { return [] }
        return entries.compactMap { url in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            do { return try load(id: id) } catch {
                log.error("Skipping unreadable show \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func delete(id: UUID) throws {
        try fileManager.removeItem(at: folder(for: id))
    }

    // MARK: - Media

    /// Copies an imported file into the show folder and returns its reference.
    /// The filename is uniqued so importing two clips called `IMG_0001.mov` works.
    func importMedia(from source: URL, kind: MediaReference.Kind, displayName: String,
                     pixelSize: CGSize, duration: Double, projectID: UUID) throws -> MediaReference {
        try prepareFolders(for: projectID)
        let ext = source.pathExtension.isEmpty ? (kind == .video ? "mov" : "png") : source.pathExtension
        let filename = "\(UUID().uuidString).\(ext)"
        let destination = mediaFolder(for: projectID).appendingPathComponent(filename)
        try fileManager.copyItem(at: source, to: destination)
        return MediaReference(kind: kind, filename: filename, displayName: displayName,
                              pixelSize: pixelSize, duration: duration)
    }

    /// Removes media files no layer references any more.
    func pruneMedia(for project: MappingProject) {
        let keep = project.referencedMedia
        guard let files = try? fileManager.contentsOfDirectory(at: mediaFolder(for: project.id),
                                                               includingPropertiesForKeys: nil)
        else { return }
        for file in files where !keep.contains(file.lastPathComponent) {
            try? fileManager.removeItem(at: file)
        }
    }
}
