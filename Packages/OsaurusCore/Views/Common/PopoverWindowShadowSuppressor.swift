//
//  PopoverWindowShadowSuppressor.swift
//  Osaurus
//

import AppKit
import SwiftUI

/// Opt one native popover out of AppKit's shadow rim. Its SwiftUI content
/// supplies the themed outline and shadow; other popovers keep their chrome.
struct PopoverWindowShadowSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> ShadowSuppressingView {
        ShadowSuppressingView()
    }

    func updateNSView(_ view: ShadowSuppressingView, context: Context) {
        view.suppressShadow()
    }

    static func dismantleNSView(_ view: ShadowSuppressingView, coordinator: ()) {
        view.restoreShadow()
    }

    final class ShadowSuppressingView: NSView {
        private weak var styledWindow: NSWindow?
        private var originalHasShadow = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            suppressShadow()
        }

        func suppressShadow() {
            guard window !== styledWindow else { return }
            restoreShadow()
            guard let window else { return }
            styledWindow = window
            originalHasShadow = window.hasShadow
            window.hasShadow = false
        }

        func restoreShadow() {
            styledWindow?.hasShadow = originalHasShadow
            styledWindow = nil
        }
    }
}
