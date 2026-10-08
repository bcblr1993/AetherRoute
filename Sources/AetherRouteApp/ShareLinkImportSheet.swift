import AetherRouteKit
import AppKit
import CoreImage
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
        guard let image = CIImage(contentsOf: url) else { return [] }
        return payloads(in: image)
    }

    static func payloads(in image: NSImage) -> [String] {
        guard let data = image.tiffRepresentation,
              let ciImage = CIImage(data: data) else { return [] }
        return payloads(in: ciImage)
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
                .onDrop(of: [.image, .fileURL], isTargeted: nil, perform: readDroppedImage)
                .accessibilityLabel(AppLocalization.string("Node links"))
                .accessibilityIdentifier("share-link-text")

            HStack(spacing: AetherVisual.s2) {
                Button(AppLocalization.string("Paste"), systemImage: "doc.on.clipboard") {
                    pasteFromClipboard()
                }
                .aetherGlassButton()
                .accessibilityIdentifier("share-link-paste")
                Button(AppLocalization.string("Choose QR Code Image…"), systemImage: "qrcode") {
                    isImagePickerPresented = true
                }
                .aetherGlassButton()
                .accessibilityIdentifier("share-link-choose-image")
                Spacer(minLength: AetherVisual.s2)
                if let qrMessage {
                    Text(qrMessage)
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                }
            }

            Text(AppLocalization.string("Links are parsed on this Mac; AetherRoute does not contact any of the servers until you connect."))
                .font(.caption)
                .foregroundStyle(AetherVisual.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                // Cancel and the primary action share the trailing edge, as in
                // every macOS sheet.
                Spacer()
                Button(AppLocalization.string("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isImporting)
                Button {
                    isImporting = true
                    Task {
                        let imported = await tunnel.importShareLinks(text)
                        isImporting = false
                        if imported { dismiss() }
                    }
                } label: {
                    AetherProgressButtonLabel(
                        AppLocalization.string("Import"),
                        isWorking: isImporting
                    )
                }
                .aetherGlassButton(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(isImporting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("share-link-import")
            }

            if tunnel.profileMessageIsError, let message = tunnel.profileMessage {
                AetherInlineMessage(text: message)
            }
        }
        .padding(AetherVisual.dialogPadding)
        .aetherSheetFrame()
        .fileImporter(
            isPresented: $isImagePickerPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            append(ShareLinkQRCodeReader.payloads(inImageAt: url))
        }
        .onAppear { tunnel.clearProfileMessage() }
    }

    private func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general
        if let string = pasteboard.string(forType: .string),
           !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = text.isEmpty ? string : text + "\n" + string
            qrMessage = nil
            return
        }
        // A copied screenshot of a QR code.
        if let image = NSImage(pasteboard: pasteboard) {
            append(ShareLinkQRCodeReader.payloads(in: image))
        }
    }

    private func readDroppedImage(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                guard let image = object as? NSImage else { return }
                let payloads = ShareLinkQRCodeReader.payloads(in: image)
                Task { @MainActor in append(payloads) }
            }
            return true
        }
        return false
    }

    private func append(_ payloads: [String]) {
        guard !payloads.isEmpty else {
            qrMessage = AppLocalization.string("No QR code was found in the image.")
            return
        }
        let joined = payloads.joined(separator: "\n")
        text = text.isEmpty ? joined : text + "\n" + joined
        qrMessage = AppLocalization.format("Read %lld QR codes.", Int64(payloads.count))
    }
}
