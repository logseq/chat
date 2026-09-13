import LUIAppleBackend
import SwiftUI

@MainActor
enum LGChatLiquidGlassTweak {
    static let identifier = "liquid-glass"
    static let fingerprint =
        "lui-tweak-v1|12:liquid-glass|profiles:ios/swiftui|properties:5:shape:string:required:none"

    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.registerTweak(
            LUIAppleTweak(
                identifier: identifier,
                fingerprint: fingerprint,
                properties: [
                    .init(name: "shape", kind: .string, isRequired: true),
                ]
            ) { content, context in
                let shapeName: String
                if case let .string(value) = context.property("shape") {
                    shapeName = value
                } else {
                    shapeName = ""
                }
                let shape: LGChatLiquidGlassSurface.Shape
                switch shapeName {
                case "circle":
                    shape = .circle
                case "container":
                    shape = .container
                case "rounded-rectangle":
                    shape = .roundedRectangle
                default:
                    shape = .capsule
                }
                if shape == .capsule {
                    return AnyView(
                        content
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .modifier(LGChatLiquidGlassSurface(shape: shape))
                    )
                }
                return AnyView(content.modifier(LGChatLiquidGlassSurface(shape: shape)))
            }
        )
    }
}

struct LGChatLiquidGlassSurface: ViewModifier {
    enum Shape {
        case capsule
        case circle
        case container
        case roundedRectangle
    }

    let shape: Shape

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            if shape == .circle {
                content.glassEffect(.regular.interactive(), in: .circle)
            } else if shape == .roundedRectangle {
                content.glassEffect(
                    .regular,
                    in: .rect(cornerRadius: 24)
                )
            } else if shape == .container {
                content.glassEffect(
                    .regular,
                    in: .rect(cornerRadius: 28)
                )
            } else {
                content.glassEffect(.regular.interactive(), in: .capsule)
            }
        } else {
            if shape == .circle {
                content.background(.ultraThinMaterial, in: Circle())
            } else if shape == .roundedRectangle {
                content.background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
            } else if shape == .container {
                content.background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                )
            } else {
                content.background(.ultraThinMaterial, in: Capsule())
            }
        }
    }
}
