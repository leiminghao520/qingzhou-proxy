import AppKit
import Foundation
let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath:destination,withIntermediateDirectories:true)
for size in [16,32,64,128,256,512,1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
    let s = CGFloat(size)
    NSColor(calibratedRed:0.08,green:0.28,blue:0.34,alpha:1).setFill()
    NSBezierPath(roundedRect:NSRect(x:s*0.04,y:s*0.04,width:s*0.92,height:s*0.92),xRadius:s*0.2,yRadius:s*0.2).fill()
    NSColor(calibratedRed:0.68,green:0.92,blue:0.83,alpha:1).setFill()
    let plane = NSBezierPath();plane.move(to:NSPoint(x:s*0.22,y:s*0.56));plane.line(to:NSPoint(x:s*0.80,y:s*0.79));plane.line(to:NSPoint(x:s*0.59,y:s*0.22));plane.line(to:NSPoint(x:s*0.45,y:s*0.43));plane.close();plane.fill()
    NSColor(calibratedRed:0.08,green:0.28,blue:0.34,alpha:1).setStroke()
    let line = NSBezierPath();line.lineWidth = max(1,s*0.018);line.move(to:NSPoint(x:s*0.45,y:s*0.43));line.line(to:NSPoint(x:s*0.72,y:s*0.71));line.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:destination).appendingPathComponent("size-\(size).png"))
}
