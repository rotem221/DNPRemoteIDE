import SwiftUI

/// Displays the **selected** session's terminal. Other sessions keep running in the background
/// (their `TerminalSession` is held by `vm.terminalSessions[id]`). Switching sessions just swaps
/// the visible NSView; nothing is killed.
struct TerminalPaneView: View {
    @EnvironmentObject var vm: MacAppViewModel
    @EnvironmentObject var workspace: WorkspaceController

    var body: some View {
        Group {
            if let id = workspace.selectedSessionId, let session = vm.terminalSessions[id] {
                TerminalEmulatorView(session: session)
                    .id(id)   // recreate the embed when the active session id changes
                    // Breathing room so the terminal text doesn't sit flush against the
                    // sidebar boundary or the toolbar/status bar above-and-below. The
                    // dark background extends edge-to-edge (so it still looks like a
                    // single integrated terminal pane); only the character grid is inset.
                    .padding(.leading, 18)
                    .padding(.trailing, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 10)
            } else {
                emptyState
            }
        }
        // Match the app theme — same tone as Settings / Diagnostics, NOT a hardcoded
        // near-black. Keeps the terminal pane consistent with the rest of the IDE.
        .background(MacTheme.groupedBackground)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(MacTheme.textTertiary)
            Text("No active session").font(.title3.bold()).foregroundStyle(MacTheme.textPrimary)
            Text("Create a new session — each one gets its own terminal and Claude context.")
                .font(.callout).foregroundStyle(MacTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                Task { await vm.newSession(in: workspace) }
            } label: {
                Label("New Session", systemImage: "plus")
                    .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent).tint(MacTheme.accent).controlSize(.large)
            .keyboardShortcut("n", modifiers: [.command])

            if let project = workspace.projectRootName {
                Text("Working directory: \(project)")
                    .font(.caption.monospaced()).foregroundStyle(MacTheme.textTertiary)
            } else {
                Text("Tip: open a project folder first (Files → Open Folder…)")
                    .font(.caption).foregroundStyle(MacTheme.textTertiary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
