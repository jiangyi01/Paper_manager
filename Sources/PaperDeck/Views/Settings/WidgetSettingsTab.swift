import AppKit
import SwiftUI
import PaperDeckCore
import PaperDeckConfig

// MARK: - 小组件

struct WidgetSettingsTab: View {
    let state: AppState
    @State private var probe: PluginKitProbe.Result?
    @State private var probing = false
    @State private var refreshing = false
    @State private var refreshResult: (kind: StatusKind, text: String)?
    @State private var repairing = false
    @State private var repairResult: (kind: StatusKind, text: String)?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L.Pref.widgetIntroTitle).font(.headline)
                        Text(L.Pref.widgetIntro)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                registrationStatus
                if let probe, !probe.output.isEmpty {
                    Text(probe.output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            } header: {
                HStack {
                    Text(L.Pref.widgetStatusSection)
                    HelpButton(.fixWidgetMissing)
                    Spacer()
                    Button {
                        Task { await runProbe() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(probing)
                    .help(L.Pref.recheck)
                }
            }

            Section {
                ForEach(Array(L.Pref.widgetSteps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(i + 1)")
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .frame(width: 20, height: 20)
                            .background(.fill.tertiary, in: Circle())
                        Text(step).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text(L.Pref.widgetStepsSection)
            } footer: {
                NoteText(L.Pref.widgetStepsFooter)
            }

            Section {
                LabeledContent {
                    Button {
                        refresh()
                    } label: {
                        if refreshing { ProgressView().controlSize(.small) } else { Text(L.Pref.refresh) }
                    }
                    .disabled(refreshing)
                } label: {
                    Text(L.Pref.refreshWidget)
                    Text(L.Pref.refreshWidgetHint)
                }
                if let refreshResult { StatusLine(refreshResult.kind, refreshResult.text) }
                LabeledContent {
                    Button {
                        repair()
                    } label: {
                        if repairing { ProgressView().controlSize(.small) } else { Text(L.Pref.repairButton) }
                    }
                    .disabled(repairing || WidgetRegistration.appBundle == nil)
                } label: {
                    Text(L.Pref.repairRegistration)
                    Text(WidgetRegistration.appBundle == nil ? L.Pref.repairNeedsApp : L.Pref.repairRegistrationHint)
                }
                if let repairResult { StatusLine(repairResult.kind, repairResult.text) }
            }
        }
        .task { await runProbe() }
    }

    @ViewBuilder private var registrationStatus: some View {
        if probing && probe == nil {
            StatusLine(.working, L.Pref.checking)
        } else if let probe {
            if probe.failed {
                StatusLine(.error, L.Pref.widgetProbeFailed)
            } else if probe.output.isEmpty {
                StatusLine(.warning, L.Pref.widgetNotRegistered)
            } else if probe.isDisabled {
                StatusLine(.warning, L.Pref.widgetDisabled)
            } else {
                StatusLine(.ok, L.Pref.widgetRegistered)
            }
        }
    }

    private func runProbe() async {
        probing = true
        probe = await PluginKitProbe.query()
        probing = false
    }

    /// Repair Registration: `lsregister -f -R -trusted` on the app, `pluginkit -a` on its widget,
    /// then the status is probed again.
    private func repair() {
        guard let app = WidgetRegistration.appBundle else { return }
        repairing = true
        repairResult = nil
        Task {
            let failure = await WidgetRegistration.repair(app: app)
            await runProbe()
            repairResult = failure.map { (.error, L.Pref.repairFailed($0)) } ?? (.ok, L.Pref.repairDone)
            repairing = false
        }
    }

    private func refresh() {
        refreshing = true
        refreshResult = nil
        let engine = state.engine
        Task {
            do {
                let changed = try await engine.writeWidgetSnapshot()
                DerivedRefresher.reloadWidgets()
                refreshResult = (.ok, L.Pref.widgetRefreshed(changed: changed, at: SettingsFormat.time(Date())))
            } catch {
                refreshResult = (.error, SettingsFormat.error(error))
            }
            refreshing = false
        }
    }
}

/// Settings ▸ Widget ▸ Repair registration: registers the running app bundle and its widget
/// extension with LaunchServices and PlugInKit again (both system binaries; nothing else runs).
nonisolated enum WidgetRegistration {
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    static let pluginkit = "/usr/bin/pluginkit"

    /// The running `.app` (nil for a bare `swift build` binary).
    static var appBundle: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    /// The widget extension inside `app`.
    static func appex(in app: URL) -> URL {
        app.appendingPathComponent("Contents/PlugIns/PaperDeckWidget.appex", isDirectory: true)
    }

    /// The two commands, in order.
    static func commands(app: URL) -> [(executable: String, arguments: [String])] {
        [(lsregister, ["-f", "-R", "-trusted", app.path]), (pluginkit, ["-a", appex(in: app).path])]
    }

    /// nil on success, else the failing command's message.
    static func repair(app: URL) async -> String? {
        let runner = ProcessRunner(interruptGrace: .seconds(1), terminateGrace: .seconds(1))
        let env = ["HOME": SharedPaths.realHome.path, "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        for c in commands(app: app) {
            do {
                let r = try await runner.run(.init(executable: c.executable, arguments: c.arguments, environment: env,
                                                   currentDirectory: NSTemporaryDirectory(), timeout: .seconds(30)))
                if r.timedOut { return "\((c.executable as NSString).lastPathComponent): timed out" }
                if r.exitCode != 0 {
                    let err = String(decoding: r.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    return "\((c.executable as NSString).lastPathComponent) (\(r.exitCode))" + (err.isEmpty ? "" : ": " + String(err.prefix(200)))
                }
            } catch {
                return String(describing: error)
            }
        }
        return nil
    }
}
