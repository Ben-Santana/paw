import SwiftUI
import VisionKit
import AVFoundation

struct IdentityScanner: View {
    var title = "Scan Mac identity"
    let completed: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var permitted = false
    @State private var message = "Requesting camera access…"
    var body: some View {
        NavigationStack {
            Group {
                if permitted && DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    IdentityCamera(completed: { text in dismiss(); completed(text) }, failed: { message = $0; permitted = false })
                } else { ContentUnavailableView("Identity scanner", systemImage: "qrcode.viewfinder", description: Text(message)) }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                permitted = await AVCaptureDevice.requestAccess(for: .video)
                message = permitted ? "QR scanning is unavailable on this device. Check camera restrictions and try again." : "Allow camera access in Settings to scan the QR code on your Mac."
            }
        }
    }
}

private struct IdentityCamera: UIViewControllerRepresentable {
    let completed: (String) -> Void
    let failed: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completed: completed, failed: failed) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, recognizesMultipleItems: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        do { try scanner.startScanning() }
        catch { DispatchQueue.main.async { failed("Camera could not start. Close other camera apps and try again.") } }
        return scanner
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) { controller.stopScanning() }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let completed: (String) -> Void
        let failed: (String) -> Void
        private var finished = false
        init(completed: @escaping (String) -> Void, failed: @escaping (String) -> Void) { self.completed = completed; self.failed = failed }
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !finished else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let text = code.payloadStringValue {
                    finished = true; scanner.stopScanning(); completed(text); return
                }
            }
        }
        func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            failed("Camera scanning became unavailable. Try again.")
        }
    }
}
