import AppKit

struct IconPalette {
    let name: String
    let colors: [NSColor]
    let defaultGlyphColor: NSColor
    let borderColor: NSColor
    let shadowColor: NSColor
    let highlightAlpha: CGFloat
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1.0) -> NSColor {
    NSColor(calibratedRed: red / 255.0, green: green / 255.0, blue: blue / 255.0, alpha: alpha)
}

func colorFromHex(_ hex: String) -> NSColor? {
    var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("#") {
        value.removeFirst()
    }

    guard value.count == 6, let intValue = UInt32(value, radix: 16) else {
        return nil
    }

    let red = CGFloat((intValue >> 16) & 0xff)
    let green = CGFloat((intValue >> 8) & 0xff)
    let blue = CGFloat(intValue & 0xff)
    return color(red, green, blue)
}

let palettes: [String: IconPalette] = [
    "blue": IconPalette(
        name: "blue",
        colors: [color(10, 88, 245), color(18, 150, 250), color(0, 205, 255)],
        defaultGlyphColor: color(207, 232, 252),
        borderColor: NSColor.white.withAlphaComponent(0.22),
        shadowColor: NSColor.black.withAlphaComponent(0.22),
        highlightAlpha: 0.28
    ),
    "gray": IconPalette(
        name: "gray",
        colors: [color(28, 31, 36), color(80, 86, 94), color(174, 181, 190)],
        defaultGlyphColor: color(239, 242, 246),
        borderColor: NSColor.white.withAlphaComponent(0.18),
        shadowColor: NSColor.black.withAlphaComponent(0.28),
        highlightAlpha: 0.20
    ),
    "weather": IconPalette(
        name: "weather",
        colors: [color(8, 112, 234), color(70, 176, 255), color(255, 196, 76)],
        defaultGlyphColor: color(255, 249, 226),
        borderColor: NSColor.white.withAlphaComponent(0.24),
        shadowColor: NSColor.black.withAlphaComponent(0.20),
        highlightAlpha: 0.30
    ),
    "purple": IconPalette(
        name: "purple",
        colors: [color(80, 36, 164), color(142, 78, 225), color(219, 126, 255)],
        defaultGlyphColor: color(245, 232, 255),
        borderColor: NSColor.white.withAlphaComponent(0.22),
        shadowColor: NSColor.black.withAlphaComponent(0.24),
        highlightAlpha: 0.24
    ),
    "tomato": IconPalette(
        name: "tomato",
        colors: [color(178, 45, 38), color(242, 89, 69), color(255, 159, 112)],
        defaultGlyphColor: color(255, 239, 229),
        borderColor: NSColor.white.withAlphaComponent(0.22),
        shadowColor: NSColor.black.withAlphaComponent(0.23),
        highlightAlpha: 0.24
    ),
    "green": IconPalette(
        name: "green",
        colors: [color(20, 118, 72), color(44, 184, 112), color(151, 230, 126)],
        defaultGlyphColor: color(230, 255, 236),
        borderColor: NSColor.white.withAlphaComponent(0.22),
        shadowColor: NSColor.black.withAlphaComponent(0.22),
        highlightAlpha: 0.24
    ),
    "white": IconPalette(
        name: "white",
        colors: [color(255, 255, 255), color(246, 248, 251), color(229, 234, 240)],
        defaultGlyphColor: color(20, 118, 238),
        borderColor: NSColor.black.withAlphaComponent(0.08),
        shadowColor: NSColor.black.withAlphaComponent(0.16),
        highlightAlpha: 0.12
    )
]

let scriptArguments: [String]
if let separatorIndex = CommandLine.arguments.firstIndex(of: "--") {
    scriptArguments = Array(CommandLine.arguments.dropFirst(separatorIndex + 1))
} else if let scriptIndex = CommandLine.arguments.firstIndex(where: { $0.hasSuffix("generate_icon.swift") }) {
    scriptArguments = Array(CommandLine.arguments.dropFirst(scriptIndex + 1))
} else {
    scriptArguments = []
}

let symbolName = scriptArguments.first ?? "photo.stack.fill"
let outputPath = scriptArguments.dropFirst().first ?? "Icon.png"
let paletteName = scriptArguments.dropFirst(2).first ?? "blue"
let selectedPalette = palettes[paletteName] ?? palettes["blue"]!
let glyphColor = scriptArguments.dropFirst(3).first.flatMap(colorFromHex) ?? selectedPalette.defaultGlyphColor

print("==> generate_icon.swift settings")
print("    SF Symbol    : \(symbolName)")
print("    output       : \(outputPath)")
print("    palette      : \(selectedPalette.name)")
print("    symbol color : \(scriptArguments.dropFirst(3).first ?? "palette default")")
print("    palettes     : \(palettes.keys.sorted().joined(separator: ", "))")

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)

image.lockFocus()

let rect = NSRect(origin: .zero, size: size)
let tileRect = rect.insetBy(dx: 100, dy: 100)
let cornerRadius: CGFloat = 232
let backgroundPath = NSBezierPath(roundedRect: tileRect, xRadius: cornerRadius, yRadius: cornerRadius)

let gradient = NSGradient(colors: selectedPalette.colors)

gradient?.draw(in: backgroundPath, angle: 45)

let highlightPath = NSBezierPath(roundedRect: tileRect.insetBy(dx: 16, dy: 16),
                                 xRadius: cornerRadius - 10,
                                 yRadius: cornerRadius - 10)
let highlight = NSGradient(colors: [
    NSColor.white.withAlphaComponent(selectedPalette.highlightAlpha),
    NSColor.white.withAlphaComponent(0.04)
])
highlight?.draw(in: highlightPath, angle: -90)

let borderPath = NSBezierPath(roundedRect: tileRect.insetBy(dx: 6, dy: 6),
                              xRadius: cornerRadius - 4,
                              yRadius: cornerRadius - 4)
selectedPalette.borderColor.setStroke()
borderPath.lineWidth = 6
borderPath.stroke()

let glyphShadow = NSShadow()
glyphShadow.shadowBlurRadius = 16
glyphShadow.shadowOffset = NSSize(width: 0, height: -3)
glyphShadow.shadowColor = selectedPalette.shadowColor

let symbolConfig = NSImage.SymbolConfiguration(pointSize: 740, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [glyphColor]))
let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
    .withSymbolConfiguration(symbolConfig)

if let symbol {
    let targetRect = tileRect.insetBy(dx: 58, dy: 58)
    let symbolSize = symbol.size
    let scale = min(targetRect.width / symbolSize.width, targetRect.height / symbolSize.height)
    let drawSize = NSSize(width: symbolSize.width * scale, height: symbolSize.height * scale)
    let drawRect = NSRect(
        x: rect.midX - drawSize.width / 2,
        y: rect.midY - drawSize.height / 2,
        width: drawSize.width,
        height: drawSize.height
    )
    NSGraphicsContext.current?.saveGraphicsState()
    glyphShadow.set()
    symbol.draw(in: drawRect)
    NSGraphicsContext.current?.restoreGraphicsState()
}

image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)
let pngData = rep?.representation(using: .png, properties: [:])
let outputURL = URL(fileURLWithPath: outputPath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
try pngData?.write(to: outputURL)

print("Wrote \(outputURL.path)")
