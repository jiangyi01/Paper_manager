import SwiftUI
import PaperDeckCore
import PaperDeckConfig

// MARK: - 个人资料 / Profile

/// Settings ▸ Profile: the profile editor (field, stage, reader, interests, institution) plus the
/// field's starter categories — [Add Missing Categories…] only inserts names the library lacks
/// (never renames or removes; capped by the engine).
struct ProfileSettingsTab: View {
    let state: AppState

    var body: some View {
        Form {
            ProfileEditor(settings: state.settings, context: .settings)
            StarterCategoriesSection(state: state)
        }
    }
}

private struct StarterCategoriesSection: View {
    let state: AppState
    @State private var confirm = false
    @State private var working = false
    @State private var result: (kind: StatusKind, text: String)?

    var body: some View {
        let field = state.settings.config.field
        let missing = Self.missing(field.starterCategories, existing: (state.snapshot?.categories ?? []).map(\.category.name))
        Section {
            Text(L.Profile.starterSuggested(field.name(L.lang), field.starterCategories.map(\.name).joined(separator: " · ")))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    confirm = true
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text(L.Profile.addMissingCategories) }
                }
                .disabled(working || missing.isEmpty || state.snapshot == nil)
                Spacer()
            }
            if let result {
                StatusLine(result.kind, result.text)
            } else if state.snapshot != nil, missing.isEmpty {
                StatusLine(.ok, L.Profile.noMissingCategories)
            }
        } header: {
            Text(L.Profile.starterSection)
        }
        .alert(L.Profile.addMissingTitle(missing.count), isPresented: $confirm) {
            Button(L.Profile.add) { add(missing) }
            Button(L.cancel, role: .cancel) {}
        } message: {
            Text(L.Profile.addMissingBody(missing.count))
        }
    }

    /// The pack's categories whose names the library doesn't have (case-insensitive).
    static func missing(_ pack: [StarterCategory], existing: [String]) -> [StarterCategory] {
        let have = Set(existing.map { $0.lowercased() })
        return pack.filter { !have.contains($0.name.lowercased()) }
    }

    private func add(_ pack: [StarterCategory]) {
        working = true
        result = nil
        let engine = state.engine
        Task {
            do {
                let n = try await engine.addMissingStarterCategories(pack)
                result = (.ok, L.Profile.addMissingDone(n))
                state.scheduleRefresh(delay: .zero)
            } catch {
                result = (.error, SettingsFormat.error(error))
            }
            working = false
        }
    }
}
