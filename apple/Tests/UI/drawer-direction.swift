import Foundation
@testable import LUIAppleBackend

@main
struct DrawerDirectionCheck {
    static func main() {
        let cases: [(Double, Double, Bool)] = [
            (4, 1, false), (10, 2, false), (20, 18, false),
            (18, 20, false), (0, 30, false), (30, 0, true),
            (-30, 2, true), (24, 8, true), (0, 0, false)
        ]
        var failures = 0
        for (x, y, expected) in cases {
            let actual = LUIDrawerGeometry.gestureIsEligible(
                enabled: true, translationX: x, translationY: y
            )
            if actual != expected {
                print("FAIL: drag (\(x), \(y)) eligibility = \(actual)")
                failures += 1
            }
        }
        assert(!LUIDrawerGeometry.gestureIsEligible(
            enabled: false, translationX: 100, translationY: 0
        ))
        if failures > 0 { exit(1) }
        print("PASS: drawer rejects jitter and diagonal scrolling")
    }
}
