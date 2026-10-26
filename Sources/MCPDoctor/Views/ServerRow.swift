import MCPDoctorCore
import SwiftUI

struct ServerRow: View {
    let server: MCPServer
    let model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(server.status.color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(server.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if let origin = server.origin {
                        Text(origin)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    if model.isMuted(server) {
                        Image(systemName: "bell.slash")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .help(server.detail ?? server.status.label)
            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .contextMenu { menu }
    }

    private var signIn: SignInState? { model.signIns[server.id] }

    /// Healthy servers get a single line.
    private var subtitle: String? {
        switch signIn {
        case .running: return "Waiting for you to finish in the browser…"
        case .failed(let message): return "Sign-in failed: \(message)"
        case nil: break
        }
        if case .expiringSoon(let date) = server.status {
            return "Token expires \(date.formatted(.relative(presentation: .named))) and can't be refreshed"
        }
        return server.detail ?? (server.status == .ok ? nil : server.status.label)
    }

    @ViewBuilder private var trailing: some View {
        switch signIn {
        case .running(let link):
            HStack(spacing: 6) {
                if let link {
                    Button("Open link") { NSWorkspace.shared.open(link) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
                ProgressView()
                    .controlSize(.small)
                Button {
                    model.cancelSignIn(server)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Cancel sign-in")
            }
        case .failed:
            Button("Use Terminal") { model.signInInTerminal(server) }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Run the sign-in command in Terminal")
        case nil:
            if server.canSignIn, server.status.isProblem {
                Button("Sign in") { model.signIn(server) }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder private var menu: some View {
        if server.canSignIn {
            Button("Sign In") { model.signIn(server) }
            Button("Sign In Using Terminal") { model.signInInTerminal(server) }
            Button("Copy Sign-In Command") { model.copySignInCommand(server) }
            Divider()
        }
        if case .failed = signIn {
            Button("Dismiss Error") { model.dismissSignInError(server) }
        }
        Button(model.isMuted(server) ? "Unmute" : "Mute") { model.toggleMute(server) }
        if let target = server.target {
            Button(server.transport == .stdio ? "Copy Command" : "Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(target, forType: .string)
            }
        }
    }
}

extension ServerStatus {
    var color: Color {
        switch self {
        case .ok: .green
        case .needsAuth: .orange
        case .expiringSoon: .yellow
        case .failed: .red
        case .unknown: .gray
        case .disabled: .gray.opacity(0.5)
        }
    }
}
