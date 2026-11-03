import AppKit
import Foundation
import Darwin

enum AppLocalization { static func string(_ value: String) -> String { value } }
@main struct TransformProbe {
    static func footprint() -> UInt64 {
        var value = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        precondition(status == KERN_SUCCESS)
        return value.phys_footprint
    }
    @MainActor static func main() {
        // This CLI probe has no App/NSApplication.run() entry point. Complete
        // AppKit startup before exercising the production font renderer.
        NSApplication.shared.finishLaunching()
        var warmedFootprint: UInt64 = 0
        var peakAfterWarmup: UInt64 = 0
        for frame in 0...3000 {
            autoreleasepool {
                let image = MenuBarTrafficRenderer.image(symbol: "paperplane.fill", isConnected: true, hasUpdate: frame % 2 == 0,
                    isTrafficEnabled: true, uploadBytesPerSecond: UInt64(frame * 731),
                    downloadBytesPerSecond: UInt64(frame * 1931))
                let pixels = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:384,pixelsHigh:128,
                    bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,
                    colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
                pixels.size = NSSize(width:192,height:64)
                let context = NSGraphicsContext(bitmapImageRep:pixels)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                context.cgContext.clear(CGRect(x:0,y:0,width:192,height:64))
                let scale = 1 + CGFloat(frame) / 10000
                context.cgContext.scaleBy(x:scale,y:scale)
                _ = image.representations[0].draw(in: NSRect(origin:.zero,size:image.size))
                NSGraphicsContext.restoreGraphicsState()
            }
            if frame % 500 == 0 {
                if frame >= 500 {
                    let current = footprint()
                    if warmedFootprint == 0 { warmedFootprint = current }
                    peakAfterWarmup = max(peakAfterWarmup, current)
                }
                print("frames=\(frame) footprintBytes=\(footprint())")
                fflush(stdout)
            }
        }
        let growth = peakAfterWarmup - warmedFootprint
        guard growth <= 8 * 1024 * 1024 else {
            fputs("Transformed traffic consumption retained more than 8 MiB after warmup: \(growth) bytes\n", stderr)
            exit(1)
        }
        print("transformed_font_cache_growth=\(growth) status=passed")
    }
}

