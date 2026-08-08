import SwiftUI

// Placeholder shell: an empty window. Task 11 fills it in with the drop
// target, crop overlay, preview, and controls, all driven by C64Kit.
//
// The type is deliberately not named `Image64App`: that is the module's own
// name, and shadowing it makes references from later files ambiguous.
@main
struct Image64AppMain: App {
    var body: some Scene {
        WindowGroup("image64") {
            Color.clear
                .frame(minWidth: 640, minHeight: 400)
        }
    }
}
