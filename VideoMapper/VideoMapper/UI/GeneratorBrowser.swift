import SwiftUI

/// The abstract source library.
///
/// Picking one adds a canvas-filling layer immediately rather than opening another
/// configuration step — the fastest way to judge a source is to see it on the wall,
/// and every parameter stays editable in the inspector afterwards.
struct GeneratorBrowser: View {
    @ObservedObject var controller: ShowController
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(GeneratorKind.allCases) { kind in
                        Button {
                            controller.addGeneratorLayer(kind)
                            dismiss()
                        } label: {
                            cell(for: kind)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()

                Text("""
                     Sources are generated on the GPU, so they have no resolution \
                     limit, never loop, and add nothing to the size of a show. Every \
                     one can be recoloured, warped and driven by the music once it \
                     is on the stage.
                     """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 24)
            }
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
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
