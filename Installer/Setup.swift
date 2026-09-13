import AppKit
import SwiftUI

final class SetupDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { closeDiskWindow() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
        -> Bool
    {
        closeDiskWindow()
        return true
    }
    private func closeDiskWindow() {
        let container = Bundle.main.bundleURL.deletingLastPathComponent()
        guard
            let values = try? container.resourceValues(forKeys: [
                .volumeIsReadOnlyKey, .volumeIsLocalKey,
            ]),
            values.volumeIsReadOnly == true, values.volumeIsLocal == true
        else { return }
        let pids = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.finder"
        ).map(\.processIdentifier)
        DispatchQueue.global(qos: .utility).async {
            FinderWindowCloser.close(container: container, pids: pids)
        }
    }
}

@main struct AmbientSetup: App {
    @NSApplicationDelegateAdaptor(SetupDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Ambient Setup") { SetupView() }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
    }
}
struct SetupView: View {
    @Environment(\.scenePhase) private var phase
    @State private var busy = false
    @State private var message = ""
    @State private var installed: URL?
    private var payload: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Ambient.app")
    }
    var body: some View {
        ZStack {
            Color(red: 0.045, green: 0.025, blue: 0.085)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: phase != .active)) {
                timeline in
                Canvas { context, size in
                    let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(
                        dividingBy: 120)
                    for layer in 0..<3 {
                        var path = Path()
                        let base = size.height * (0.64 + Double(layer) * 0.075)
                        path.move(to: CGPoint(x: 0, y: size.height))
                        for x in stride(from: 0.0, through: size.width, by: 5) {
                            let y =
                                base + sin(x / 155 + t * 0.3 + Double(layer)) * 32 + sin(
                                    x / 280 - t * 0.19) * 22
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                        path.addLine(to: CGPoint(x: size.width, y: size.height))
                        path.closeSubpath()
                        context.fill(
                            path,
                            with: .linearGradient(
                                Gradient(colors: [
                                    Color.purple.opacity(0.36),
                                    Color(red: 0.32, green: 0.12, blue: 0.64).opacity(0.12),
                                ]), startPoint: .zero,
                                endPoint: CGPoint(x: size.width, y: size.height)))
                    }
                }
            }.allowsHitTesting(false)
            VStack(spacing: 16) {
                if let icon = NSImage(
                    contentsOf: payload.appendingPathComponent("Contents/Resources/Ambient.icns"))
                {
                    Image(nsImage: icon).resizable().frame(width: 116, height: 116)
                }
                Text("Make room for a little motion.").font(.system(size: 30, weight: .semibold))
                Text("Install Ambient and bring your desktop to life.").foregroundStyle(
                    .white.opacity(0.65))
                Spacer().frame(height: 18)
                Button(action: install) {
                    HStack {
                        if busy { ProgressView().controlSize(.small) }
                        Text(busy ? "Installing…" : "Install Ambient")
                        Image(systemName: "arrow.down.to.line")
                    }
                    .font(.system(size: 16, weight: .semibold)).padding(.horizontal, 26).padding(
                        .vertical, 12)
                }.buttonStyle(.borderedProminent).tint(Color(red: 0.55, green: 0.28, blue: 0.9))
                    .disabled(busy || installed != nil)
                if let installed {
                    Button("Open Ambient") { NSWorkspace.shared.open(installed) }.buttonStyle(
                        .bordered)
                }
                Text(
                    message.isEmpty
                        ? "Choose Applications in the next window. No administrator helper required."
                        : message
                )
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center).frame(maxWidth: 520)
                Spacer().frame(height: 8)
                Text("APPLE SILICON  •  macOS 14+").font(.system(size: 10, weight: .medium))
                    .tracking(2).foregroundStyle(.white.opacity(0.4))
            }.padding(40)
        }.frame(width: 720, height: 470).preferredColorScheme(.dark)
    }
    private func install() {
        let panel = NSOpenPanel()
        panel.title = "Install Ambient"
        panel.message = "Choose Applications, or another folder where you want Ambient installed."
        panel.prompt = "Install Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let destination = folder.appendingPathComponent("Ambient.app")
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            message =
                "Ambient already exists there. Use Finder to replace it, or choose another folder."
            return
        }
        guard
            FileManager.default.fileExists(
                atPath: payload.appendingPathComponent("Contents/MacOS/Ambient").path)
        else {
            message = "The bundled Ambient app is missing. Download a fresh installer."
            return
        }
        busy = true
        message = ""
        let source = payload
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let staging = folder.appendingPathComponent(
                        ".Ambient-install-" + UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: staging) }
                    try FileManager.default.copyItem(at: source, to: staging)
                    try FileManager.default.moveItem(at: staging, to: destination)
                }.value
                installed = destination
                message = "Installed successfully. You can close setup and eject the disk image."
            } catch { message = "Installation failed: \(error.localizedDescription)" }
            busy = false
        }
    }
}
