import SwiftUI

/// The abstract source library.
///
/// Picking one adds a canvas-filling layer immediately rather than opening another
/// configuration step — the fastest way to judge a source is to see it on the wall,
/// and every parameter stays editable in the inspector afterwards.
struct GeneratorBrowser: View {
    @ObservedObject var controller: ShowController
    /// When set, picking a source fills that layer instead of adding a new one, so a
    /// surface you already aligned keeps its mapping.
    var replacingLayerID: UUID?
    @Environment(\.dismiss) private var dismiss

    /// Nil shows every shelf at once, which is how you browse; a family shows one,
    /// which is how you find the thing you already had in mind.
    @State private var family: GeneratorFamily?
    @State private var search = ""

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                shelfPicker

                if matches.isEmpty {
                    ContentUnavailableView.search(text: search)
                        .padding(.top, 40)
                } else {
                    ForEach(shownFamilies) { shelf in
                        let kinds = matches.filter { $0.family == shelf }
                        if !kinds.isEmpty {
                            section(shelf, kinds: kinds)
                        }
                    }
                }

                Text("""
                     Sources are generated on the GPU, so they have no resolution \
                     limit, never loop, and add nothing to the size of a show. Every \
                     one can be recoloured, warped and driven by the music once it \
                     is on the stage.
                     """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
            }
            .searchable(text: $search, prompt: "Find a source")
            .navigationTitle(replacingLayerID == nil ? "Sources" : "Fill Layer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Filtering

    /// Searching looks at the description as well as the name, because what you
    /// remember about a source is usually what it looked like — "columns", "beat",
    /// "smoke" — and not what it was called.
    private var matches: [GeneratorKind] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return GeneratorKind.allCases.filter { kind in
            guard family == nil || kind.family == family else { return false }
            guard !query.isEmpty else { return true }
            return kind.displayName.lowercased().contains(query)
                || kind.detail.lowercased().contains(query)
                || kind.family.displayName.lowercased().contains(query)
        }
    }

    private var shownFamilies: [GeneratorFamily] {
        if let family { return [family] }
        return GeneratorFamily.allCases
    }

    // MARK: - Pieces

    private var shelfPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", symbol: "square.grid.2x2", isOn: family == nil) {
                    family = nil
                }
                ForEach(GeneratorFamily.allCases) { shelf in
                    chip(title: shelf.displayName, symbol: shelf.symbolName,
                         isOn: family == shelf) {
                        family = family == shelf ? nil : shelf
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 4)
        }
    }

    private func chip(title: String, symbol: String, isOn: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Capsule().fill(isOn ? Color.accentColor : Color.secondary.opacity(0.15)))
                .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private func section(_ shelf: GeneratorFamily, kinds: [GeneratorKind]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shelf.displayName)
                    .font(.headline)
                Text(shelf.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 12)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(kinds) { kind in
                    Button {
                        pick(kind)
                    } label: {
                        cell(for: kind)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    private func pick(_ kind: GeneratorKind) {
        if let id = replacingLayerID {
            controller.setContent(.generator(kind, kind.defaultSettings), forLayer: id)
        } else {
            controller.addGeneratorLayer(kind)
        }
        controller.saveNow()
        dismiss()
    }

    private func cell(for kind: GeneratorKind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            preview(for: kind)
            Text(kind.displayName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            Text(kind.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3, reservesSpace: true)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.displayName). \(kind.detail)")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func preview(for kind: GeneratorKind) -> some View {
        // Falls back to the symbol on a device where the preview could not render,
        // so the library is still usable rather than a grid of black rectangles.
        if let image = GeneratorThumbnailRenderer.shared.image(for: kind) {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(16.0 / 9.0, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay {
                    Image(systemName: kind.symbolName)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
        }
    }
}
