//
//  AnchoredCardPresenter.swift
//  Osaurus
//
//  A transient, arrowless SwiftUI card attached to its source control.
//

import AppKit
import QuartzCore
import SwiftUI

extension View {
    /// Presents a card above this view, falling back below when the display
    /// has more room there. Content receives the actual screen-constrained
    /// size and owns its surface, border and corner treatment.
    func anchoredCard<Card: View>(
        isPresented: Binding<Bool>,
        size: CGSize,
        accessibilityLabel: String = "Options",
        @ViewBuilder content: () -> Card
    ) -> some View {
        background(
            AnchoredCardAnchor(
                isPresented: isPresented,
                size: size,
                accessibilityLabel: accessibilityLabel,
                content: content()
            )
        )
    }
}

/// Screen coordinates use AppKit's bottom-left origin. Keep this calculation
/// independent of the window so edge cases can be checked without showing UI.
enum AnchoredCardPlacement {
    static func frame(
        anchor: CGRect,
        size: CGSize,
        visibleFrame: CGRect,
        rightToLeft: Bool = false,
        preferAbove: Bool? = nil
    ) -> CGRect {
        let inset: CGFloat = 12
        let gap: CGFloat = 8
        let safe = visibleFrame.insetBy(
            dx: min(inset, visibleFrame.width / 4),
            dy: min(inset, visibleFrame.height / 4)
        )
        let width = min(max(1, size.width), safe.width)
        let desiredHeight = max(1, size.height)
        let above = max(0, safe.maxY - anchor.maxY - gap)
        let below = max(0, anchor.minY - gap - safe.minY)
        let placeAbove = preferAbove ?? (above >= desiredHeight || (below < desiredHeight && above >= below))
        let height = min(desiredHeight, max(1, placeAbove ? above : below))
        let preferredX = rightToLeft ? anchor.maxX - width : anchor.minX
        let preferredY = placeAbove ? anchor.maxY + gap : anchor.minY - gap - height
        return CGRect(
            x: min(max(preferredX, safe.minX), safe.maxX - width),
            y: min(max(preferredY, safe.minY), safe.maxY - height),
            width: width,
            height: height
        )
    }
}

/// The native window and its SwiftUI content share one presentation size.
/// Content can clip a retiring column without maintaining a second animation.
struct AnchoredCardMetrics: Equatable {
    var visibleSize: CGSize
    var targetSize: CGSize
    var availableSize: CGSize
    var isAnimating: Bool
}

private struct AnchoredCardMetricsKey: EnvironmentKey {
    static let defaultValue: AnchoredCardMetrics? = nil
}

extension EnvironmentValues {
    var anchoredCardMetrics: AnchoredCardMetrics? {
        get { self[AnchoredCardMetricsKey.self] }
        set { self[AnchoredCardMetricsKey.self] = newValue }
    }
}

@MainActor
private final class AnchoredCardPresentation: ObservableObject {
    var content: (AnchoredCardMetrics) -> AnyView
    var metrics: AnchoredCardMetrics

    init(content: @escaping (AnchoredCardMetrics) -> AnyView, metrics: AnchoredCardMetrics) {
        self.content = content
        self.metrics = metrics
    }

    func update(content: @escaping (AnchoredCardMetrics) -> AnyView, metrics: AnchoredCardMetrics) {
        objectWillChange.send()
        self.content = content
        self.metrics = metrics
    }
}

private struct AnchoredCardRoot: View {
    @ObservedObject var presentation: AnchoredCardPresentation

    var body: some View {
        presentation.content(presentation.metrics)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transaction {
                // The native viewport is the only animation clock. Letting
                // SwiftUI animate layout again would lag behind the surface.
                $0.animation = nil
                $0.disablesAnimations = true
            }
    }
}

private struct AnchoredCardAnchor<Card: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let size: CGSize
    let accessibilityLabel: String
    let content: Card

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.locale) private var locale

    func makeCoordinator() -> AnchoredCardCoordinator { AnchoredCardCoordinator() }

    func makeNSView(context: Context) -> AnchoredCardMarkerView {
        let view = AnchoredCardMarkerView()
        context.coordinator.anchor = view
        view.onGeometryChange = { [weak coordinator = context.coordinator] in
            coordinator?.scheduleUpdate()
        }
        return view
    }

    func updateNSView(_ view: AnchoredCardMarkerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isPresented = $isPresented
        coordinator.requestedSize = size
        coordinator.accessibilityLabel = accessibilityLabel
        coordinator.rightToLeft = layoutDirection == .rightToLeft
        coordinator.content = { metrics in
            AnyView(content
                .environment(\.anchoredCardMetrics, metrics)
                // A separate hosting window needs its own focus environment.
                // Forward visual values rather than the parent's focus bridge.
                .environment(\.theme, theme)
                .environment(\.colorScheme, colorScheme)
                .environment(\.layoutDirection, layoutDirection)
                .environment(\.locale, locale)
                .tint(theme.accentColor))
        }
        coordinator.scheduleUpdate()
    }

    static func dismantleNSView(_ view: AnchoredCardMarkerView, coordinator: AnchoredCardCoordinator) {
        view.onGeometryChange = nil
        coordinator.tearDown(restoreFocus: false)
        coordinator.anchor = nil
        coordinator.isPresented = nil
    }
}

@MainActor
private final class AnchoredCardCoordinator {
    weak var anchor: AnchoredCardMarkerView?
    var isPresented: Binding<Bool>?
    var requestedSize: CGSize = .zero
    var accessibilityLabel = ""
    var rightToLeft = false
    var content: (AnchoredCardMetrics) -> AnyView = { _ in AnyView(EmptyView()) }

    private weak var parent: NSWindow?
    private weak var previousResponder: NSResponder?
    private var panel: AnchoredCardPanel?
    private var host: NSHostingView<AnchoredCardRoot>?
    private var presentation: AnchoredCardPresentation?
    private var resizeTransition: AnchoredCardResizeTransition?
    private var resizeTimer: Timer?
    private var availableSize: CGSize = .zero
    private var lastAnchorFrame: CGRect?
    private var prefersAbove: Bool?
    private var suppressNextAnimation = false
    private var observers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var updateScheduled = false
    private var presentedFrame = NSRect.zero

    // NSViewRepresentable updates and layout callbacks may occur during a
    // SwiftUI render. Defer panel mutations and binding writes one turn.
    func scheduleUpdate(animateResize: Bool = true) {
        if !animateResize { suppressNextAnimation = true }
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            self.updatePresentation()
        }
    }

    private func updatePresentation() {
        guard isPresented?.wrappedValue == true else {
            tearDown(restoreFocus: true)
            return
        }
        guard let anchor, let window = anchor.window, window.isVisible,
            !window.isMiniaturized, NSApp.isActive
        else {
            if panel != nil { dismiss(restoreFocus: false) }
            return
        }
        guard anchor.bounds.width > 0, anchor.bounds.height > 0 else { return }

        if let parent, parent !== window {
            tearDown(restoreFocus: false)
        }
        let placement = placement(anchor: anchor, window: window)
        let frame = placement.frame
        availableSize = placement.availableSize
        // A model label can change the chip's width without moving its
        // origin. That is a selection resize, not a window move to snap.
        let anchorMoved = lastAnchorFrame.map { $0.origin != placement.anchorFrame.origin } ?? false
        lastAnchorFrame = placement.anchorFrame
        prefersAbove = frame.minY >= placement.anchorFrame.maxY
        let skipAnimation = suppressNextAnimation || anchorMoved
        suppressNextAnimation = false
        if panel == nil {
            present(in: window, frame: frame)
        }
        guard let panel else { return }
        panel.setAccessibilityLabel(accessibilityLabel)
        panel.title = accessibilityLabel
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if !skipAnimation, !reduceMotion, resizeTransition?.to == frame {
            // Provider refreshes and option edits must not restart a resize.
            updateContent(target: frame.size, isAnimating: true)
            return
        }
        if presentedFrame == frame {
            stopResize()
            updateContent(target: frame.size, isAnimating: false)
            return
        }
        let changesSize = presentedFrame.size != frame.size
        if changesSize && !skipAnimation && !reduceMotion {
            // Retarget from the last frame actually drawn, including when the
            // user reverses direction before the previous resize finishes.
            resizeTransition = AnchoredCardResizeTransition(
                from: presentedFrame, to: frame, startTime: CACurrentMediaTime()
            )
            updateContent(target: frame.size, isAnimating: true)
            if resizeTimer == nil {
                let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.advanceResize() }
                }
                resizeTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        } else {
            stopResize()
            applyFrame(frame, target: frame.size, isAnimating: false)
        }
    }

    private func advanceResize() {
        guard let transition = resizeTransition, panel != nil else {
            stopResize()
            return
        }
        let now = CACurrentMediaTime()
        let finished = transition.isComplete(at: now)
            || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let frame = finished ? transition.to : transition.frame(at: now)
        if finished { stopResize() }
        applyFrame(frame, target: transition.to.size, isAnimating: !finished)
    }

    private func applyFrame(_ frame: CGRect, target: CGSize, isAnimating: Bool) {
        guard let panel else { return }
        presentedFrame = frame
        panel.setFrame(frame, display: false)
        updateContent(target: target, isAnimating: isAnimating)
        host?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }

    private func updateContent(target: CGSize, isAnimating: Bool) {
        presentation?.update(content: content, metrics: AnchoredCardMetrics(
            visibleSize: presentedFrame.size,
            targetSize: target,
            availableSize: availableSize,
            isAnimating: isAnimating
        ))
    }

    private func stopResize() {
        resizeTimer?.invalidate()
        resizeTimer = nil
        resizeTransition = nil
    }

    private func placement(anchor: NSView, window: NSWindow) -> (frame: CGRect, anchorFrame: CGRect, availableSize: CGSize) {
        let anchorFrame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchorFrame.midX, y: anchorFrame.midY)) }
            ?? window.screen
            ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? window.frame
        let safeFrame = visibleFrame.insetBy(
            dx: min(12, visibleFrame.width / 4), dy: min(12, visibleFrame.height / 4)
        )
        return (
            AnchoredCardPlacement.frame(
                anchor: anchorFrame,
                size: requestedSize,
                visibleFrame: visibleFrame,
                rightToLeft: rightToLeft,
                preferAbove: !suppressNextAnimation && lastAnchorFrame?.origin == anchorFrame.origin ? prefersAbove : nil
            ),
            anchorFrame,
            safeFrame.size
        )
    }

    private func present(in parent: NSWindow, frame: NSRect) {
        self.parent = parent
        previousResponder = parent.firstResponder
        let panel = AnchoredCardPanel(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // AppKit's shadow includes a bright rim on macOS. Let the card's
        // themed stroke own its edge instead of stacking native chrome.
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = parent.level
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.onCancel = { [weak self] in self?.dismiss(restoreFocus: true) }

        let presentation = AnchoredCardPresentation(
            content: content,
            metrics: AnchoredCardMetrics(
                visibleSize: frame.size, targetSize: frame.size,
                availableSize: availableSize, isAnimating: false
            )
        )
        let host = NSHostingView(rootView: AnchoredCardRoot(presentation: presentation))
        self.presentation = presentation
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
        self.host = host
        presentedFrame = frame
        installObservers(parent: parent, panel: panel)
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.recalculateKeyViewLoop()
    }

    private func installObservers(parent: NSWindow, panel: NSWindow) {
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            observers.append(center.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleUpdate(animateResize: false) }
            })
        }
        for name in [NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss(restoreFocus: false) }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(restoreFocus: false) }
        })
        // Allow a nested native popover or sheet to become key. Evaluate
        // after the current event so AppKit has installed the new key window.
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.panel != nil else { return }
                if !self.belongsToCard(NSApp.keyWindow) {
                    self.dismiss(restoreFocus: false)
                }
            }
        })
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] notification in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.panel != nil else { return }
                if !self.belongsToCard(NSApp.keyWindow) { self.dismiss(restoreFocus: false) }
            }
        })
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handle(event) == nil
            }
            return consumed ? nil : event
        }
    }

    private func belongsToCard(_ window: NSWindow?) -> Bool {
        guard let panel else { return false }
        var candidate = window
        while let current = candidate {
            if current === panel { return true }
            candidate = current.parent ?? current.sheetParent
        }
        return false
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let panel else { return event }
        if event.type == .keyDown {
            // Parent chat windows have their own Escape-to-close shortcut.
            // Keep focus here and consume Escape before it can reach that.
            if event.window === panel, event.keyCode == 53 {
                dismiss(restoreFocus: true)
                return nil
            }
            return event
        }
        guard !belongsToCard(event.window) else { return event }
        if let anchor, let parent, event.window === parent {
            let point = anchor.convert(event.locationInWindow, from: nil)
            // Let a second click on the source button toggle its binding.
            // Closing before the button's action would immediately reopen it.
            if anchor.bounds.contains(point) { return event }
        }
        // The outside click keeps its normal action and focus destination.
        dismiss(restoreFocus: false)
        return event
    }

    private func dismiss(restoreFocus: Bool) {
        let binding = isPresented
        tearDown(restoreFocus: restoreFocus)
        if binding?.wrappedValue == true { binding?.wrappedValue = false }
    }

    func tearDown(restoreFocus: Bool) {
        stopResize()
        lastAnchorFrame = nil
        prefersAbove = nil
        suppressNextAnimation = false
        guard let panel else { return }
        let shouldRestore = restoreFocus && NSApp.isActive && belongsToCard(NSApp.keyWindow)
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        panel.onCancel = nil
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        host = nil
        presentation = nil
        if shouldRestore, let parent, parent.isVisible, !parent.isMiniaturized {
            parent.makeKey()
            if let previousResponder { parent.makeFirstResponder(previousResponder) }
        }
        parent = nil
        previousResponder = nil
    }
}

private final class AnchoredCardMarkerView: NSView {
    var onGeometryChange: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onGeometryChange?()
    }

    override func layout() {
        super.layout()
        onGeometryChange?()
    }
}

private final class AnchoredCardPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
