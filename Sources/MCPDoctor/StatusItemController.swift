import AppKit
import MCPDoctorCore
import Observation
import SwiftUI

/// The menu bar icon and its popover. The popover's SwiftUI content is created on open and
/// released on close, so a closed panel costs nothing.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: AppModel
    private let scheduler: Scheduler
    private var badgeUpdates: Task<Void, Never>?

    init(model: AppModel, scheduler: Scheduler) {
        self.model = model
        self.scheduler = scheduler
        super.init()
        popover.delegate = self
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.imagePosition = .imageLeading
        badgeUpdates = Task { [weak self, model] in
            for await count in Observations({ model.attentionCount }) {
                self?.showBadge(count)
            }
        }
    }

    private func showBadge(_ count: Int) {
        guard let button = statusItem.button else { return }
        let description = count == 0 ? "MCP Doctor" : "MCP Doctor: \(count) need attention"
        let image = NSImage(systemSymbolName: "stethoscope", accessibilityDescription: description)
        if count == 0 {
            image?.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            let tinted = image?.withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
            tinted?.isTemplate = false
            button.image = tinted
            button.title = " \(count)"
        }
        button.toolTip = description
    }

    @objc private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    /// `pinned` keeps the panel open when clicking elsewhere, for screenshots and debugging.
    func showPanel(pinned: Bool = false, expanded: Bool = false) {
        guard let button = statusItem.button else { return }
        let state = PanelState()
        if expanded { state.expanded = Set(Harness.allCases) }
        let panel = PanelView(model: model, scheduler: scheduler, state: state, loginItem: LoginItem())
        let host = NSHostingController(rootView: panel)
        host.sizingOptions = [.preferredContentSize]
        popover.behavior = pinned ? .applicationDefined : .transient
        popover.contentViewController = host
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate()
        scheduler.panelOpened()
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }
}
