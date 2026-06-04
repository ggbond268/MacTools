import AppKit
import SwiftUI

/// The launcher content: a focused search field over a horizontally **paged** app grid
/// (classic Launchpad layout).
///
/// Input model (Codex P0 #2/#3): the `NSSearchField` is first responder, so typing /
/// IME composition just works while the grid stays visible ("grid-first, type to
/// search"). Arrow keys move the grid selection and Return launches — routed through
/// the field's `doCommandBySelector`, which the system does NOT call during IME
/// composition, so a candidate-selecting Return never launches an app.
///
/// Paging (LP4b): macOS SwiftUI has no `PageTabViewStyle`, so pages are laid out in a
/// single clipped `HStack` and slid by an `offset`. `selectedIndex` is the source of
/// truth; the visible page is derived from it (`selectedIndex / perPage`), so keyboard
/// navigation, page dots and drag all stay consistent.
struct LaunchpadGridView: View {
    @ObservedObject var catalog: LaunchpadAppCatalog
    /// Fixed column count, or `LaunchpadPreferences.autoColumns` (0) to fit to width.
    var columns: Int = LaunchpadPreferences.autoColumns
    /// Compact (centered panel) vs fullscreen — tightens padding and, since a small
    /// panel dismisses by clicking *outside* it (→ app resigns active), drops the
    /// inside-the-panel click-to-dismiss that fullscreen Launchpad uses.
    var isCompact: Bool = false
    /// Ids hidden from the grid (snapshot at open; the live set below seeds from it).
    var hiddenAppIDs: Set<String> = []
    var onActivate: (LaunchpadAppItem) -> Void
    var onReveal: (LaunchpadAppItem) -> Void
    var onHide: (LaunchpadAppItem) -> Void
    var onDismiss: () -> Void

    @State private var searchText = ""
    @State private var selectedIndex = 0
    @State private var currentPage = 0
    /// Hiding an app removes it from the grid immediately (live), while `onHide`
    /// persists it; seeded from `hiddenAppIDs` on appear.
    @State private var sessionHidden: Set<String> = []
    @State private var columnCount = 7
    @State private var rowCount = 5

    private let cellWidth: CGFloat = 116
    private let cellHeight: CGFloat = 124
    private let iconSide: CGFloat = 72
    private let columnSpacing: CGFloat = 8
    private let rowSpacing: CGFloat = 16

    private var filtered: [LaunchpadAppItem] {
        let visible = catalog.apps.filter { !sessionHidden.contains($0.id) }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return visible }
        // Fuzzy (subsequence) match, ranked by relevance; ties keep alphabetical order.
        var scored: [(app: LaunchpadAppItem, score: Int)] = []
        for app in visible {
            if let s = LaunchpadFuzzy.score(name: app.name, query: query) {
                scored.append((app, s))
            }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.app.name.localizedCaseInsensitiveCompare(rhs.app.name) == .orderedAscending
        }
        return scored.map(\.app)
    }

    private var perPage: Int { max(1, columnCount * rowCount) }

    private var pageCount: Int {
        max(1, Int(ceil(Double(filtered.count) / Double(perPage))))
    }

    var body: some View {
        ZStack {
            // Click-to-dismiss on empty space — the fullscreen Launchpad behaviour. Icons
            // and the search field (an AppKit NSView) hit-test first and swallow their own
            // clicks, so only genuine empty space (gaps/margins) reaches this layer. In
            // compact mode the panel itself is the content, so inside clicks must NOT
            // dismiss (outside clicks deactivate the app → close).
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { if !isCompact { onDismiss() } }

            VStack(spacing: isCompact ? 14 : 20) {
                searchBar
                content
            }
            .padding(.top, isCompact ? 24 : 60)
            .padding(.bottom, isCompact ? 20 : 32)
            .padding(.horizontal, isCompact ? 24 : 48)
        }
        .onAppear { selectedIndex = 0; currentPage = 0; sessionHidden = hiddenAppIDs }
        .onChange(of: searchText) { _, _ in selectedIndex = 0; currentPage = 0 }
        // An async `catalog.reload()` can shrink the list under a stale selection; keep the
        // source-of-truth selection valid so Return never targets a gone/off-page item (Codex P2).
        .onChange(of: catalog.apps.count) { _, _ in
            selectedIndex = min(selectedIndex, max(0, filtered.count - 1))
            currentPage = filtered.isEmpty ? 0 : selectedIndex / perPage
        }
    }

    private var searchBar: some View {
        LaunchpadSearchField(
            text: $searchText,
            onMove: handleMove,
            onLaunch: activateSelection,
            onCancel: onDismiss
        )
        .frame(width: 360, height: 28)
    }

    @ViewBuilder
    private var content: some View {
        if catalog.isLoading && catalog.apps.isEmpty {
            Spacer()
            ProgressView().controlSize(.large)
            Spacer()
        } else if filtered.isEmpty {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 42, weight: .regular))
                    .foregroundStyle(.secondary)
                Text(searchText.isEmpty ? "未找到应用" : "无匹配应用")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        } else {
            pagedGrid
        }
    }

    private var pagedGrid: some View {
        GeometryReader { geo in
            let visiblePage = min(currentPage, pageCount - 1)
            VStack(spacing: 10) {
                HStack(spacing: 0) {
                    ForEach(0..<pageCount, id: \.self) { page in
                        pageContent(page: page, columns: columnCount)
                            .frame(width: geo.size.width)
                    }
                }
                .frame(width: geo.size.width, alignment: .leading)
                .offset(x: -CGFloat(visiblePage) * geo.size.width)
                .animation(.easeInOut(duration: 0.22), value: visiblePage)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { value in
                            if value.translation.width < -40 { goToPage(visiblePage + 1) }
                            else if value.translation.width > 40 { goToPage(visiblePage - 1) }
                        }
                )

                if pageCount > 1 {
                    pageIndicator(current: visiblePage)
                }
            }
            .onAppear { updateLayout(size: geo.size) }
            .onChange(of: geo.size) { _, size in updateLayout(size: size) }
        }
    }

    /// One page's grid of cells. Items are sliced from `filtered`; the cell's selected
    /// state and launch action use the *global* index so navigation spans pages.
    private func pageContent(page: Int, columns: Int) -> some View {
        let start = page * perPage
        let end = min(start + perPage, filtered.count)
        let items = start < end ? Array(filtered[start..<end]) : []
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: columnSpacing), count: max(1, columns)),
            spacing: rowSpacing
        ) {
            ForEach(Array(items.enumerated()), id: \.element.id) { offset, app in
                let globalIndex = start + offset
                cell(for: app, isSelected: globalIndex == selectedIndex)
                    .onTapGesture {
                        selectedIndex = globalIndex
                        onActivate(app)
                    }
                    // `.onTapGesture` only handles a mouse click; without an explicit
                    // accessibility action a VoiceOver user (or any AX press) activates
                    // the `.isButton`-trait cell to no effect. Wire the same launch.
                    .accessibilityAction {
                        selectedIndex = globalIndex
                        onActivate(app)
                    }
                    .contextMenu { cellMenu(for: app) }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func cellMenu(for app: LaunchpadAppItem) -> some View {
        Button {
            onReveal(app)
        } label: {
            Label("在 Finder 中显示", systemImage: "folder")
        }
        Button {
            // Lightweight clipboard action — no lifecycle effect, so keep the launcher open.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(app.url.path, forType: .string)
        } label: {
            Label("拷贝路径", systemImage: "doc.on.doc")
        }
        Divider()
        Button {
            sessionHidden.insert(app.id)        // drop from this grid immediately
            selectedIndex = 0
            currentPage = 0
            onHide(app)                         // persist (settings page can restore)
        } label: {
            Label("隐藏", systemImage: "eye.slash")
        }
    }

    private func pageIndicator(current: Int) -> some View {
        HStack(spacing: 9) {
            ForEach(0..<pageCount, id: \.self) { page in
                Circle()
                    .fill(Color.primary.opacity(page == current ? 0.55 : 0.18))
                    .frame(width: 7, height: 7)
                    .onTapGesture { goToPage(page) }
                    // Mirror the cell fix: `.onTapGesture` is mouse-only, so VoiceOver /
                    // AX press needs an explicit action to actually change page.
                    .accessibilityAction { goToPage(page) }
                    .accessibilityLabel("第 \(page + 1) 页")
                    // Announce which dot is the current page (was visual-only — workflow QA).
                    .accessibilityAddTraits(page == current ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.top, 2)
    }

    private func cell(for app: LaunchpadAppItem, isSelected: Bool) -> some View {
        VStack(spacing: 8) {
            Image(nsImage: catalog.icon(for: app))
                .resizable()
                .interpolation(.high)
                .frame(width: iconSide, height: iconSide)
            Text(app.name)
                .font(.system(size: 12))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 30, alignment: .top)
        }
        .frame(width: cellWidth)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isSelected ? Color.primary.opacity(0.14) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Layout + navigation

    private func updateLayout(size: CGSize) {
        if columns != LaunchpadPreferences.autoColumns {
            columnCount = max(1, columns)                       // fixed count from preferences
        } else {
            let usable = max(size.width, cellWidth)
            columnCount = max(1, Int(usable / (cellWidth + columnSpacing)))
        }
        // Reserve ~26pt for the page indicator row below the grid.
        let usableHeight = max(cellHeight, size.height - 26)
        rowCount = max(1, Int((usableHeight + rowSpacing) / (cellHeight + rowSpacing)))
        // Layout (and thus perPage) changed: keep the selection valid and re-derive the
        // visible page *from it*, so the source-of-truth selection is always on screen —
        // not stranded on a now-wrong page (Codex P1).
        selectedIndex = min(max(selectedIndex, 0), max(0, filtered.count - 1))
        currentPage = filtered.isEmpty ? 0 : selectedIndex / perPage
    }

    private func handleMove(_ direction: LaunchpadSearchField.MoveDirection) {
        guard !filtered.isEmpty else { return }
        var index = selectedIndex
        switch direction {
        case .left:  index -= 1
        case .right: index += 1
        case .up:    index -= columnCount
        case .down:  index += columnCount
        }
        selectedIndex = min(max(index, 0), filtered.count - 1)
        currentPage = selectedIndex / perPage      // follow selection onto its page
    }

    private func goToPage(_ page: Int) {
        // A stale gesture/dot closure could fire after an async catalog update emptied the
        // list; avoid `filtered.count - 1 == -1` (Codex P2).
        guard !filtered.isEmpty else { selectedIndex = 0; currentPage = 0; return }
        let target = min(max(page, 0), pageCount - 1)
        currentPage = target
        // Move selection onto the page so keyboard nav resumes from what's visible.
        selectedIndex = min(target * perPage, filtered.count - 1)
    }

    private func activateSelection() {
        guard filtered.indices.contains(selectedIndex) else { return }
        onActivate(filtered[selectedIndex])
    }
}
