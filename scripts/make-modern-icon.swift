import AppKit
import Foundation

// 与界面帆形保持同一轮廓；所有尺寸直接矢量绘制，避免缩小时模糊。
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/icon-png")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let sailSVG = "M 310 632 C 426 518 525 353 686 240 C 646 393 655 513 725 596 C 575 557 447 578 310 632 Z"
let foldSVG = "M 310 632 C 435 561 554 490 686 240 C 569 457 470 572 310 632 Z"
let tideSVG = "M 285 716 C 422 637 576 771 748 668"
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs><linearGradient id="bg" x2="1" y2="1"><stop stop-color="#162C49"/><stop offset="1" stop-color="#0C162B"/></linearGradient><linearGradient id="sail" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#B2FFF0"/><stop offset=".5" stop-color="#29D7D5"/><stop offset="1" stop-color="#5865E8"/></linearGradient></defs>
<rect x="64" y="64" width="896" height="896" rx="200" fill="url(#bg)"/>
<rect x="65" y="65" width="894" height="894" rx="199" fill="none" stroke="#FFFFFF" stroke-opacity=".14" stroke-width="2"/>
<path d="\(sailSVG)" fill="url(#sail)"/><path d="\(foldSVG)" fill="#DCFFF8" fill-opacity=".45"/>
<path d="\(tideSVG)" fill="none" stroke="#53DFD8" stroke-width="32" stroke-linecap="round"/>
</svg>
"""
try Data(svg.utf8).write(to: output.appendingPathComponent("Xihang.svg"))
let menuSVG = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><path d="\(sailSVG)"/><path d="\(tideSVG)" fill="none" stroke="black" stroke-width="42" stroke-linecap="round"/></svg>
"""
try Data(menuSVG.utf8).write(to: output.appendingPathComponent("XihangMenuTemplate.svg"))
func sail() -> CGPath {
    let p = CGMutablePath(); p.move(to: CGPoint(x:310,y:632))
    p.addCurve(to: CGPoint(x:686,y:240), control1: CGPoint(x:426,y:518), control2: CGPoint(x:525,y:353))
    p.addCurve(to: CGPoint(x:725,y:596), control1: CGPoint(x:646,y:393), control2: CGPoint(x:655,y:513))
    p.addCurve(to: CGPoint(x:310,y:632), control1: CGPoint(x:575,y:557), control2: CGPoint(x:447,y:578)); p.closeSubpath(); return p
}
func color(_ r:CGFloat,_ g:CGFloat,_ b:CGFloat)->CGColor { CGColor(red:r/255,green:g/255,blue:b/255,alpha:1) }
for size in [16,32,64,128,256,512,1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    let context = NSGraphicsContext(bitmapImageRep:rep)!.cgContext
    context.scaleBy(x:CGFloat(size)/1024,y:CGFloat(size)/1024)
    context.translateBy(x:0,y:1024);context.scaleBy(x:1,y:-1)
    let background=CGPath(roundedRect:CGRect(x:64,y:64,width:896,height:896),cornerWidth:200,cornerHeight:200,transform:nil)
    context.saveGState(); context.addPath(background);context.clip()
    context.drawLinearGradient(CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:[color(22,44,73),color(12,22,43)] as CFArray,locations:[0,1])!,start:CGPoint(x:64,y:64),end:CGPoint(x:960,y:960),options:[])
    context.restoreGState()
    context.saveGState();context.addPath(sail());context.clip()
    context.drawLinearGradient(CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:[color(178,255,240),color(41,215,213),color(88,101,232)] as CFArray,locations:[0,0.5,1])!,start:CGPoint(x:310,y:240),end:CGPoint(x:725,y:632),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
    context.restoreGState()
    let fold=CGMutablePath();fold.move(to:CGPoint(x:310,y:632));fold.addCurve(to:CGPoint(x:686,y:240),control1:CGPoint(x:435,y:561),control2:CGPoint(x:554,y:490));fold.addCurve(to:CGPoint(x:310,y:632),control1:CGPoint(x:569,y:457),control2:CGPoint(x:470,y:572));fold.closeSubpath()
    context.addPath(fold);context.setFillColor(CGColor(red:0.86,green:1,blue:0.97,alpha:0.45));context.fillPath()
    context.move(to:CGPoint(x:285,y:716));context.addCurve(to:CGPoint(x:748,y:668),control1:CGPoint(x:422,y:637),control2:CGPoint(x:576,y:771))
    context.setStrokeColor(color(83,223,216));context.setLineWidth(32);context.setLineCap(.round);context.strokePath()
    try rep.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("size-\(size).png"))
}
print("XIHANG_ICON_OK \(output.path)")
