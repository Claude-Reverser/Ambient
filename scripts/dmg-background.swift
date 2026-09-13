import AppKit

let w = 720
let h = 460
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: w * 2, pixelsHigh: h * 2, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
    bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let c = NSGraphicsContext.current!.cgContext
c.scaleBy(x: 2, y: 2)
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        NSColor(red: 0.16, green: 0.08, blue: 0.28, alpha: 1).cgColor,
        NSColor(red: 0.045, green: 0.025, blue: 0.085, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
c.drawLinearGradient(
    gradient, start: CGPoint(x: 0, y: 460), end: CGPoint(x: 720, y: 0), options: [])
func text(
    _ value: String, _ y: CGFloat, _ size: CGFloat, _ color: NSColor,
    _ weight: NSFont.Weight = .regular
) {
    let p = NSMutableParagraphStyle()
    p.alignment = .center
    (value as NSString).draw(
        in: NSRect(x: 30, y: y, width: 660, height: size * 1.6),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
            .paragraphStyle: p,
        ])
}
text("Welcome to Ambient", 350, 36, .white, .semibold)
text("Your desktop, with a little more life.", 318, 15, NSColor(white: 0.75, alpha: 1))
c.setFillColor(NSColor(red: 0.76, green: 0.66, blue: 0.9, alpha: 1).cgColor)
c.addPath(
    CGPath(
        roundedRect: CGRect(x: 270, y: 120, width: 180, height: 28), cornerWidth: 14,
        cornerHeight: 14, transform: nil))
c.fillPath()
text("Double click me to install", 65, 24, .white, .semibold)
text("A guided installation. A moving welcome.", 30, 13, NSColor(white: 0.65, alpha: 1))
rep.size = NSSize(width: w, height: h)
try rep.representation(using: .png, properties: [:])!.write(
    to: URL(fileURLWithPath: CommandLine.arguments[1]))
