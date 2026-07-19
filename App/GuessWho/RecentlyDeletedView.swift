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
///
/// A pushed destination: Phase 3 moved the entry point from the File menu
/// into the Settings sheet (a Preferences row), so this view lives inside
/// the sheet's NavigationStack rather than wrapping its own.
struct RecentlyDeletedView: View {
    let service: RecentlyDeletedService

    @State private var items: [RecentlyDeletedItem] = []
    @State private var loaded = false
    @State private var failedRestoreItemID: String?

    var body: some View {
        content
            .navigationTitle(RecentlyDeletedStrings.title)
            .task { await reload() }
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

#endif
