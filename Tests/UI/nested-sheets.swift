import Foundation
@testable import LUIAppleBackend

@main
struct NestedSheetsCheck {
    @MainActor static func main() throws {
        let backend = LUIAppleBackend()
        try backend.apply(json: """
        {"generation":1,"ops":[
          {"op":"create-node","id":1,"kind":"root"},
          {"op":"create-node","id":2,"kind":"sheet"},
          {"op":"set-prop","id":2,"property":"text","value":"Settings"},
          {"op":"insert-child","parent":1,"child":2,"index":0}
        ]}
        """)
        precondition(backend.modalPresentation.item?.id == 2)
        try backend.apply(json: """
        {"generation":2,"ops":[
          {"op":"create-node","id":3,"kind":"sheet"},
          {"op":"set-prop","id":3,"property":"text","value":"Tabs"},
          {"op":"insert-child","parent":2,"child":3,"index":0}
        ]}
        """)
        precondition(backend.modalPresentation.item?.id == 2, "Inner sheet must retain its parent")
        precondition(backend.modalPresentation.nestedSheets[2]?.id == 3)
        try backend.apply(json: """
        {"generation":3,"ops":[{"op":"remove-child","parent":2,"child":3},{"op":"drop-node","id":3}]}
        """)
        precondition(backend.modalPresentation.item?.id == 2, "Closing inner sheet keeps Settings")
        precondition(backend.modalPresentation.nestedSheets.isEmpty)
        print("PASS: nested sheets retain Settings while opening and closing")
    }
}
