import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QingzhouKit

struct EditorRequest: Identifiable {
    let id = UUID()
    var node: Node?
}
