#if targetEnvironment(macCatalyst)

import SwiftUI
import UIKit
import GuessWhoMCPCore
import GuessWhoMCPWire

/// The user-reachable "Recently Deleted" screen (plans/cli-mcp.md Phase 2 —
/// the prerequisite for enabling agent writes): items an assistant deleted,
/// each restorable in one tap. Plain-language copy only; the strings live in
/// `RecentlyDeletedStrings` under the banned-vocabulary test.
///
/// Catalyst-only, like the channel itself (INV-5): the backing activity log
/// is device-local, and only the Mac host records agent writes.
struct RecentlyDeletedView: View {
    let service: RecentlyDeletedService

    @State private var items: [RecentlyDeletedItem] = []
    @State private var loaded = false
    @State private var failedRestoreItemID: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(RecentlyDeletedStrings.title)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .task { await reload() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !loaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            Text(RecentlyDeletedStrings.emptyMessage)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(items) { item in
                row(for: item)
            }
        }
    }

    private func row(for item: RecentlyDeletedItem) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(item.deletedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if !item.canRestore {
                    Text(RecentlyDeletedStrings.restoreBlocked)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if failedRestoreItemID == item.id {
                    Text(RecentlyDeletedStrings.restoreFailed)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            Button(RecentlyDeletedStrings.restoreButton) {
                Task { await restore(item) }
            }
            .disabled(!item.canRestore)
        }
        .padding(.vertical, 2)
    }

    private func reload() async {
        items = await service.items()
        loaded = true
    }

    private func restore(_ item: RecentlyDeletedItem) async {
        if await service.restore(item) {
            failedRestoreItemID = nil
            await reload()
        } else {
            failedRestoreItemID = item.id
        }
    }
}

/// Self-presenting entry point for the File-menu command — same pattern as
/// `DebugMenuActions`: resolve the frontmost view controller directly so
/// presentation never depends on responder-chain focus.
@MainActor
enum RecentlyDeletedPresenter {
    static func present(service: RecentlyDeletedService) {
        guard let presenter = topViewController() else { return }
        let host = UIHostingController(rootView: RecentlyDeletedView(service: service))
        host.modalPresentationStyle = .formSheet
        presenter.present(host, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        guard let root = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? scene?.windows.first?.rootViewController else { return nil }

        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}

#endif
