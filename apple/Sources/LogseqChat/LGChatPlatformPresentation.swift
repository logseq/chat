import Observation
import SwiftUI
import LogseqChatModel

import CryptoKit
import PhotosUI
import UniformTypeIdentifiers
#if os(iOS)
import QuickLook
import UIKit
#endif

public enum LGChatAttachmentService: String, CaseIterable, Sendable {
    case files
    case camera
    case photos
    case audio
}

@MainActor
@Observable
public final class LGChatPlatformPresentationCoordinator {
    public private(set) var attachmentService: LGChatAttachmentService?
    public private(set) var attachmentTargetBlockID: String?
    public private(set) var pendingDeletionBlockIDs: [String] = []
    #if os(iOS)
    public private(set) var previewAssetURL: URL?
    var pageSharePayload: NodeSharePayload?
    #endif

    public init() {
    }

    @discardableResult
    public func presentAttachment(
        _ rawValue: String,
        targetBlockID: String? = nil
    ) -> Bool {
        guard let service = LGChatAttachmentService(rawValue: rawValue) else {
            return false
        }
        attachmentService = service
        attachmentTargetBlockID = targetBlockID
        return true
    }

    public func dismissAttachment() {
        attachmentService = nil
    }

    public func completeAttachment() {
        attachmentService = nil
        attachmentTargetBlockID = nil
    }

    public func confirmDeletion(of blockIDs: [String]) {
        pendingDeletionBlockIDs = blockIDs
    }

    public func dismissDeletion() {
        pendingDeletionBlockIDs = []
    }

    #if os(iOS)
    @discardableResult
    public func presentAsset(_ asset: LGChatAssetPresentationPayload) -> Bool {
        guard let url = LocalAssetPath.resolve(
            asset.localPath,
            title: asset.title,
            assetType: asset.assetType
        ) else { return false }
        previewAssetURL = url
        return true
    }

    public func updatePreviewAssetURL(_ url: URL?) {
        previewAssetURL = url
    }

    @discardableResult
    public func presentPageShare(_ payload: LGChatPageSharePayload) -> Bool {
        pageSharePayload = NodeSharePayload(
            text: payload.text,
            localAssetPaths: payload.localAssetPaths
        )
        return true
    }

    @discardableResult
    public func presentFile(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        pageSharePayload = NodeSharePayload(fileURL: url)
        return true
    }

    #endif
}


struct LGChatImportedAsset: Sendable {
    let title: String
    let assetType: String
    let size: Int
    let checksum: String
    let path: String
}

enum LGChatAssetImporter {
    nonisolated static func persist(_ sourceURL: URL) async throws -> LGChatImportedAsset {
        try await Task.detached(priority: .utility) {
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
            let directory = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("Assets", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let destination = directory.appendingPathComponent(
                UUID().uuidString + "-" + sourceURL.lastPathComponent
            )
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let handle = try FileHandle(forReadingFrom: destination)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                hash.update(data: chunk)
            }
            let checksum = hash.finalize().map { String(format: "%02x", $0) }.joined()
            return LGChatImportedAsset(
                title: sourceURL.lastPathComponent,
                assetType: destination.pathExtension.lowercased(),
                size: size,
                checksum: checksum,
                path: destination.path
            )
        }.value
    }

    nonisolated static func persist(
        data: Data,
        title: String
    ) async throws -> LGChatImportedAsset {
        try await Task.detached(priority: .utility) {
            let directory = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("Assets", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let destination = directory.appendingPathComponent(title)
            try data.write(to: destination, options: .atomic)
            let checksum = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            return LGChatImportedAsset(
                title: title,
                assetType: destination.pathExtension.lowercased(),
                size: data.count,
                checksum: checksum,
                path: destination.path
            )
        }.value
    }
}

struct LGChatPlatformPresentationHost: ViewModifier {
    @Bindable var coordinator: LGChatPlatformPresentationCoordinator
    let store: LogseqChatStore
    let stageAsset: @MainActor (String) throws -> Void

    @State private var selectedPhotoItems: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: presentationBinding(for: .files),
                allowedContentTypes: [.image, .audio, .data],
                allowsMultipleSelection: true,
                onCompletion: importFiles
            )
            #if !os(iOS)
            .photosPicker(
                isPresented: presentationBinding(for: .photos),
                selection: $selectedPhotoItems,
                maxSelectionCount: 20,
                matching: .images
            )
            .onChange(of: selectedPhotoItems) { _, items in
                importPhotos(items)
            }
            #endif
            .alert(deletionTitle, isPresented: deletionBinding) {
                Button("Delete", role: .destructive) {
                    store.outlinerEvent(LogseqOutlinerEvent(type: "confirmDelete"))
                    coordinator.dismissDeletion()
                }
                Button("Cancel", role: .cancel) {
                    coordinator.dismissDeletion()
                }
            } message: {
                Text("This deletes the block and all of its children. Pages use Recycle instead.")
            }
            #if os(iOS)
            .quickLookPreview(previewAssetBinding)
            .sheet(item: pageSharePayloadBinding) { payload in
                NodeShareSheet(items: payload.items)
            }
            .sheet(isPresented: mediaPanelBinding) {
                let target = coordinator.attachmentTargetBlockID
                VStack(spacing: 0) {
                    LGChatMediaPanel(initialService: coordinator.attachmentService ?? .photos) { items in
                        importPhotos(items, closeWhenFinished: false, targetBlockID: target)
                    } onCapture: { data in
                        importCapturedData(data, targetBlockID: target)
                    } onPhotoData: { data, fileExtension in
                        importCapturedData(data, targetBlockID: target,
                                           title: "Photo-\(UUID().uuidString).\(fileExtension)")
                    }
                }
                .background(Color(uiColor: .systemBackground))
                .presentationDetents([.fraction(0.58), .large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(32)
            }
            .sheet(isPresented: presentationBinding(for: .audio)) {
                AudioRecorderSheet(
                    targetBlockID: coordinator.attachmentTargetBlockID
                ) { asset, targetBlockID, transcript in
                    try addImportedAsset(LGChatImportedAsset(
                        title: asset.title, assetType: AudioRecordingPolicy.fileExtension,
                        size: asset.size, checksum: asset.checksum, path: asset.path
                    ), targetBlockID: targetBlockID, transcript: transcript)
                    coordinator.completeAttachment()
                }
            }
            #endif
    }

    private var mediaPanelBinding: Binding<Bool> {
        Binding(
            get: { coordinator.attachmentService == .camera || coordinator.attachmentService == .photos },
            set: { if !$0 { coordinator.completeAttachment() } }
        )
    }

    private func presentationBinding(for service: LGChatAttachmentService) -> Binding<Bool> {
        Binding(
            get: { coordinator.attachmentService == service },
            set: { presented in
                if !presented {
                    coordinator.dismissAttachment()
                }
            }
        )
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { !coordinator.pendingDeletionBlockIDs.isEmpty },
            set: { presented in
                if !presented {
                    coordinator.dismissDeletion()
                }
            }
        )
    }

    #if os(iOS)
    private var previewAssetBinding: Binding<URL?> {
        Binding(
            get: { coordinator.previewAssetURL },
            set: { coordinator.updatePreviewAssetURL($0) }
        )
    }

    private var pageSharePayloadBinding: Binding<NodeSharePayload?> {
        Binding(
            get: { coordinator.pageSharePayload },
            set: { coordinator.pageSharePayload = $0 }
        )
    }
    #endif

    private var deletionTitle: String {
        coordinator.pendingDeletionBlockIDs.count > 1 ? "Delete blocks?" : "Delete block?"
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else {
            coordinator.completeAttachment()
            return
        }
        let target = coordinator.attachmentTargetBlockID
        Task {
            for url in urls {
                do {
                    try addImportedAsset(try await LGChatAssetImporter.persist(url), targetBlockID: target)
                } catch {
                    logger.error("Asset import failed: \(String(describing: error))")
                }
            }
            coordinator.completeAttachment()
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem], closeWhenFinished: Bool = true,
                              targetBlockID: String? = nil) {
        guard !items.isEmpty else { return }
        selectedPhotoItems = []
        let target = targetBlockID ?? coordinator.attachmentTargetBlockID
        Task {
            for item in items {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        continue
                    }
                    let fileExtension = item.supportedContentTypes.first?
                        .preferredFilenameExtension ?? "jpg"
                    let title = "Photo-\(UUID().uuidString).\(fileExtension)"
                    try addImportedAsset(
                        try await LGChatAssetImporter.persist(data: data, title: title),
                        targetBlockID: target
                    )
                } catch {
                    logger.error("Photo import failed: \(String(describing: error))")
                }
            }
            if closeWhenFinished { coordinator.completeAttachment() }
        }
    }

    #if os(iOS)
    private func importCapturedData(_ data: Data, targetBlockID: String?,
                                    title: String = "Camera-\(UUID().uuidString).jpg") {
        Task {
            do {
                try addImportedAsset(
                    try await LGChatAssetImporter.persist(data: data, title: title),
                    targetBlockID: targetBlockID
                )
            } catch {
                logger.error("Camera import failed: \(String(describing: error))")
            }
        }
    }
    #endif

    private func addImportedAsset(_ asset: LGChatImportedAsset, targetBlockID: String? = nil, transcript: String? = nil) throws {
        let payload = LGChatStagedAssetPayload(
            uuid: UUID().uuidString.lowercased(), title: asset.title,
            now: Int64(Date().timeIntervalSince1970 * 1_000),
            assetType: asset.assetType, assetSize: asset.size,
            assetChecksum: asset.checksum,
            localPath: LocalAssetPath.storedPath(asset.path),
            targetBlockId: targetBlockID,
            transcript: transcript, transcriptUUID: transcript == nil ? nil : UUID().uuidString.lowercased()
        )
        let data = try JSONEncoder().encode(payload)
        try stageAsset(String(decoding: data, as: UTF8.self))
    }
}

private struct LGChatStagedAssetPayload: Encodable {
    let uuid: String
    let title: String
    let now: Int64
    let assetType: String
    let assetSize: Int
    let assetChecksum: String
    let localPath: String
    let targetBlockId: String?
    let transcript: String?
    let transcriptUUID: String?
}
