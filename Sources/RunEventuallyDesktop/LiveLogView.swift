import AppKit
import RunEventuallyCore
import SwiftUI

/// Appends to a native text view so refreshes do not reconstruct the entire log.
struct LiveLogView: NSViewRepresentable {
    let path: String
    let finished: Bool

    func makeCoordinator() -> Coordinator { Coordinator(path: path) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        context.coordinator.attach(text, scroll: scroll)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.finished = finished
        context.coordinator.refresh()
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
    }

    @MainActor final class Coordinator {
        let reader: RunLogReader
        weak var text: NSTextView?
        weak var scroll: NSScrollView?
        var timer: Timer?
        var finished = false

        init(path: String) { reader = RunLogReader(path: path) }

        func attach(_ text: NSTextView, scroll: NSScrollView) {
            self.text = text
            self.scroll = scroll
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            refresh()
        }

        func refresh() {
            guard let text, let scroll else { return }
            do {
                let chunk = try reader.read(finished: finished)
                guard !chunk.isEmpty else { return }
                let following = scroll.contentView.bounds.maxY >= text.bounds.maxY - 24
                text.textStorage?.append(NSAttributedString(string: chunk, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.textColor,
                ]))
                if following { text.scrollToEndOfDocument(nil) }
                text.toolTip = nil
            } catch {
                text.toolTip = "Unable to read log: \(error.localizedDescription)"
            }
        }
    }
}
