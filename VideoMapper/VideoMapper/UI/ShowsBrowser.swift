import SwiftUI

/// Saved shows: open, create, duplicate-free deletion.
struct ShowsBrowser: View {
    @ObservedObject var controller: ShowController
    @Environment(\.dismiss) private var dismiss
    @State private var shows: [MappingProject] = []
    @State private var renaming = false
    @State private var draftName = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Current") {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(controller.project.name)
                            Text("\(controller.project.layers.count) layer(s)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Rename") {
                            draftName = controller.project.name
                            renaming = true
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Section("Saved") {
                    ForEach(otherShows) { show in
                        Button {
                            controller.openProject(show)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading) {
                                Text(show.name).foregroundStyle(.primary)
                                Text(show.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: delete)

                    if otherShows.isEmpty {
                        Text("No other shows yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Shows")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        controller.saveNow()
                        var fresh = MappingProject.demo
                        fresh.name = "Show \(shows.count + 1)"
                        controller.openProject(fresh)
                        dismiss()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New show")
                }
            }
            .alert("Rename show", isPresented: $renaming) {
                TextField("Name", text: $draftName)
                Button("Save") {
                    controller.project.name = draftName
                    controller.saveNow()
                    refresh()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .onAppear {
            controller.saveNow()
            refresh()
        }
    }

    private var otherShows: [MappingProject] {
        shows.filter { $0.id != controller.project.id }
    }

    private func refresh() {
        shows = ProjectStore.shared.loadAll()
    }

    private func delete(at offsets: IndexSet) {
        let targets = offsets.map { otherShows[$0] }
        for show in targets {
            try? ProjectStore.shared.delete(id: show.id)
        }
        refresh()
    }
}
