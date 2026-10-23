// Draws the DMG window's background: Still on the left, an arrow, Applications on the right.
//
//   swift Scripts/dmg-background.swift <output.png> <scale>
//
// Scripts/package.sh renders it at 1× and 2× and combines them into one TIFF for Retina screens. The
// layout matches Scripts/dmg-settings.py, which places the icons.
//
// The background is transparent, so Finder's own window color shows through in light and dark mode. Finder
// draws the icon names in black or white to match, so they stay readable either way.

import AppKit

let size = CGSize(width: 660, height: 400)
let stillCenter = CGPoint(x: 170, y: 150)
let applicationsCenter = CGPoint(x: 490, y: 150)

let arguments = CommandLine.arguments
guard arguments.count == 3, let scale = Double(arguments[2]) else {
    FileHandle.standardError.write(Data("Usage: dmg-background.swift <output.png> <scale>\n".utf8))
    exit(64)
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                        bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Top-left origin, in points, like Finder's icon positions.
context.translateBy(x: 0, y: size.height * scale)
context.scaleBy(x: scale, y: -scale)

// The arrow, in the trim brackets' yellow.
let arrowY = stillCenter.y
let arrowStart = stillCenter.x + 98
let arrowEnd = applicationsCenter.x - 98
context.setStrokeColor(color(0xFFC93C))
context.setLineWidth(5)
context.setLineCap(.round)
context.setLineJoin(.round)
context.beginPath()
context.move(to: CGPoint(x: arrowStart, y: arrowY))
context.addLine(to: CGPoint(x: arrowEnd, y: arrowY))
context.move(to: CGPoint(x: arrowEnd - 16, y: arrowY - 16))
context.addLine(to: CGPoint(x: arrowEnd, y: arrowY))
context.addLine(to: CGPoint(x: arrowEnd - 16, y: arrowY + 16))
context.strokePath()

// The instruction, above where Finder's path bar can cover the bottom of the window. Mid gray reads on both
// a light and a dark window.
let caption = NSAttributedString(string: "Drag Still to Applications to install it", attributes: [
    .font: NSFont.systemFont(ofSize: 14, weight: .medium),
    .foregroundColor: NSColor(cgColor: color(0x8E8E93))!,
])
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
let captionSize = caption.size()
caption.draw(at: CGPoint(x: (size.width - captionSize.width) / 2, y: 282))
NSGraphicsContext.current = nil

let image = context.makeImage()!
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, "public.png" as CFString, 1, nil)!
// 72 dpi per point, so Finder shows the 2× image at the window's size.
CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
guard CGImageDestinationFinalize(destination) else { exit(1) }
