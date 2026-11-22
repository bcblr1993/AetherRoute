import AetherRouteKit
import AppKit
import CoreImage
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

/// Reads the text of every QR code in an image, entirely on this Mac.
enum ShareLinkQRCodeReader {
    /// The payloads of the QR codes in the image, top to bottom.
    static func payloads(in image: CIImage) -> [String] {
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        let features = detector?.features(in: image) ?? []
        return features
            .compactMap { $0 as? CIQRCodeFeature }
            .sorted { $0.bounds.maxY > $1.bounds.maxY }
            .compactMap(\.messageString)
    }

    static func payloads(inImageAt url: URL) -> [String] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let image = CIImage(contentsOf: url) else { return [] }
        return payloads(in: image)
    }

    static func payloads(inData data: Data) -> [String] {
        guard let image = CIImage(data: data) else { return [] }
        return payloads(in: image)
    }

    static func payloads(in image: NSImage) -> [String] {
        guard let data = image.tiffRepresentation,
              let ciImage = CIImage(data: data) else { return [] }
        return payloads(in: ciImage)
    }
}

/// Reads the QR codes shown anywhere on screen, outside AetherRoute's own
/// windows. Each display is captured once, in memory, and never saved. macOS
/// asks for Screen Recording permission the first time.
enum ShareLinkScreenScanner {
    static func payloads() async throws -> [String] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let ownApplications = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        var payloads: [String] = []
        for display in content.displays {
            let filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            configuration.width = Int(CGFloat(display.width) * scale)
            configuration.height = Int(CGFloat(display.height) * scale)
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            payloads += ShareLinkQRCodeReader.payloads(in: CIImage(cgImage: image))
        }
        return payloads
    }
}

/// Paste node share links, or read them from a QR code image, and add them
/// as one editable profile. Nothing is opened or downloaded: links are
/// parsed into typed nodes and validated before anything is saved.
struct ShareLinkImportSheet: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var isImporting = false
    @State private var isImagePickerPresented = false
    @State private var qrMessage: String?
    @State private var qrMessageIsError = false
    @State private var qrNeedsScreenPermission = false
    @State private var importErrorMessage: String?
    @State private var isScanningScreen = false
    @State private var requestsCancel = false
    @State private var importTask: Task<Void, Never>?
    @State private var qrTask: Task<Void, Never>?
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s4) {
            AetherSheetHeader(
                symbol: "qrcode.viewfinder",
                title: AppLocalization.string("Import Node Links"),
                subtitle: AppLocalization.string("Paste links such as vless://, ss:// or hy2://, one per line, or read them from a QR code image."),
                tint: AetherVisual.manualNodesTint
            )

            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(AetherVisual.s2)
                .frame(minHeight: AetherVisual.s6 * 6)
                .background(
                    AetherVisual.subtleFill,
                    in: RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                )
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(verbatim: "vless://…\nhy2://…")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(AetherVisual.tertiaryText)
                            .padding(AetherVisual.s3)
                            .allowsHitTesting(false)
                    }
                }
                .focused($isEditorFocused)
                .disabled(isImporting)
                .onDrop(of: [.image, .fileURL], isTargeted: nil, perform: readDroppedImage)
                .accessibilityLabel(AppLocalization.string("Node links"))
                .accessibilityIdentifier("share-link-text")

            AetherFlowLayout(spacing: AetherVisual.s2) {
                Button(AppLocalization.string("Paste"), systemImage: "doc.on.clipboard") {
                    pasteFromClipboard()
                }
                .aetherButton()
                .disabled(isImporting)
                .accessibilityIdentifier("share-link-paste")
                Button(AppLocalization.string("Choose QR Code Image…"), systemImage: "qrcode") {
                    isImagePickerPresented = true
                }
                .aetherButton()
                .disabled(isImporting)
                .accessibilityIdentifier("share-link-choose-image")
                Button {
                    scanScreen()
                } label: {
                    AetherProgressButtonLabel(
                        AppLocalization.string("Scan Screen"),
                        systemImage: "viewfinder",
                        isWorking: isScanningScreen
                    )
                }
                .aetherButton()
                .disabled(isImporting || isScanningScreen)
                .help(AppLocalization.string("Reads a QR code shown in another app's window, such as a browser or chat."))
                .accessibilityIdentifier("share-link-scan-screen")
            }

            if let qrMessage {
                VStack(alignment: .leading, spacing: AetherVisual.s2) {
                    if qrMessageIsError {
                        AetherInlineMessage(text: qrMessage, kind: .warning, isCompact: true)
                    } else {
                        Label(qrMessage, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(AetherReadableTint(color: .green))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if qrNeedsScreenPermission {
                        Button(AppLocalization.string("Open System Settings")) {
                            openScreenRecordingSettings()
                        }
                        .aetherButton()
                        .controlSize(.small)
                        .accessibilityIdentifier("share-link-open-screen-recording-settings")
                    }
                }
            }

            Text(AppLocalization.string("Links are parsed on this Mac; AetherRoute does not contact any of the servers until you connect."))
                .font(.caption)
                .foregroundStyle(AetherVisual.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let importErrorMessage {
                AetherInlineMessage(text: importErrorMessage)
            }

            HStack {
                // Cancel and the primary action share the trailing edge, as in
                // every macOS sheet.
                Spacer()
                Button(AppLocalization.string("Cancel"), role: .cancel) {
                    if isImporting {
                        importTask?.cancel()
                        importTask = nil
                        qrTask?.cancel()
                        qrTask = nil
                        isImporting = false
                        dismiss()
                    } else {
                        requestsCancel = true
                    }
                }
                .aetherButton()
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("share-link-cancel")
                Button {
                    startImport()
                } label: {
                    AetherProgressButtonLabel(
                        AppLocalization.string("Import"),
                        isWorking: isImporting
                    )
                }
                .aetherButton(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isImporting
                        || !tunnel.canImportOrAddProfile
                        || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .accessibilityIdentifier("share-link-import")
            }
            .controlSize(.large)
        }
        .padding(AetherVisual.dialogPadding)
        .aetherSheetFrame()
        .interactiveDismissDisabled(isImporting)
        .modifier(DiscardChangesModifier(
            isDirty: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            isSaving: isImporting,
            requested: $requestsCancel
        ))
        .fileImporter(
            isPresented: $isImagePickerPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                qrTask?.cancel()
                qrTask = Task {
                    let payloads = await Task.detached(priority: .userInitiated) {
                        ShareLinkQRCodeReader.payloads(inImageAt: url)
                    }.value
                    guard !Task.isCancelled else { return }
                    append(payloads)
                }
            case let .failure(error):
                qrMessage = error.localizedDescription
                qrMessageIsError = true
                qrNeedsScreenPermission = false
            }
        }
        .onChange(of: text) { _, _ in
            importErrorMessage = nil
        }
        .onAppear {
            tunnel.clearProfileMessage()
            isEditorFocused = true
        }
        .onDisappear {
            importTask?.cancel()
            importTask = nil
            qrTask?.cancel()
            qrTask = nil
        }
    }

    private func startImport() {
        guard !isImporting else { return }
        importErrorMessage = nil
        tunnel.clearProfileMessage()
        isImporting = true
        importTask?.cancel()
        importTask = Task {
            let imported = await tunnel.importShareLinks(text)
            importTask = nil
            isImporting = false
            guard !Task.isCancelled else { return }
            if imported {
                dismiss()
            } else {
                importErrorMessage = tunnel.profileMessage
                    ?? AppLocalization.string("No valid node link was found. Paste links such as vless://, ss:// or hy2://, one per line.")
            }
        }
    }

    private func pasteFromClipboard() {
        guard !isImporting else { return }
        qrNeedsScreenPermission = false
        let pasteboard = NSPasteboard.general
        if let string = pasteboard.string(forType: .string),
           !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = text.isEmpty ? string : text + "\n" + string
            qrMessage = nil
            qrMessageIsError = false
            return
        }
        // A copied screenshot of a QR code.
        if let data = pasteboard.data(forType: .png)
            ?? pasteboard.data(forType: .tiff)
            ?? pasteboard.data(forType: NSPasteboard.PasteboardType("public.jpeg"))
            ?? NSImage(pasteboard: pasteboard)?.tiffRepresentation {
            qrTask?.cancel()
            qrTask = Task {
                let payloads = await Task.detached(priority: .userInitiated) {
                    ShareLinkQRCodeReader.payloads(inData: data)
                }.value
                guard !Task.isCancelled else { return }
                append(payloads)
            }
            return
        }
        qrMessage = AppLocalization.string("Clipboard does not contain text or a QR code image.")
        qrMessageIsError = true
    }

    private func scanScreen() {
        guard !isImporting, !isScanningScreen else { return }
        isScanningScreen = true
        qrNeedsScreenPermission = false
        qrTask?.cancel()
        qrTask = Task {
            defer { isScanningScreen = false }
            do {
                let payloads = try await ShareLinkScreenScanner.payloads()
                guard !Task.isCancelled else { return }
                append(payloads)
            } catch {
                guard !Task.isCancelled else { return }
                qrMessage = AppLocalization.string("Allow AetherRoute under System Settings › Privacy & Security › Screen & System Audio Recording to scan the screen.")
                qrMessageIsError = true
                qrNeedsScreenPermission = true
            }
        }
    }

    private func openScreenRecordingSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:"
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
        qrMessage = AppLocalization.string("Could not open System Settings.")
        qrMessageIsError = true
    }

    private func readDroppedImage(_ providers: [NSItemProvider]) -> Bool {
        guard !isImporting, let provider = providers.first else { return false }
        qrNeedsScreenPermission = false
        // An image file dragged from Finder arrives as a file URL.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let url, error == nil {
                    let payloads = ShareLinkQRCodeReader.payloads(inImageAt: url)
                    Task { @MainActor in append(payloads) }
                } else {
                    Task { @MainActor in
                        qrMessage = error?.localizedDescription
                            ?? AppLocalization.string("No QR code was found in the image.")
                        qrMessageIsError = true
                    }
                }
            }
            return true
        }
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { object, error in
                if let image = object as? NSImage, error == nil {
                    let payloads = ShareLinkQRCodeReader.payloads(in: image)
                    Task { @MainActor in append(payloads) }
                } else {
                    Task { @MainActor in
                        qrMessage = error?.localizedDescription
                            ?? AppLocalization.string("No QR code was found in the image.")
                        qrMessageIsError = true
                    }
                }
            }
            return true
        }
        return false
    }

    private func append(_ payloads: [String]) {
        qrNeedsScreenPermission = false
        guard !payloads.isEmpty else {
            qrMessage = AppLocalization.string("No QR code was found in the image.")
            qrMessageIsError = true
            return
        }
        let joined = payloads.joined(separator: "\n")
        text = text.isEmpty ? joined : text + "\n" + joined
        qrMessage = AppLocalization.format("Read %lld QR codes.", Int64(payloads.count))
        qrMessageIsError = false
    }
}
