import Testing
@testable import LogseqChat

@Suite struct AssetPresentationTests {
    @Test func outlinerUsesAssetPreviewForAssetBlocks() {
        #expect(OutlinerBlockPresentationPolicy.usesAssetPreview(isAsset: true))
        #expect(!OutlinerBlockPresentationPolicy.usesAssetPreview(isAsset: false))
    }

    @Test func recognizesImageAndAudioTypes() {
        #expect(AssetPresentationPolicy.kind(assetType: "image/png", localPath: nil) == .image)
        #expect(AssetPresentationPolicy.kind(assetType: "m4a", localPath: nil) == .audio)
        #expect(AssetPresentationPolicy.kind(assetType: nil, localPath: "Assets/voice.wav") == .audio)
        #expect(AssetPresentationPolicy.kind(assetType: "application/pdf", localPath: nil) == .file)
    }
}
