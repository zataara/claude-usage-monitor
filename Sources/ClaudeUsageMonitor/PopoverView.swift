import SwiftUI
import AppKit

struct PopoverView: View {
    @Bindable var store: Store
    @Environment(\.colorScheme) private var scheme

    private var p: Palette { Palette(scheme: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let err = store.usageError {
                errorBanner(err)
            }

            // Focal: official rate-limit windows, data-driven from limits[].
            VStack(spacing: 10) {
                ForEach(store.sortedLimits) { limit in
                    LimitBar(limit: limit, palette: p)
                }
                if store.sortedLimits.isEmpty && store.usageError == nil {
                    Text("Loading usage…").font(.callout).foregroundStyle(p.subtle)
                }
            }

            if let extra = store.usage?.extraUsage, extra.isEnabled {
                Divider().overlay(p.hairline)
                OverageRow(extra: extra, spend: store.usage?.spend, palette: p)
            }

            Divider().overlay(p.hairline)
            SessionDetail(block: store.block, palette: p)

            Divider().overlay(p.hairline)
            footer
        }
        .padding(14)
        .frame(width: 320)
        .background(p.scheme == .dark ? Color(hex: 0x1F1D1A) : Color(hex: 0xFAF7F2))
        .foregroundStyle(p.text)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            if let mark = ClaudeMark.image {
                Image(nsImage: mark)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .foregroundStyle(p.clay)
            } else {
                Circle().fill(p.clay).frame(width: 9, height: 9)
            }
            Text("Claude Usage").font(.system(size: 14, weight: .bold))
            Spacer()
            Text(Fmt.agoShort(store.lastRefresh)).font(.caption2).foregroundStyle(p.subtle)
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(store.isRefreshing
                        ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                        : .default, value: store.isRefreshing)
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
        }
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(p.amber)
            Text(msg).font(.caption)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            LaunchAtLoginToggle()
            Spacer()
            Stepper("every \(store.intervalMinutes)m",
                    value: $store.intervalMinutes, in: 1...60)
                .font(.caption2)
                .fixedSize()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
    }
}

// MARK: - A single rate-limit window bar

struct LimitBar: View {
    let limit: UsageLimit
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(limit.title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(Int(limit.percent.rounded()))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            Meter(fraction: limit.percent / 100, color: palette.fill(for: limit), palette: palette)
            HStack {
                Text(Fmt.resetsIn(limit.resetsAt)).font(.caption2).foregroundStyle(palette.subtle)
                Spacer()
                if limit.group == "weekly" {
                    Text(palette.onPace(limit) ? "on pace" : "behind — use more")
                        .font(.caption2)
                        .foregroundStyle(palette.onPace(limit) ? palette.green : palette.clay)
                }
            }
        }
    }
}

/// Rounded fill bar.
struct Meter: View {
    let fraction: Double
    let color: Color
    let palette: Palette

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.track)
                Capsule().fill(color)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 8)
    }
}

// MARK: - Overage / credits

struct OverageRow: View {
    let extra: ExtraUsage
    let spend: Spend?
    let palette: Palette

    var body: some View {
        let used = spend?.used?.dollars ?? extra.usedCredits ?? 0
        let cap = spend?.limit?.dollars ?? (extra.monthlyLimit.map { $0 / 100 }) ?? 0
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Overage credits").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(Fmt.dollars(used)) / \(Fmt.dollars(cap))")
                    .font(.system(size: 11, design: .rounded)).monospacedDigit()
                    .foregroundStyle(palette.subtle)
            }
            Meter(fraction: cap > 0 ? used / cap : 0, color: palette.clay, palette: palette)
        }
    }
}

// MARK: - ccusage detail

struct SessionDetail: View {
    let block: CCUsage.Block?
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SESSION DETAIL · ccusage")
                .font(.system(size: 9, weight: .semibold)).tracking(0.5)
                .foregroundStyle(palette.subtle)

            if let b = block {
                let t = b.tokenCounts
                grid(rows: [
                    ("Burn rate", b.burnRate?.tokensPerMinute.map { "\(Fmt.compactCount($0))/min" } ?? "—"),
                    ("Cost rate", b.burnRate?.costPerHour.map { "\(Fmt.dollars($0))/hr" } ?? "—"),
                    ("Tokens in / out",
                        "\(Fmt.compactCount(t?.inputTokens ?? 0)) / \(Fmt.compactCount(t?.outputTokens ?? 0))"),
                    ("Cache read", Fmt.compactCount(t?.cacheReadInputTokens ?? 0)),
                    ("Block total", "\(Fmt.compactCount(b.totalTokens ?? 0)) · \(Fmt.dollars(b.costUSD ?? 0)) API-equiv"),
                    ("Projected", b.projection.map {
                        "\(Fmt.compactCount($0.totalTokens ?? 0)) · \(Fmt.dollars($0.totalCost ?? 0))" } ?? "—"),
                    ("Block ends", b.projection?.remainingMinutes.map { "in \(Fmt.duration($0 * 60))" }
                        ?? Fmt.resetsIn(b.endTime).replacingOccurrences(of: "resets ", with: "")),
                ])
            } else {
                Text("ccusage unavailable").font(.caption).foregroundStyle(palette.subtle)
            }
        }
    }

    private func grid(rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0).font(.caption).foregroundStyle(palette.subtle)
                    Text(row.1).font(.caption).monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Launch at login

struct LaunchAtLoginToggle: View {
    @State private var on = LoginItem.isEnabled

    var body: some View {
        Toggle(isOn: $on) { Text("Launch at login").font(.caption2) }
            .toggleStyle(.checkbox)
            .onChange(of: on) { _, newValue in LoginItem.set(newValue) }
    }
}
