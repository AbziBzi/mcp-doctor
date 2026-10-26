import MCPDoctorCore
import SwiftUI

/// One harness: its problems, then a summary row that expands to everything else.
struct HarnessSection: View {
    let snapshot: HarnessSnapshot
    let model: AppModel
    let state: PanelState
    let now: Date

    private var harness: Harness { snapshot.harness }
    private var isExpanded: Bool { state.expanded.contains(harness) }

    var body: some View {
        let groups = model.groups(for: snapshot)
        let showsSummary = groups.attention.isEmpty || !groups.others.isEmpty || !groups.dormant.isEmpty

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(harness.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(checkedCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            if let error = snapshot.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .padding(.horizontal, 4)
            }

            VStack(spacing: 0) {
                ForEach(Array(groups.attention.enumerated()), id: \.element.id) { index, server in
                    if index > 0 { RowDivider() }
                    ServerRow(server: server, model: model)
                }
                if showsSummary {
                    if !groups.attention.isEmpty { RowDivider() }
                    summaryRow(groups)
                }
                if isExpanded {
                    ForEach(groups.others) { server in
                        RowDivider()
                        ServerRow(server: server, model: model)
                    }
                }
            }
            .background(CardBackground())

            if isExpanded, !groups.dormant.isEmpty {
                DisclosureGroup(isExpanded: showDormant) {
                    ServerList(servers: groups.dormant, model: model)
                        .padding(.top, 4)
                } label: {
                    Text("\(counted(groups.dormant.count, "claude.ai connector")) never connected on this Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func summaryRow(_ groups: ServerGroups) -> some View {
        let canExpand = !groups.others.isEmpty || !groups.dormant.isEmpty
        return Button {
            guard canExpand else { return }
            withAnimation(.snappy) {
                if isExpanded { state.expanded.remove(harness) } else { state.expanded.insert(harness) }
            }
        } label: {
            HStack(spacing: 10) {
                summaryIndicator(groups)
                    .frame(width: 8, height: 8)
                Text(summaryText(groups))
                    .font(.callout)
                    .foregroundStyle(groups.attention.isEmpty ? .primary : .secondary)
                Spacer()
                if canExpand {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(canExpand ? (isExpanded ? "Hide servers" : "Show servers") : "")
    }

    /// Before the first check finishes, servers come from config files only and say nothing yet.
    private func awaitingFirstCheck(_ groups: ServerGroups) -> Bool {
        snapshot.installed && snapshot.checkedAt == nil && groups.others.allSatisfy { $0.status == .unknown }
    }

    @ViewBuilder private func summaryIndicator(_ groups: ServerGroups) -> some View {
        if awaitingFirstCheck(groups) {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
        } else {
            Circle().fill(groups.others.contains { $0.status == .ok } ? Color.green : Color.gray)
        }
    }

    private func summaryText(_ groups: ServerGroups) -> String {
        if !snapshot.installed { return "\(harness.executableName) isn't installed" }
        if awaitingFirstCheck(groups) { return "Checking…" }
        if snapshot.servers.isEmpty { return "No MCP servers configured" }

        let connected = groups.others.filter { $0.status == .ok }.count
        var parts: [String] = []
        if groups.attention.isEmpty {
            if connected == 0 {
                parts.append("No servers connected yet")
            } else if connected == groups.others.count {
                parts.append(connected == 1 ? "1 server connected" : "All \(connected) servers connected")
            } else {
                parts.append("\(connected) connected")
            }
        } else if connected > 0 {
            parts.append("\(connected) more connected")
        }
        let muted = groups.others.filter { $0.status.isProblem }.count
        let disabled = groups.others.filter { $0.status == .disabled }.count
        let unchecked = groups.others.filter { $0.status == .unknown }.count
        if muted > 0 { parts.append("\(muted) muted") }
        if disabled > 0 { parts.append("\(disabled) disabled") }
        if unchecked > 0 { parts.append("\(unchecked) not checked") }
        if parts.isEmpty, !groups.dormant.isEmpty {
            parts.append("\(counted(groups.dormant.count, "connector")) not connected")
        }
        return parts.joined(separator: " · ")
    }

    private var checkedCaption: String {
        if model.checking.contains(harness) { return "checking…" }
        return snapshot.checkedAt.map { "checked \($0.relativeDescription(from: now))" } ?? ""
    }

    private var showDormant: Binding<Bool> {
        Binding(
            get: { state.expandedDormant.contains(harness) },
            set: { expanded in
                if expanded { state.expandedDormant.insert(harness) } else { state.expandedDormant.remove(harness) }
            }
        )
    }
}

struct ServerList: View {
    let servers: [MCPServer]
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                if index > 0 { RowDivider() }
                ServerRow(server: server, model: model)
            }
        }
        .background(CardBackground())
    }
}

struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 28)
    }
}

struct CardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.05))
    }
}
