import AppKit
import SwiftUI

/// Pure sizing rules shared by the account detail content and its AppKit host.
///
/// `NSPopover` otherwise uses the first intrinsic size reported by the
/// loading view. Keeping this policy independent from AppKit makes the
/// requested dimensions and screen-bound clamping straightforward to test.
enum TransientPopoverSizingPolicy {
    /// The dashboard is intentionally tall enough for quota, usage,
    /// contribution, activity, and probe sections. AppKit clamps this to the
    /// current screen's visible frame before presenting it.
    static let contentWidth: CGFloat = 640
    static let contentHeight: CGFloat = 760
    static let preferredContentSize = CGSize(width: contentWidth, height: contentHeight)

    static func clampedContentSize(
        preferred: CGSize = preferredContentSize,
        visibleFrame: CGRect? = nil
    ) -> CGSize {
        let width = positiveFinite(preferred.width, fallback: contentWidth)
        let height = positiveFinite(preferred.height, fallback: contentHeight)
        let maxWidth = positiveFinite(visibleFrame?.width, fallback: width)
        let maxHeight = positiveFinite(visibleFrame?.height, fallback: height)

        return CGSize(
            width: min(width, maxWidth),
            height: min(height, maxHeight)
        )
    }

    private static func positiveFinite(_ value: CGFloat?, fallback: CGFloat) -> CGFloat {
        guard let value, value.isFinite, value > 0 else { return fallback }
        return value
    }
}

/// Presents SwiftUI content in an AppKit transient popover.
///
/// The notch panels are non-activating `NSPanel`s, which means SwiftUI's
/// default popover presentation does not reliably receive the outside-click
/// dismissal event. `NSPopover.Behavior.transient` provides the normal AppKit
/// behavior, while the short-lived mouse monitors below cover events that the
/// non-activating host does not route back through the popover.
@MainActor
struct TransientPopoverPresenter<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let content: Content

    init(
        isPresented: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self._isPresented = isPresented
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AnchorView {
        AnchorView()
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        context.coordinator.update(
            isPresented: $isPresented,
            content: AnyView(content),
            anchorView: nsView
        )
    }

    /// SwiftUI 그래프 해제 중 바인딩 재접근 없이 팝오버 정리
    static func dismantleNSView(_ nsView: AnchorView, coordinator: Coordinator) {
        coordinator.dismantle()
    }

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            // The representable is only an anchor; the donut button remains
            // responsible for all hit testing in the source panel.
            nil
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        private var isPresented: Binding<Bool> = .constant(false)
        private var popover: NSPopover?
        private var hostingController: SizingHostingController?
        private weak var anchorView: NSView?
        private var localMouseDownMonitor: Any?
        private var globalMouseDownMonitor: Any?

        private let mouseDownMask: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
        ]

        func update(
            isPresented: Binding<Bool>,
            content: AnyView,
            anchorView: NSView
        ) {
            self.isPresented = isPresented
            self.anchorView = anchorView

            if let hostingController {
                hostingController.rootView = content
            } else {
                let controller = SizingHostingController(rootView: content)
                controller.onLayout = { [weak self] in
                    self?.refreshPopoverContentSize()
                }
                hostingController = controller
            }

            guard isPresented.wrappedValue else {
                dismiss()
                return
            }

            guard let hostingController, anchorView.window != nil else {
                return
            }

            if let popover, popover.isShown {
                // An async child update can change the root layout without
                // another NSViewRepresentable update. Reapply the explicit
                // size here and from SizingHostingController.viewDidLayout.
                refreshPopoverContentSize()
                return
            }

            let popover = NSPopover()
            popover.contentViewController = hostingController
            popover.behavior = .transient
            popover.animates = true
            popover.delegate = self
            self.popover = popover
            refreshPopoverContentSize()

            popover.show(
                relativeTo: anchorView.bounds,
                of: anchorView,
                preferredEdge: .minY
            )

            if popover.isShown {
                refreshPopoverContentSize()
                installMouseDownMonitors()
            } else {
                self.popover = nil
                isPresented.wrappedValue = false
            }
        }

        /// 파괴 중인 SwiftUI 바인딩과 콜백을 분리한 뒤 팝오버 해제
        func dismantle() {
            isPresented = .constant(false)
            popover?.delegate = nil
            dismiss()
            popover = nil
            hostingController?.onLayout = nil
            hostingController = nil
            anchorView = nil
        }

        func dismiss() {
            removeMouseDownMonitors()

            guard let popover else {
                isPresented.wrappedValue = false
                return
            }

            if popover.isShown {
                popover.performClose(nil)
            } else {
                self.popover = nil
                isPresented.wrappedValue = false
            }
        }

        func popoverDidClose(_ notification: Notification) {
            _ = notification
            removeMouseDownMonitors()
            popover = nil
            isPresented.wrappedValue = false
        }

        private func refreshPopoverContentSize() {
            guard let popover, let hostingController else { return }

            let visibleFrame = anchorView?.window?.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
            let contentSize = TransientPopoverSizingPolicy.clampedContentSize(
                preferred: TransientPopoverSizingPolicy.preferredContentSize,
                visibleFrame: visibleFrame
            )

            if popover.contentSize != contentSize {
                popover.contentSize = contentSize
            }
            if hostingController.preferredContentSize != contentSize {
                hostingController.preferredContentSize = contentSize
            }
        }

        private func installMouseDownMonitors() {
            guard localMouseDownMonitor == nil, globalMouseDownMonitor == nil else {
                return
            }

            localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(
                matching: mouseDownMask
            ) { [weak self] event in
                guard let self else { return event }
                return self.handleLocalMouseDown(event)
            }

            globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: mouseDownMask
            ) { [weak self] event in
                self?.handleGlobalMouseDown(event)
            }
        }

        private func removeMouseDownMonitors() {
            if let localMouseDownMonitor {
                NSEvent.removeMonitor(localMouseDownMonitor)
                self.localMouseDownMonitor = nil
            }

            if let globalMouseDownMonitor {
                NSEvent.removeMonitor(globalMouseDownMonitor)
                self.globalMouseDownMonitor = nil
            }
        }

        private func handleLocalMouseDown(_ event: NSEvent) -> NSEvent? {
            guard popover?.isShown == true else {
                removeMouseDownMonitors()
                return event
            }

            guard !isInsidePopover(event) else {
                return event
            }

            let clickedSourceAnchor = isInsideSourceAnchor(event)
            dismiss()

            // The source donut would otherwise receive this same mouse-down
            // after dismissal and immediately set the binding back to true.
            // Swallow only that source click; other in-app controls continue
            // receiving their outside click normally.
            return clickedSourceAnchor ? nil : event
        }

        private func handleGlobalMouseDown(_ event: NSEvent) {
            guard popover?.isShown == true else {
                removeMouseDownMonitors()
                return
            }

            // Global monitors only receive events dispatched to another app,
            // so they cannot be inside this popover's window.
            _ = event
            dismiss()
        }

        /// 상세 팝오버 및 그 자식 서비스 알림 창의 클릭을 내부 입력으로 처리
        private func isInsidePopover(_ event: NSEvent) -> Bool {
            guard
                let popoverWindow = popover?.contentViewController?.view.window,
                let eventWindow = event.window
            else {
                return false
            }

            if eventWindow !== popoverWindow {
                var parent = eventWindow.parent
                while let window = parent {
                    if window === popoverWindow { return true }
                    parent = window.parent
                }
                return false
            }

            guard let contentView = popoverWindow.contentView else {
                return true
            }

            let point = contentView.convert(event.locationInWindow, from: nil)
            return contentView.bounds.contains(point)
        }

        private func isInsideSourceAnchor(_ event: NSEvent) -> Bool {
            guard
                let anchorView,
                let anchorWindow = anchorView.window,
                let eventWindow = event.window,
                eventWindow === anchorWindow
            else {
                return false
            }

            let point = anchorView.convert(event.locationInWindow, from: nil)
            return anchorView.bounds.contains(point)
        }
    }

    @MainActor
    private final class SizingHostingController: NSHostingController<AnyView> {
        var onLayout: (() -> Void)?

        override func viewDidLayout() {
            super.viewDidLayout()
            onLayout?()
        }
    }
}
