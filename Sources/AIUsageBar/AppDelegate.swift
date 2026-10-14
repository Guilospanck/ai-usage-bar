import AppKit

/// Carried on each clickable usage row so its action knows both which provider
/// and which window it belongs to — the menu-bar metric is chosen per provider.
private struct RowSelection {
    let provider: ProviderKind
    let metric: TitleMetric
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let store = UsageStore(providers: [
        AnthropicProvider(), OpenAIProvider(), AntigravityProvider(),
    ])

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar agent: no dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "AI …"
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        store.onUpdate = { [weak self] in self?.render() }
        store.start()
        render()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    // MARK: - Rendering

    private func render() {
        let snapshots = store.ordered
        if let button = statusItem.button {
            button.image = nil
            button.attributedTitle =
                (store.isRefreshing && snapshots.isEmpty)
                ? NSAttributedString(
                    string: "AI …",
                    attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                    ])
                : menuBarTitle(snapshots)
        }
        statusItem.menu = buildMenu(snapshots)
    }

    /// The menu-bar title with each provider's logo drawn inline before its
    /// percentage, e.g. "[✳] 26% · [✺] 2%".
    private func menuBarTitle(_ snapshots: [ProviderUsage]) -> NSAttributedString {
        let pieces = Format.menuBarPieces(snapshots)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.labelColor,
        ]
        let result = NSMutableAttributedString()
        for (index, piece) in pieces.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "  ·  ", attributes: textAttrs))
            }
            let icon = piece.provider.iconImage(pointSize: font.pointSize)
            let attachment = NSTextAttachment()
            attachment.image = icon
            // Center the glyph vertically against the digits' cap height.
            attachment.bounds = CGRect(
                x: 0, y: (font.capHeight - icon.size.height) / 2,
                width: icon.size.width, height: icon.size.height)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: " \(piece.text)", attributes: textAttrs))
        }
        return result
    }

    private func buildMenu(_ snapshots: [ProviderUsage]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false  // we manage enabled state explicitly

        if snapshots.isEmpty {
            menu.addItem(disabledItem("Loading…"))
        } else {
            for snap in snapshots {
                addProviderSection(snap, to: menu)
                menu.addItem(.separator())
            }
        }

        let refresh = NSMenuItem(
            title: store.isRefreshing ? "Refreshing…" : "Refresh Now",
            action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = !store.isRefreshing
        menu.addItem(refresh)

        if LoginItem.isAvailable {
            let login = NSMenuItem(
                title: "Launch at Login",
                action: #selector(toggleLogin), keyEquivalent: "")
            login.target = self
            login.state = LoginItem.isEnabled ? .on : .off
            menu.addItem(login)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit AI Usage Bar",
            action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    /// This provider's windows paired with the metric that selects them.
    private func rows(for snap: ProviderUsage) -> [(
        label: String, window: UsageWindow, metric: TitleMetric
    )] {
        var rows: [(label: String, window: UsageWindow, metric: TitleMetric)] = []
        if let w = snap.fiveHour { rows.append(("Session (5h)", w, .fiveHour)) }
        if let w = snap.weekly { rows.append(("Weekly", w, .weekly)) }
        for named in snap.scoped {
            rows.append((named.label, named.window, .scoped(named.label)))
        }
        return rows
    }

    private func addProviderSection(_ snap: ProviderUsage, to menu: NSMenu) {
        var header = snap.provider.rawValue
        if let plan = snap.planName, !plan.isEmpty {
            header += "  (\(plan))"
        }
        menu.addItem(headerItem(header, provider: snap.provider))

        if let err = snap.error {
            menu.addItem(disabledItem("  ⚠ \(err)"))
        }
        if snap.autoRefreshPaused {
            menu.addItem(disabledItem("  Auto-refresh paused — Refresh Now to retry", small: true))
        }

        let sectionRows = rows(for: snap)
        if sectionRows.isEmpty {
            if snap.error == nil { menu.addItem(disabledItem("  No data")) }
            return
        }

        // Tick the row actually shown in the menu bar. When the provider is on
        // auto (.worst) or active — including on first launch — resolve that to
        // the concrete row it displays, so the current window is always marked.
        let chosen = Settings.titleMetric(for: snap.provider)
        let displayed: TitleMetric?
        if sectionRows.contains(where: { $0.metric == chosen }) {
            displayed = chosen
        } else if chosen == .active, let active = sectionRows.first(where: { $0.window.isActive }) {
            displayed = active.metric
        } else {
            displayed =
                sectionRows.max(by: { $0.window.usedPercent < $1.window.usedPercent })?.metric
        }

        for row in sectionRows {
            addWindowItem(
                row, snapshot: snap,
                selected: row.metric == displayed, to: menu)
        }
    }

    private func addWindowItem(
        _ row: (label: String, window: UsageWindow, metric: TitleMetric),
        snapshot: ProviderUsage, selected: Bool, to menu: NSMenu
    ) {
        let window = row.window
        var parts: [String] = []
        if snapshot.provider == .claude, row.metric == .fiveHour, window.resetsAt == nil {
            if let weekly = snapshot.weekly, weekly.usedPercent >= 100, weekly.isActive {
                // This is the blocking weekly reset, not an invented session reset.
                parts.append("Paused until your week resets")
                if let countdown = Format.resetCountdown(weekly.resetsAt) {
                    parts.append(countdown)
                }
            } else {
                parts.append("Session reset not reported")
            }
        } else if let countdown = Format.resetCountdown(window.resetsAt) {
            parts.append(countdown)
        }
        if let detail = window.detail { parts.append(detail) }
        let item = NSMenuItem(title: row.label, action: #selector(selectRow(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = RowSelection(provider: snapshot.provider, metric: row.metric)
        item.isEnabled = true
        item.view = QuotaMenuItemView(
            item: item, label: row.label, window: window,
            subtitle: parts.isEmpty ? nil : parts.joined(separator: " · "), selected: selected)
        menu.addItem(item)
    }

    // MARK: - Menu item factories

    private func headerItem(_ title: String, provider: ProviderKind) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        // Copy before templating: the cached menu-bar glyph must remain white.
        if let icon = provider.iconImage(pointSize: 13).copy() as? NSImage {
            icon.isTemplate = true
            item.image = icon
        }
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        item.isEnabled = false
        return item
    }

    private func disabledItem(_ title: String, monospaced: Bool = false, small: Bool = false)
        -> NSMenuItem
    {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        var attrs: [NSAttributedString.Key: Any] = [:]
        if monospaced {
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        } else if small {
            attrs[.font] = NSFont.systemFont(ofSize: 11)
            attrs[.foregroundColor] = NSColor.secondaryLabelColor
        }
        if !attrs.isEmpty {
            item.attributedTitle = NSAttributedString(string: title, attributes: attrs)
        }
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    /// Clicking a usage row pins it as that provider's menu-bar metric; clicking
    /// the pinned row again reverts that provider to auto (highest window).
    /// Selections are independent per provider.
    @objc private func selectRow(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? RowSelection else { return }
        let current = Settings.titleMetric(for: selection.provider)
        let next: TitleMetric = (current == selection.metric) ? .worst : selection.metric
        Settings.setTitleMetric(next, for: selection.provider)
        render()
    }

    @objc private func refreshNow() {
        Task { await store.refresh(manual: true) }
    }

    @objc private func toggleLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        render()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
