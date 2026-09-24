import SwiftUI

struct WidgetStudio: View {
    @EnvironmentObject var widgets: DesktopWidgets
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow(text: "MAKE SPACE FOR WHAT MATTERS")
                        Text("Widget studio").font(
                            .system(size: 29, weight: .semibold, design: .rounded))
                        Text("Native essentials. Your own designs. One desktop.").foregroundStyle(
                            .secondary)
                    }
                    Spacer()
                    Button(widgets.editing ? "Done editing" : "Edit on desktop") {
                        widgets.setEditing(!widgets.editing)
                    }.buttonStyle(VioletButtonStyle())
                }
                HStack {
                    Text(
                        "Each widget moves on its own. Enter Edit Mode, drag it into place, then choose Done."
                    ).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("All displays", isOn: $widgets.settings.allDisplays).toggleStyle(.switch)
                        .controlSize(.small)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 400))], spacing: 14) {
                    ForEach(WidgetKind.allCases) { kind in independentCard(kind) }
                }
                HStack {
                    Text("500 ms system readings · 60-second network history").font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset sizes & positions") { widgets.resetLayout() }
                }
                CustomWidgetEditor(widgets: widgets)
                Text(
                    "Network shows combined Ethernet/Wi-Fi traffic (not per-app), avoiding VPN double-counting. CPU is the average over each sample interval. RAM estimates active, wired and compressed physical memory; it differs from Activity Monitor’s Memory Used. Custom web widgets use more resources than native widgets."
                ).font(.caption).foregroundStyle(.secondary)
            }.padding(26)
        }.background(AmbientTheme.background)
    }
    private func independentCard(_ kind: WidgetKind) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(kind.title, systemImage: kind.icon).font(.headline).foregroundStyle(
                    AmbientTheme.lavender)
                Spacer()
                Toggle(
                    kind.title,
                    isOn: Binding(
                        get: { widgets.enabled(kind) }, set: { widgets.setEnabled(kind, $0) })
                ).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if kind == .custom {
                VStack(spacing: 8) {
                    Image(systemName: "curlybraces").font(.title)
                    Text(widgets.custom.name).font(.caption)
                }.frame(maxWidth: .infinity).frame(height: 90).foregroundStyle(.secondary)
            } else {
                SingleWidgetFace(readings: widgets.readings, kind: kind, scale: 0.75).frame(
                    maxWidth: .infinity
                ).frame(height: 90)
            }
            HStack {
                Text("Size").font(.caption).foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { widgets.scale(kind) }, set: { widgets.setScale(kind, $0) }),
                    in: 0.6...2.5
                ).accessibilityLabel(kind.title + " size")
                Text(String(format: "%.0f%%", widgets.scale(kind) * 100)).font(
                    .caption.monospacedDigit()
                ).frame(width: 36)
            }
        }.padding(16).background(AmbientTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14).stroke(
                    widgets.enabled(kind) ? AmbientTheme.accent.opacity(0.4) : AmbientTheme.border))
    }

}

// The editor holds large HTML/CSS text. It reads DesktopWidgets without observing it, so moving
// a size slider or toggling a widget does not re-render the text editor. Only the small status
// views below observe widget state.
private struct CustomWidgetEditor: View {
    let widgets: DesktopWidgets
    @State private var draft = CustomWidgetPackage.starter
    @State private var editorTab = "HTML"
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Build your own").font(.headline)
                    Text("Style a widget with HTML and CSS, then apply it to your desktop.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import JSON") {
                    if let imported = widgets.importCustom() { draft = imported }
                }
                Button("Export JSON") { widgets.exportCustom(draft) }
            }
            HStack {
                TextField("Widget name", text: $draft.name).textFieldStyle(.roundedBorder)
                Text("Height").foregroundStyle(.secondary)
                TextField("Height", value: $draft.height, format: .number).frame(width: 65)
                    .textFieldStyle(.roundedBorder)
                Text("pt").foregroundStyle(.secondary)
            }
            Picker("Code", selection: $editorTab) {
                Text("HTML").tag("HTML")
                Text("CSS").tag("CSS")
            }.pickerStyle(.segmented).frame(width: 200)
            TextEditor(text: editorTab == "HTML" ? $draft.html : $draft.css)
                .font(.system(size: 12, design: .monospaced)).scrollContentBackground(
                    .hidden
                )
                .padding(10).frame(height: 260).background(
                    .black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            Text(
                "Live fields: data-ambient=\"time\", \"date\", \"cpu\", \"memory\", \"download\", \"upload\". CSS receives --cpu and --memory as percentages. Use inline HTML/CSS or embedded data images. External resources and page JavaScript are disabled."
            )
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            .textSelection(.enabled)
            WidgetErrorText(widgets: widgets)
            HStack {
                Button("Load starter") { draft = .starter }
                DraftStatus(widgets: widgets, draft: draft)
                Spacer()
                Button("Apply code") {
                    widgets.applyCustom(draft)
                    if widgets.error == nil { widgets.customEnabled = true }
                }.buttonStyle(VioletButtonStyle())
            }
        }.padding(20).background(
            AmbientTheme.surface, in: RoundedRectangle(cornerRadius: 16)
        ).onAppear { draft = widgets.custom }
    }
}
private struct WidgetErrorText: View {
    @ObservedObject var widgets: DesktopWidgets
    var body: some View {
        if let error = widgets.error {
            Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
        }
    }
}
private struct DraftStatus: View {
    @ObservedObject var widgets: DesktopWidgets
    let draft: CustomWidgetPackage
    var body: some View {
        Text(draft == widgets.custom ? "Saved" : "Unapplied changes").font(.caption)
            .foregroundStyle(.secondary)
    }
}
