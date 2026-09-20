import Testing
@testable import LogseqChat
import LogseqChatModel

@Suite struct AssetPresentationTests {
    @Test func recognizesImageAndAudioTypes() {
        #expect(AssetPresentationPolicy.kind(assetType: "image/png", localPath: nil) == .image)
        #expect(AssetPresentationPolicy.kind(assetType: "m4a", localPath: nil) == .audio)
        #expect(AssetPresentationPolicy.kind(assetType: nil, localPath: "Assets/voice.wav") == .audio)
        #expect(AssetPresentationPolicy.kind(assetType: "application/pdf", localPath: nil) == .file)
        #expect(AssetPresentationPolicy.kind(assetType: nil, localPath: "") == .file)
        #expect(AssetPresentationPolicy.kind(assetType: nil, localPath: "Assets/photo.webp") == .image)
    }

    @Test func nodeShareIncludesTextAndEveryUniqueLocalAsset() {
        let blocks = [
            block(uuid: "text", title: "A note"),
            block(uuid: "audio", title: "Voice.m4a", assetPath: "Assets/voice.m4a"),
            block(uuid: "image", title: "Photo.jpg", assetPath: "Assets/photo.jpg"),
            block(uuid: "duplicate", title: "Voice copy", assetPath: "Assets/voice.m4a"),
            block(uuid: "remote", title: "Not downloaded", isAsset: true),
        ]

        #expect(NodeSharePolicy.text(pageTitle: "Project", blocks: blocks) == """
        Project
        - A note
        - Voice.m4a
        - Photo.jpg
        - Voice copy
        - Not downloaded
        """)
        #expect(NodeSharePolicy.localAssetPaths(blocks: blocks) == [
            "Assets/voice.m4a", "Assets/photo.jpg",
        ])
    }

    private func block(
        uuid: String,
        title: String,
        assetPath: String? = nil,
        isAsset: Bool = false
    ) -> LogseqBlock {
        LogseqBlock(
            uuid: uuid,
            title: title,
            pageId: "page",
            parentId: nil,
            createdAt: 1,
            updatedAt: 1,
            syncStatus: nil,
            isAsset: isAsset || assetPath != nil,
            localPath: assetPath
        )
    }
}
