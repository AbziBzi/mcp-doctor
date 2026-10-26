import MCPDoctorCore
import SwiftUI

/// View state for one opening of the panel. Kept in an observable object rather than `@State`
/// because the `@State` macro's compiler plugin ships with Xcode, not the Command Line Tools.
@MainActor
@Observable
final class PanelState {
    var expanded: Set<Harness> = []
    var expandedDormant: Set<Harness> = []
    var contentHeight: CGFloat = 0
    var edges = ScrollEdges(moreAbove: false, moreBelow: false)
}

/// Whether there is content scrolled out of view above or below.
struct ScrollEdges: Equatable {
    var moreAbove: Bool
    var moreBelow: Bool
}

struct PanelView: View {
    /// Taller lists scroll.
    private static let maxListHeight: CGFloat = 480
    /// How often relative times such as "checked 2 min. ago" are redrawn.
    private static let clockInterval: TimeInterval = 30

    let model: AppModel
    let scheduler: Scheduler
    let state: PanelState
    let loginItem: LoginItem

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.clockInterval)) { context in
            VStack(spacing: 0) {
                header(now: context.date)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                serverList(now: context.date)
                footer
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
        .frame(width: 380)
    }

    private func header(now: Date) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MCP Doctor")
                    .font(.headline)
                Text(summary(now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                scheduler.checkAllNow()
            } label: {
                Group {
                    if model.checking.isEmpty {
                        Image(systemName: "arrow.clockwise")
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: 16, height: 16)
            }
            .buttonStyle(.glass)
            .disabled(!model.checking.isEmpty || !model.isOnline)
            .help("Check all servers now")
        }
    }

    private func summary(now: Date) -> String {
        if !model.isOnline { return "Offline · checks paused" }
        var parts: [String] = []
        switch model.attentionCount {
        case 0: parts.append(model.lastChecked == nil ? "Checking…" : "All good")
        case 1: parts.append("1 server needs attention")
        case let count: parts.append("\(count) servers need attention")
        }
        if let checking = model.checking.first {
            parts.append("checking \(checking.displayName)…")
        } else if let lastChecked = model.lastChecked {
            parts.append("checked \(lastChecked.relativeDescription(from: now))")
        }
        return parts.joined(separator: " · ")
    }

    /// Every harness is always listed, in a fixed order, so an empty panel never leaves you
    /// wondering whether a harness was checked at all.
    private func serverList(now: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(model.snapshots) { snapshot in
                    HarnessSection(snapshot: snapshot, model: model, state: state, now: now)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { state.contentHeight = $0 }
        }
        .frame(height: min(max(state.contentHeight, 1), Self.maxListHeight))
        .scrollBounceBehavior(.basedOnSize)
        // A visible scroller takes width from the content when it appears, which shifts every
        // row, and the expand button, sideways. Fading the edges hints at more content instead.
        .scrollIndicators(.never)
        .onScrollGeometryChange(for: ScrollEdges.self) { geometry in
            ScrollEdges(
                moreAbove: geometry.contentOffset.y > 1,
                moreBelow: geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 1
            )
        } action: { _, edges in
            state.edges = edges
        }
        .mask { EdgeFade(edges: state.edges) }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("Open at login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            if let problem = loginItem.problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// A mask that fades the list's edges where content continues out of view.
private struct EdgeFade: View {
    let edges: ScrollEdges

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: edges.moreAbove ? 16 : 0)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: edges.moreBelow ? 24 : 0)
        }
        .animation(.easeOut(duration: 0.15), value: edges)
    }
}
