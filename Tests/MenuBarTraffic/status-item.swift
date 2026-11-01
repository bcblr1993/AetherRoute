import AppKit
import SwiftUI
import Darwin

enum AppLocalization { static func string(_ value: String) -> String { value } }

@MainActor final class Rates: ObservableObject {
    @Published var upload: UInt64 = 1024
    @Published var download: UInt64 = 2048
    let mode = CommandLine.arguments.dropFirst().first ?? "dynamic"
    func start() {
        Task { @MainActor in
            var random: UInt64 = 7
            for frame in 0...6000 {
                if mode == "dynamic" {
                    random = random &* 6364136223846793005 &+ 1
                    upload = (random >> 32) % 10_000_000
                    download = random % 100_000_000
                }
                if frame % 1000 == 0 {
                    var info = task_vm_info_data_t()
                    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
                    let result = withUnsafeMutablePointer(to: &info) { pointer in
                        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                        }
                    }
                    precondition(result == KERN_SUCCESS)
                    precondition(info.phys_footprint < 64 * 1024 * 1024, "Status-item footprint exceeded 64 MiB")
                    print("mode=\(mode) frames=\(frame) footprintBytes=\(info.phys_footprint)")
                    fflush(stdout)
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            print("statusitem_frames=6000 status=passed")
            fflush(stdout)
            NSApplication.shared.terminate(nil)
        }
    }
}
struct StatusLabel: View {
    @ObservedObject var rates: Rates
    var body: some View {
        Image(nsImage: MenuBarTrafficRenderer.image(
            symbol: "paperplane.fill", isConnected: true,
            isTrafficEnabled: true, uploadBytesPerSecond: rates.upload,
            downloadBytesPerSecond: rates.download
        ))
    }
}
@main struct StatusProbe: App {
    @StateObject private var rates: Rates
    init() {
        let value = Rates()
        _rates = StateObject(wrappedValue: value)
        value.start()
    }
    var body: some Scene {
        MenuBarExtra { Text("Temporary memory diagnostic") } label: { StatusLabel(rates: rates) }
            .menuBarExtraStyle(.window)
    }
}

