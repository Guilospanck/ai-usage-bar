import Foundation

/// Presentation helpers shared by the menu-bar title and the dropdown.
enum Format {

    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// A short "resets in 3h 12m" / "resets in 2d 4h" phrase.
    static func resetCountdown(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "resetting…" }
        let d = seconds / 86_400
        let h = (seconds % 86_400) / 3_600
        let m = (seconds % 3_600) / 60
        let parts: String
        if d > 0 { parts = "\(d)d \(h)h" }
        else if h > 0 { parts = "\(h)h \(m)m" }
        else { parts = "\(m)m" }
        return "resets in \(parts)"
    }

    /// A 10-cell text meter, e.g. "▰▰▰▰▱▱▱▱▱▱".
    static func bar(_ percent: Double, cells: Int = 10) -> String {
        let clamped = max(0, min(100, percent))
        let filled = Int((clamped / 100 * Double(cells)).rounded())
        return String(repeating: "▰", count: filled)
             + String(repeating: "▱", count: cells - filled)
    }

    /// Resolve the window a metric points at within one provider's snapshot.
    /// Returns nil if that provider doesn't report the requested window.
    static func window(for metric: TitleMetric, in snap: ProviderUsage) -> UsageWindow? {
        switch metric {
        case .worst:    return snap.allWindows.max(by: { $0.usedPercent < $1.usedPercent })
        case .active:   return snap.allWindows.first(where: { $0.isActive })
        case .fiveHour: return snap.fiveHour
        case .weekly:   return snap.weekly
        case .scoped(let name): return snap.scoped.first(where: { $0.label == name })?.window
        }
    }

    /// The compact menu-bar title, e.g. "C 42% · O 71%", using the chosen metric.
    /// Falls back to a provider's highest window when it lacks the selected one
    /// (e.g. OpenAI has no "Fable" cap), so every provider still shows a number.
    static func menuBarTitle(_ snapshots: [ProviderUsage], metric: TitleMetric) -> String {
        guard !snapshots.isEmpty else { return "AI …" }
        let pieces = snapshots.map { snap -> String in
            let w = window(for: metric, in: snap) ?? window(for: .worst, in: snap)
            guard let w else { return "\(snap.provider.shortSymbol) —" }
            return "\(snap.provider.shortSymbol) \(percent(w.usedPercent))"
        }
        return pieces.joined(separator: " · ")
    }
}
