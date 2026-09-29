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
        rightToLeft: Bool = false
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
        let placeAbove = above >= desiredHeight || (below < desiredHeight && above >= below)
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

private struct AnchoredCardAnchor<Card: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let size: CGSize
    let accessibilityLabel: String
    let content: Card

    @Environment(\.self) private var environment

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
        coordinator.rightToLeft = environment.layoutDirection == .rightToLeft
        coordinator.content = AnyView(content.environment(\.self, environment))
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
    var content = AnyView(EmptyView())

    private weak var parent: NSWindow?
    private weak var previousResponder: NSResponder?
    private var panel: AnchoredCardPanel?
    private var host: NSHostingView<AnyView>?
    private var observers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var updateScheduled = false
    private var presentedFrame = NSRect.zero

    // NSViewRepresentable updates and layout callbacks may occur during a
    // SwiftUI render. Defer panel mutations and binding writes one turn.
    func scheduleUpdate() {
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
        let frame = presentationFrame(anchor: anchor, window: window)
        if panel == nil {
            present(in: window, frame: frame)
        }
        guard let panel, let host else { return }
        panel.setAccessibilityLabel(accessibilityLabel)
        panel.title = accessibilityLabel
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        host.rootView = AnyView(
            content
                .frame(width: frame.width, height: frame.height)
                .transaction { if reduceMotion { $0.animation = nil } }
        )
        if presentedFrame != frame {
            let changesSize = presentedFrame.size != frame.size
            presentedFrame = frame
            if changesSize && !reduceMotion {
                // The content takes its final layout while the native
                // window reveals the added column. Keep position-only
                // updates immediate so dragging a chat never trails it.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(frame, display: true)
                }
            } else {
                panel.setFrame(frame, display: true)
            }
        }
    }

    private func presentationFrame(anchor: NSView, window: NSWindow) -> NSRect {
        let anchorFrame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        // Prefer the display containing the actual control, including when
        // its parent straddles displays with different coordinate origins.
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchorFrame.midX, y: anchorFrame.midY)) }
            ?? window.screen
            ?? NSScreen.main
        return AnchoredCardPlacement.frame(
            anchor: anchorFrame,
            size: requestedSize,
            visibleFrame: screen?.visibleFrame ?? window.frame,
            rightToLeft: rightToLeft
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
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = parent.level
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.onCancel = { [weak self] in self?.dismiss(restoreFocus: true) }

        let host = NSHostingView(rootView: AnyView(
            content
                .frame(width: frame.width, height: frame.height)
                .transaction { $0.animation = nil }
        ))
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
                MainActor.assumeIsolated { self?.scheduleUpdate() }
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
