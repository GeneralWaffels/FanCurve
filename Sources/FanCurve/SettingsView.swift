import SwiftUI
import SMCKit

// System Settings–style window: sidebar with tinted icon tiles, grouped forms on the right,
// Liquid Glass surfaces on macOS 26+ (falls back to materials on older systems).

struct SettingsView: View {
    @EnvironmentObject var nav: AppNav

    var body: some View {
        NavigationSplitView {
            // Only write back real changes: republishing an unchanged value makes SwiftUI re-render in a loop.
            List(selection: Binding(get: { Optional(nav.page) }, set: { if let p = $0, p != nav.page { nav.page = p } })) {
                if nav.search.isEmpty {
                    SidebarHeader().selectionDisabled()
                }
                // Grouped like System Settings: General / hardware / productivity.
                ForEach(AppNav.Page.groups, id: \.self) { group in
                    let pages = nav.filteredPages.filter { group.contains($0) }
                    if !pages.isEmpty {
                        Section {
                            ForEach(pages) { page in
                                Label { Text(page.title) } icon: { IconTile(symbol: page.symbol, tint: page.tint, size: 20) }
                                    .tag(page)
                            }
                        }
                    }
                }
            }
            .searchable(text: $nav.search, placement: .sidebar, prompt: "Search")
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 260)
        } detail: {
            Group {
                switch nav.page {
                case .general: GeneralPage()
                case .awake: KeepAwakePage()
                case .autocomplete: AutocompletePage()
                case .calendar: CalendarPage()
                case .snippets: SnippetsPage()
                case .launcher: LauncherPage()
                case .fans: FansPage()
                case .battery: BatteryPage()
                case .displays: DisplaysPage()
                case .mic: MicPage()
                case .keyboard: KeyboardPage()
                }
            }
            .frame(minWidth: 460)
            .modifier(HideToolbarTitle(title: nav.page.title))
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { nav.goBack() } label: { Image(systemName: "chevron.left") }
                        .disabled(nav.back.isEmpty).help("Back")
                    Button { nav.goForward() } label: { Image(systemName: "chevron.right") }
                        .disabled(nav.forward.isEmpty).help("Forward")
                }
            }
        }
        .frame(minWidth: 700, minHeight: 540)
    }
}

/// Like System Settings, pages carry their own header card, so the toolbar shows no duplicate title.
struct HideToolbarTitle: ViewModifier {
    let title: String
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.navigationTitle(title).toolbar(removing: .title)
        } else {
            content.navigationTitle(title)
        }
    }
}

/// Centred header card at the top of each page (large icon, title, one-line description),
/// matching the page headers in System Settings.
struct PageHeader: View {
    let page: AppNav.Page
    let description: String

    var body: some View {
        Section {
            VStack(spacing: 8) {
                IconTile(symbol: page.symbol, tint: page.tint, size: 56)
                    .padding(.bottom, 2)
                Text(page.title).font(.title2.weight(.bold))
                Text(description)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 24)
        }
    }
}

/// App identity row at the top of the sidebar, like the Apple Account row in System Settings.
struct SidebarHeader: View {
    @EnvironmentObject var model: Model

    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: "fan.fill", tint: .blue, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("FanCurve").font(.body.weight(.semibold))
                Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 6)
    }

    private var summary: String {
        let temp = model.currentTemp.map { "\(Int($0.rounded())) °C" } ?? "--"
        guard model.config.enabled else { return "\(temp) · macOS" }
        return model.status?.mode == "curve" ? "\(temp) · Curve active" : "\(temp) · Fans idle"
    }
}

/// Rounded, tinted SF Symbol tile like the ones in System Settings' sidebar.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(tint.gradient))
    }
}

/// Big number + caption, used in the glass stat strip.
struct StatTile: View {
    let title: String
    let value: String
    var symbol: String? = nil
    var tint: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).foregroundStyle(tint) }
                Text(title)
            }
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

/// Section footer text, leading-aligned like System Settings (grouped Form footers default to trailing).
struct Footer: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Inline status row: coloured dot + text.
struct StatusRow: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.leading)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Slider binding that snaps to a step without drawing tick marks (like System Settings' sliders).
func rounded(_ b: Binding<Double>, to step: Double) -> Binding<Double> {
    Binding(get: { b.wrappedValue }, set: { b.wrappedValue = ($0 / step).rounded() * step })
}

func mmss(_ seconds: Int) -> String { "\(seconds / 60):\(String(format: "%02d", seconds % 60))" }
