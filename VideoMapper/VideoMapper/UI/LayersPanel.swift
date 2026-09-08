import PhotosUI
import SwiftUI

/// Layer stack: order, visibility, and the entry points for adding content.
///
/// The list is shown top-of-stack first, which is how the eye reads a projection,
/// while the model stores back-to-front draw order.
struct LayersPanel: View {
    @ObservedObject var controller: ShowController
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            List {
                ForEach(displayLayers) { layer in
                    row(for: layer)
                        .listRowBackground(layer.id == controller.selectedLayerID
                                           ? Color.accentColor.opacity(0.15) : Color.clear)
                }
                .onDelete(perform: delete)
                .onMove(perform: move)
            }
            .listStyle(.plain)
            .environment(\.editMode, .constant(.active))
        }
        .photosPicker(isPresented: $isImporting, selection: $pickerItems,
                      maxSelectionCount: 8, matching: .any(of: [.images, .videos]))
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            importPicked(items)
        }
        .alert("Import failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private var displayLayers: [MappingLayer] {
        controller.project.layers.reversed()
    }

    private var header: some View {
        HStack(spacing: 16) {
            Button {
                isImporting = true
            } label: {
                Label("Media", systemImage: "photo.on.rectangle.angled")
            }
            Button {
                controller.addColorLayer()
            } label: {
                Label("Colour", systemImage: "paintpalette")
            }
            Spacer()
            if let id = controller.selectedLayerID {
                Button {
                    controller.duplicateLayer(id: id)
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .accessibilityLabel("Duplicate layer")
            }
        }
        .buttonStyle(.bordered)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func row(for layer: MappingLayer) -> some View {
        HStack(spacing: 12) {
            Button {
                controller.updateLayer(id: layer.id) { $0.isVisible.toggle() }
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.isVisible ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(layer.name).lineLimit(1)
                Text(subtitle(for: layer))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !layer.modulation.isEmpty {
                Image(systemName: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Audio reactive")
            }
            Button {
                controller.updateLayer(id: layer.id) { $0.isLocked.toggle() }
            } label: {
                Image(systemName: layer.isLocked ? "lock" : "lock.open")
                    .foregroundStyle(layer.isLocked ? Color.orange : Color.secondary)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture { controller.selectedLayerID = layer.id }
    }

    private func subtitle(for layer: MappingLayer) -> String {
        var parts = [layer.content.displayName]
        if layer.appearance.blendMode != .normal { parts.append(layer.appearance.blendMode.displayName) }
        if layer.transform.isWarped { parts.append("warped") }
        return parts.joined(separator: " · ")
    }

    /// The list is reversed for display, so indices have to be flipped back.
    private func delete(at offsets: IndexSet) {
        let ids = offsets.map { displayLayers[$0].id }
        for id in ids { controller.deleteLayer(id: id) }
    }

    private func move(from source: IndexSet, to destination: Int) {
        let count = controller.project.layers.count
        let mappedSource = IndexSet(source.map { count - 1 - $0 })
        let mappedDestination = count - destination
        controller.moveLayers(from: mappedSource, to: mappedDestination)
    }

    private func importPicked(_ items: [PhotosPickerItem]) {
        pickerItems = []
        Task { @MainActor in
            for item in items {
                do {
                    let ref = try await MediaImporter.importItem(item, projectID: controller.project.id)
                    controller.attachMedia(ref)
                } catch {
                    importError = error.localizedDescription
                }
            }
            controller.saveNow()
        }
    }
}
