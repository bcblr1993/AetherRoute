import AetherRouteKit
import AppKit
import Foundation
import Sparkle
import SwiftUI

enum AetherVisual {
    static let portalLight = Color.blue
    static let portalMid = Color.blue
    static let sMicro: CGFloat = 2
    static let s1: CGFloat = 4
    static let sCompact: CGFloat = 6
    static let s2: CGFloat = 8
    static let sRow: CGFloat = 10
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 20
    static let badgeRadius: CGFloat = 4
    static let controlRadius: CGFloat = 6
    static let cardRadius: CGFloat = 10
    static let panelFill = Color(nsColor: .quaternarySystemFill)
    static let cardFill = Color(nsColor: .tertiarySystemFill)
    static let cardStroke = Color(nsColor: .separatorColor)
    static func tintFill(_ tint: Color) -> Color { tint.opacity(0.14) }
    static func tintWash(_ tint: Color) -> Color { tint.opacity(0.10) }
}

struct AetherReadableTint: ShapeStyle {
    let color: Color
    func resolve(in environment: EnvironmentValues) -> Color { color }
}

@MainActor
final class RegressionAppDelegate: NSObject, NSApplicationDelegate {
    private let driver = AppUpdateUserDriver(
        currentVersion: "3.0.4",
        shouldShowScheduledWindow: { _ in true }
    )

    private var summaryOnlyHeight: CGFloat = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.prohibited)

        let zhSummary = "AetherRoute 3.1.0 带来三大高频效率升级：概览页按需出口画像与 AI / 流媒体可用性检测、规则页 4 套本地零依赖场景化规则预设，以及 DNS 页 Fake-IP 自动反查、一键清缓存与有界近期解析记录。"
        let enSummary = "AetherRoute 3.1.0 introduces three high-frequency workflow upgrades: on-demand egress profile and AI/streaming availability checks on Overview (with Proxies AI filtering), four built-in offline scenario rule presets on Rules, and instant Fake-IP reverse lookup, DNS cache flush, and bounded recent DNS queries."

        let zhAppcastHTML = """
        <p class="summary">\(zhSummary)</p>
        <div class="group feature">
          <div class="tag">新特性</div>
          <ul>
            <li><strong>出口画像与 AI / 流媒体可用性检测</strong>：概览页路由组新增可折叠出口画像行，按需探测落地 IP、归属地、ASN、纯净度及 ChatGPT / Claude / Gemini / Copilot / Netflix / Disney+ / YouTube / TikTok 可用性。</li>
            <li><strong>规则页场景化规则预设</strong>：应用与自定义分段新增 4 套本地零远程依赖预设（AI 开发者套件、开发者加速包、广告与遥测拦截、国内与局域网零绕路）。</li>
            <li><strong>DNS Fake-IP 反查与近期解析记录</strong>：DNS 查询原地支持 198.18.0.0/15 Fake-IP 自动反查与一键清空 DNS 缓存，紧下方新增有界 64 条近期 DNS 解析记录卡。</li>
          </ul>
        </div>
        <div class="group improve">
          <div class="tag">改进</div>
          <ul>
            <li><strong>全维度隔离门禁通过</strong>：新增 23 项 TDD 单元测试，12 协议双指纹互通与 43 节点 Mihomo 对照、6 维 VM 矩阵、UI 内存预算及 6 项公证 DMG 运行时证据全部通过。</li>
          </ul>
        </div>
        """

        let sectionsOnlyHTML = """
        <div class="section">
          <span class="section-tag tag-feature">新特性</span>
          <ul>
            <li><strong>出口画像检测</strong>：按需展示落地 IP、ASN 与纯净度评分。</li>
            <li><strong>场景化规则预设</strong>：4 套本地零远程依赖预设，一键开关。</li>
          </ul>
        </div>
        <div class="section">
          <span class="section-tag tag-fix">稳定性修复</span>
          <ul>
            <li><strong>更新弹窗布局</strong>：修复 macOS 27 亚像素高度引发的显示循环约束异常。</li>
          </ul>
        </div>
        """

        struct Step {
            let name: String
            let resizeWindow: Bool
            let verifyAfter: (NSWindow, CGFloat) -> Void
            let apply: (AppUpdateSessionModel) -> Void
        }

        let steps: [Step] = [
            Step(
                name: "1_checking",
                resizeWindow: true,
                verifyAfter: { window, _ in
                    Self.assertValidGeometry(window: window, phase: "1_checking")
                },
                apply: { model in
                    model.beginChecking(cancel: {})
                }
            ),
            Step(
                name: "2_available_zh_3line_summary",
                resizeWindow: true,
                verifyAfter: { window, _ in
                    Self.assertValidGeometry(window: window, phase: "2_available_zh_3line_summary")
                    Self.assertDriverMetadata(driver: self.driver, phase: "2_available_zh_3line_summary")
                    self.summaryOnlyHeight = window.frame.height
                    precondition(
                        window.frame.height < 450,
                        "Summary-only .available height must stay compact (< 450pt), got \(window.frame.height)"
                    )
                },
                apply: { model in
                    let notes = AppUpdateReleaseNotesParser.parse(html: "<p class=\"summary\">\(zhSummary)</p>")
                    model.presentAvailableUpdate(
                        version: "3.1.0",
                        build: "2026112002",
                        contentLength: 32_299_820,
                        releaseNotes: notes,
                        fullReleaseNotesURL: URL(string: "https://aethernative.com/apps/aetherroute/releases/3.1.0/"),
                        informationOnly: false,
                        reply: { _ in }
                    )
                }
            ),
            Step(
                name: "3_available_summary_and_sections",
                resizeWindow: true,
                verifyAfter: { window, prevHeight in
                    Self.assertValidGeometry(window: window, phase: "3_available_summary_and_sections")
                    Self.assertDriverMetadata(driver: self.driver, phase: "3_available_summary_and_sections")
                    precondition(
                        window.frame.height > max(prevHeight, self.summaryOnlyHeight),
                        "Summary + sections ScrollView must expand height beyond summary-only (\(self.summaryOnlyHeight)), got \(window.frame.height)"
                    )
                },
                apply: { model in
                    let notes = AppUpdateReleaseNotesParser.parse(html: zhAppcastHTML)
                    model.updateReleaseNotes(notes)
                }
            ),
            Step(
                name: "4_available_sections_only",
                resizeWindow: true,
                verifyAfter: { window, _ in
                    Self.assertValidGeometry(window: window, phase: "4_available_sections_only")
                    precondition(
                        window.frame.height > 320,
                        "Sections-only ScrollView must retain non-collapsed height (> 320pt), got \(window.frame.height)"
                    )
                },
                apply: { model in
                    let notes = AppUpdateReleaseNotesParser.parse(html: sectionsOnlyHTML)
                    model.presentAvailableUpdate(
                        version: "3.1.0",
                        build: "2026112002",
                        contentLength: 32_299_820,
                        releaseNotes: notes,
                        fullReleaseNotesURL: URL(string: "https://aethernative.com/apps/aetherroute/releases/3.1.0/"),
                        informationOnly: false,
                        reply: { _ in }
                    )
                }
            ),
            Step(
                name: "5_downloading_start",
                resizeWindow: true,
                verifyAfter: { window, _ in
                    Self.assertValidGeometry(window: window, phase: "5_downloading_start")
                },
                apply: { model in
                    model.beginDownload(cancel: {})
                    model.updateDownloadExpectedLength(32_299_820)
                }
            ),
            Step(
                name: "5b_downloading_progress_1",
                resizeWindow: false,
                verifyAfter: { window, _ in
                    Self.assertValidGeometry(window: window, phase: "5b_downloading_progress_1")
                },
                apply: { model in
                    model.appendDownloadedBytes(4_194_304)
                }
            ),
            Step(
                name: "5c_downloading_progress_2",
                resizeWindow: false,
                verifyAfter: { window, _ in
                    Self.assertValidGeometry(window: window, phase: "5c_downloading_progress_2")
                },
                apply: { model in
                    model.appendDownloadedBytes(12_582_912)
                }
            ),
            Step(
                name: "6_extracting",
                resizeWindow: true,
                verifyAfter: { window, _ in
                    Self.assertValidGeometry(window: window, phase: "6_extracting")
                },
                apply: { model in
                    model.beginExtraction()
                    model.updateExtractionProgress(0.45)
                }
            ),
            Step(
                name: "7_ready_to_install",
                resizeWindow: true,
                verifyAfter: { window, _ in
                    Self.assertValidGeometry(window: window, phase: "7_ready_to_install")
                },
                apply: { model in
                    model.presentReadyToInstall(reply: { _ in })
                }
            ),
            Step(
                name: "8_installing",
                resizeWindow: true,
                verifyAfter: { window, _ in
                    Self.assertValidGeometry(window: window, phase: "8_installing")
                },
                apply: { model in
                    model.beginInstalling(retryTermination: {})
                }
            ),
            Step(
                name: "9_up_to_date",
                resizeWindow: true,
                verifyAfter: { window, _ in
                    Self.assertValidGeometry(window: window, phase: "9_up_to_date")
                },
                apply: { model in
                    model.presentUpToDate(acknowledgement: {})
                }
            ),
            Step(
                name: "10_error",
                resizeWindow: true,
                verifyAfter: { window, _ in
                    Self.assertValidGeometry(window: window, phase: "10_error")
                },
                apply: { model in
                    model.presentError(
                        message: "无法连接到更新服务器，请检查您的网络连接或代理设置后重试。请求超时（NSURLErrorTimedOut -1001），且备用镜像未能返回有效的 Appcast 签名清单。",
                        acknowledgement: {}
                    )
                }
            ),
            Step(
                name: "11_available_en_3line_summary",
                resizeWindow: true,
                verifyAfter: { window, _ in
                    Self.assertValidGeometry(window: window, phase: "11_available_en_3line_summary")
                    Self.assertDriverMetadata(driver: self.driver, phase: "11_available_en_3line_summary")
                    precondition(
                        window.frame.height < 450,
                        "English summary-only .available height must stay compact (< 450pt), got \(window.frame.height)"
                    )
                },
                apply: { model in
                    let notes = AppUpdateReleaseNotesParser.parse(html: "<p class=\"summary\">\(enSummary)</p>")
                    model.presentAvailableUpdate(
                        version: "3.1.0",
                        build: "2026112002",
                        contentLength: 32_299_820,
                        releaseNotes: notes,
                        fullReleaseNotesURL: URL(string: "https://aethernative.com/en/apps/aetherroute/releases/3.1.0/"),
                        informationOnly: false,
                        reply: { _ in }
                    )
                }
            )
        ]

        var index = 0
        var lastHeight: CGFloat = 0

        func runNext() {
            guard index < steps.count else {
                print("AppUpdateWindow layout regression: all \(steps.count) phases passed")
                NSApplication.shared.terminate(nil)
                return
            }
            let step = steps[index]
            index += 1

            driver.debugMutateSession(resizeWindow: step.resizeWindow, step.apply)
            driver.debugPresentOffscreenForTesting()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                guard let window = self.driver.debugWindow else {
                    preconditionFailure("Expected update window to exist at phase \(step.name)")
                }
                step.verifyAfter(window, lastHeight)
                lastHeight = window.frame.height
                print("  PASS \(step.name): frame=\(NSStringFromRect(window.frame))")
                runNext()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            runNext()
        }
    }

    private static func assertValidGeometry(window: NSWindow, phase: String) {
        let frame = window.frame
        precondition(
            abs(frame.width - 540) < 0.5,
            "Phase \(phase): expected width 540, got \(frame.width)"
        )
        precondition(
            frame.height == floor(frame.height),
            "Phase \(phase): window height must be integral, got \(frame.height)"
        )
        precondition(
            frame.height >= 180 && frame.height <= 760,
            "Phase \(phase): window height out of bounds [180, 760], got \(frame.height)"
        )
    }

    private static func assertDriverMetadata(driver: AppUpdateUserDriver, phase: String) {
        precondition(
            driver.debugWindow?.identifier?.rawValue == "aetherroute-update",
            "Phase \(phase): expected window identifier 'aetherroute-update', got \(String(describing: driver.debugWindow?.identifier?.rawValue))"
        )
        precondition(
            driver.debugHostingSizingOptions == [],
            "Phase \(phase): expected NSHostingController.sizingOptions == [], got \(String(describing: driver.debugHostingSizingOptions))"
        )
    }
}

@main
struct AppUpdateWindowLayoutRegressionApp: App {
    @NSApplicationDelegateAdaptor(RegressionAppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
