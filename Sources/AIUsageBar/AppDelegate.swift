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
    private let store = UsageStore(providers: [AnthropicProvider(), OpenAIProvider()])

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
            button.attributedTitle = (store.isRefreshing && snapshots.isEmpty)
                ? NSAttributedString(string: "AI …",
                                     attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)])
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
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - icon.size.height) / 2,
                                       width: icon.size.width, height: icon.size.height)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: " \(piece.text)", attributes: textAttrs))
        }
        return result
    }

    private func buildMenu(_ snapshots: [ProviderUsage]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false // we manage enabled state explicitly

        if snapshots.isEmpty {
            menu.addItem(disabledItem("Loading…"))
        } else {
            // Pad labels to a width shared across every provider so the bars and
            // percentages line up in one column throughout the whole menu.
            let labelWidth = snapshots
                .flatMap { rows(for: $0) }
                .map { $0.label.count }
                .max() ?? 0
            for snap in snapshots {
                addProviderSection(snap, labelWidth: labelWidth, to: menu)
                menu.addItem(.separator())
            }
        }

        let refresh = NSMenuItem(title: store.isRefreshing ? "Refreshing…" : "Refresh Now",
                                 action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = !store.isRefreshing
        menu.addItem(refresh)

        if LoginItem.isAvailable {
            let login = NSMenuItem(title: "Launch at Login",
                                   action: #selector(toggleLogin), keyEquivalent: "")
            login.target = self
            login.state = LoginItem.isEnabled ? .on : .off
            menu.addItem(login)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit AI Usage Bar",
                              action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    /// This provider's windows paired with the metric that selects them.
    private func rows(for snap: ProviderUsage) -> [(label: String, window: UsageWindow, metric: TitleMetric)] {
        var rows: [(label: String, window: UsageWindow, metric: TitleMetric)] = []
        if let w = snap.fiveHour { rows.append(("5-hour", w, .fiveHour)) }
        if let w = snap.weekly { rows.append(("Weekly", w, .weekly)) }
        for named in snap.scoped {
            rows.append((named.label, named.window, .scoped(named.label)))
        }
        return rows
    }

    private func addProviderSection(_ snap: ProviderUsage, labelWidth: Int, to menu: NSMenu) {
        var header = snap.provider.rawValue
        if let plan = snap.planName, !plan.isEmpty {
            header += "  (\(plan))"
        }
        menu.addItem(headerItem(header))

        if let err = snap.error {
            menu.addItem(disabledItem("  ⚠ \(err)"))
        }

        let sectionRows = rows(for: snap)
        if sectionRows.isEmpty {
            if snap.error == nil { menu.addItem(disabledItem("  No data")) }
            return
        }

        let current = Settings.titleMetric(for: snap.provider)
        for row in sectionRows {
            addWindowItem(row, provider: snap.provider, labelWidth: labelWidth,
                          selected: row.metric == current, to: menu)
        }
    }

    private func addWindowItem(_ row: (label: String, window: UsageWindow, metric: TitleMetric),
                               provider: ProviderKind, labelWidth: Int, selected: Bool, to menu: NSMenu) {
        let window = row.window
        let paddedLabel = row.label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
        let pct = String(format: "%3d%%", Int(window.usedPercent.rounded()))
        let line = "\(paddedLabel)   \(Format.bar(window.usedPercent))   \(pct)"

        // Clickable: selects this window as this provider's menu-bar metric (click
        // again to return to auto/highest). The active/binding window is orange.
        let item = NSMenuItem(title: line, action: #selector(selectRow(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = RowSelection(provider: provider, metric: row.metric)
        item.state = selected ? .on : .off
        item.isEnabled = true
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        ]
        if window.isActive { attrs[.foregroundColor] = NSColor.systemOrange }
        item.attributedTitle = NSAttributedString(string: line, attributes: attrs)
        menu.addItem(item)

        var parts: [String] = []
        if let sub = Format.resetCountdown(window.resetsAt) { parts.append(sub) }
        if let detail = window.detail { parts.append(detail) }
        if !parts.isEmpty {
            menu.addItem(disabledItem("      " + parts.joined(separator: " · "), small: true))
        }
    }

    // MARK: - Menu item factories

    private func headerItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        item.isEnabled = false
        return item
    }

    private func disabledItem(_ title: String, monospaced: Bool = false, small: Bool = false) -> NSMenuItem {
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
        Task { await store.refresh() }
    }

    @objc private func toggleLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        render()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
