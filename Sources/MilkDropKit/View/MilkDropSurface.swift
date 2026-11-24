import MetalKit
import SwiftUI

/// Draws frames into a Metal view at up to 120 fps (ProMotion); the renderer keeps its own frame rate in `fps`.
@MainActor public protocol MilkDropDrawing: AnyObject {
    func draw(in view: MTKView)
    func sizeChanged(_ size: CGSize, in view: MTKView)
}

/// SwiftUI view of a `MilkDropDrawing`, on macOS and iOS.
public struct MilkDropSurface {
    let drawing: MilkDropDrawing

    public init(_ drawing: MilkDropDrawing) { self.drawing = drawing }

    @MainActor func makeView(_ coordinator: Coordinator) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 120
        view.framebufferOnly = false  // window captures (screenshots) read the drawable
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = coordinator
        return view
    }

    @MainActor public func makeCoordinator() -> Coordinator { Coordinator(drawing) }

    @MainActor public final class Coordinator: NSObject, MTKViewDelegate {
        var drawing: MilkDropDrawing
        private var last: ContinuousClock.Instant?
        init(_ drawing: MilkDropDrawing) { self.drawing = drawing }

        /// At most 60 frames a second: presets move a fixed step per frame, and ProMotion screens call at 120 Hz
        /// whatever `preferredFramesPerSecond` says, which made them run twice as fast, in jerks.
        public func draw(in view: MTKView) {
            let now = ContinuousClock.now
            if let last, now - last < .milliseconds(13) { return }
            last = now
            drawing.draw(in: view)
        }
        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { drawing.sizeChanged(size, in: view) }
    }
}

#if canImport(AppKit)
extension MilkDropSurface: NSViewRepresentable {
    public func makeNSView(context: Context) -> MTKView { makeView(context.coordinator) }
    public func updateNSView(_ view: MTKView, context: Context) { context.coordinator.drawing = drawing }
}
#else
extension MilkDropSurface: UIViewRepresentable {
    public func makeUIView(context: Context) -> MTKView { makeView(context.coordinator) }
    public func updateUIView(_ view: MTKView, context: Context) { context.coordinator.drawing = drawing }
}
#endif
