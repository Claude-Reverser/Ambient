import AppKit
import ServiceManagement
import SwiftUI

final class AmbientDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main struct AmbientApp: App {
    @NSApplicationDelegateAdaptor(AmbientDelegate.self) private var delegate
    @StateObject private var widgets = DesktopWidgets()
    @StateObject private var library: Library
    init() {
        if CommandLine.arguments.contains("--benchmark") {
            let suite = UserDefaults(suiteName: "local.ambient.benchmark")!
            _library = StateObject(
                wrappedValue: Library(
                    storage: FileManager.default.temporaryDirectory.appendingPathComponent(
                        "Ambient-benchmark-no-library.json"), defaults: suite))
        } else {
            _library = StateObject(wrappedValue: Library())
        }
    }
    var body: some Scene {
        Window("Ambient", id: "library") {
            LibraryView().environmentObject(library).environmentObject(widgets)
                .frame(minWidth: 1040, minHeight: 740).preferredColorScheme(.dark).tint(
                    AmbientTheme.accent
                )
                .task { await Benchmark.runIfRequested(library) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 830)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Wallpaper…") { library.importFiles() }.keyboardShortcut("o")
            }
            CommandMenu("Wallpaper") {
                Button("Apply Selected") {
                    if let item = library.items.first(where: { $0.id == library.selected }) {
                        library.apply(item)
                    }
                }.keyboardShortcut(.return, modifiers: .command).disabled(library.selected == nil)
                Button(library.manuallyPaused ? "Resume" : "Pause") {
                    library.manuallyPaused.toggle()
                }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(
                    library.active == nil)
                Button("Stop") { library.stop() }
            }
        }
        MenuBarExtra("Ambient", systemImage: "waveform.path") {
            AmbientMenu().environmentObject(library).environmentObject(widgets)
        }

    }
}

struct AmbientMenu: View {
    @EnvironmentObject private var widgets: DesktopWidgets
    @EnvironmentObject private var library: Library
    @Environment(\.openWindow) private var openWindow
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    var body: some View {
        Text(library.status)
        Button("Open Wallpaper Library") {
            openWindow(id: "library")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button(widgets.editing ? "Done Editing Widgets" : "Edit Desktop Widgets") {
            widgets.setEditing(!widgets.editing)
        }
        Toggle("Pause Wallpapers", isOn: $library.manuallyPaused).disabled(library.active == nil)
        Picker("Quality", selection: $library.profile) {
            ForEach(QualityProfile.allCases) { Text($0.title).tag($0) }
        }
        Toggle("Pause on Battery", isOn: $library.pauseOnBattery)
        Button("Stop Wallpapers") { library.stop() }.disabled(library.active == nil)
        Divider()
        Toggle(
            "Launch at Login",
            isOn: Binding(
                get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                set: { enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                        loginError = nil
                    } catch { loginError = error.localizedDescription }
                    loginStatus = SMAppService.mainApp.status
                }))
        if loginStatus == .requiresApproval {
            Button("Approve in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
        }
        if let loginError { Text(loginError) }
        Divider()
        Button("Quit Ambient") {
            library.stop(preserveSelection: true)
            NSApp.terminate(nil)
        }.keyboardShortcut("q")
        Text("Closing the library keeps wallpapers running.")
            .onAppear { loginStatus = SMAppService.mainApp.status }
    }
}
