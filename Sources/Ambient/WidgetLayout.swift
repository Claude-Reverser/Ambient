import AppKit
import SwiftUI

enum WidgetKind: String, CaseIterable, Identifiable, Codable {
    case clock, date, cpu, memory, network, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clock: return "Clock"
        case .date: return "Date"
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .network: return "Network graph"
        case .custom: return "Custom HTML"
        }
    }
    var icon: String {
        switch self {
        case .clock: return "clock"
        case .date: return "calendar"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .network: return "network"
        case .custom: return "chevron.left.forwardslash.chevron.right"
        }
    }
    func size(customHeight: Double) -> NSSize {
        switch self {
        case .clock: return NSSize(width: 270, height: 86)
        case .date: return NSSize(width: 300, height: 40)
        case .cpu, .memory: return NSSize(width: 140, height: 74)
        case .network: return NSSize(width: 286, height: 120)
        case .custom: return NSSize(width: 360, height: customHeight)
        }
    }
}
struct WidgetPlacement: Codable, Equatable {
    var enabled = false
    var scale = 1.0
}
struct WidgetPosition: Codable, Equatable {
    var x: Double
    var y: Double
    static func initial(_ kind: WidgetKind) -> WidgetPosition {
        switch kind {
        case .clock: return .init(x: 0.5, y: 0.10)
        case .date: return .init(x: 0.5, y: 0.18)
        case .cpu: return .init(x: 0.45, y: 0.28)
        case .memory: return .init(x: 0.55, y: 0.28)
        case .network: return .init(x: 0.5, y: 0.42)
        case .custom: return .init(x: 0.5, y: 0.65)
        }
    }
    func frame(size: NSSize, area: NSRect) -> NSRect {
        let size = NSSize(width: min(area.width, size.width), height: min(area.height, size.height))
        return NSRect(
            x: area.minX + max(0, area.width - size.width) * min(1, max(0, x)),
            y: area.maxY - size.height - max(0, area.height - size.height) * min(1, max(0, y)),
            width: size.width, height: size.height)
    }
    static func from(frame: NSRect, area: NSRect) -> WidgetPosition {
        .init(
            x: min(1, max(0, (frame.minX - area.minX) / max(1, area.width - frame.width))),
            y: min(1, max(0, (area.maxY - frame.maxY) / max(1, area.height - frame.height))))
    }
}

final class WidgetDragSurface: NSView {
    var didDrag: ((NSRect) -> Void)?
    var dragBounds: NSRect?
    private var startPointer: NSPoint?
    private var startFrame: NSRect?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func beginDrag(at point: NSPoint) {
        guard let window else { return }
        startPointer = point
        startFrame = window.frame
        window.orderFront(nil)
        NSCursor.closedHand.set()
    }
    func drag(to point: NSPoint) {
        guard let window, let startPointer, let startFrame else { return }
        var origin = NSPoint(
            x: startFrame.minX + point.x - startPointer.x,
            y: startFrame.minY + point.y - startPointer.y)
        if let area = dragBounds {
            origin.x = min(max(area.minX, area.maxX - startFrame.width), max(area.minX, origin.x))
            origin.y = min(max(area.minY, area.maxY - startFrame.height), max(area.minY, origin.y))
        }
        window.setFrameOrigin(origin)
    }
    func endDrag() {
        guard startPointer != nil else { return }
        startPointer = nil
        startFrame = nil
        NSCursor.openHand.set()
        if let frame = window?.frame { didDrag?(frame) }
    }
    override func mouseDown(with event: NSEvent) { beginDrag(at: NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { drag(to: NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) {
        drag(to: NSEvent.mouseLocation)
        endDrag()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            startPointer = nil
            startFrame = nil
            NSCursor.arrow.set()
        }
        super.viewWillMove(toWindow: newWindow)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.7, green: 0.5, blue: 1, alpha: 0.9).setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
        path.lineWidth = 2
        let dash: [CGFloat] = [5, 4]
        path.setLineDash(dash, count: 2, phase: 0)
        path.stroke()
    }
}
