import UIKit
import SwiftUI

@main
struct Check {
    @MainActor static func main() {
        let samples = ["", "Alpha", "Alpha\n", "Alpha\nBeta", "中文测试😀\n第二行",
                       "First line alignment with a longer paragraph that wraps onto the second and third lines for alignment verification."]
        var failures = 0
        for category in [UIContentSizeCategory.large, .extraExtraExtraLarge, .accessibilityExtraExtraExtraLarge] {
            let traits = UITraitCollection(preferredContentSizeCategory: category)
            let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
            let inset = max(0, (24 - font.lineHeight) / 2)
            for width: CGFloat in [180, 318, 600] {
                for text in samples {
                    let display = UIHostingController(rootView: Text(text).font(Font(font))
                        .padding(.vertical, inset).frame(minHeight: max(24, font.lineHeight)))
                    let expected = display.sizeThatFits(in: CGSize(width: width, height: 10000)).height
                    let actual = max(24, OutlinerNativeTextMeasurement.size(
                        text: text, font: font, width: width, verticalInset: inset, scale: 3).height)
                    if abs(actual - expected) > 0.34 {
                        failures += 1
                        print("FAIL: category=\(category) width=\(width) text=\(text.debugDescription) display=\(expected) editor=\(actual)")
                    }
                }
            }
        }
        print("\(failures == 0 ? "PASS" : "FAIL"): 54 display/editor height comparisons")
        if failures > 0 { exit(1) }
    }
}
