import AppKit
import SwiftUI

/// Tabs in the title row, after the window buttons, with + right after the
/// last tab. The empty part of the row drags the window.
struct TabStrip: View {
    @Environment(Tabs.self) private var tabs

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs.browsers) { b in
                TabItem(browser: b)
            }
            BarButton(symbol: "plus", help: "New tab") { tabs.newTab() }
            Spacer(minLength: 0)
        }
        .padding(.leading, 80)
        .padding(.trailing, 10)
        // Tabs centered on the window buttons, which sit 16 pt from the top.
        .frame(height: 28)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .background {
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
        }
    }
}

struct TabItem: View {
    @Environment(Tabs.self) private var tabs
    let browser: Browser
    @State private var hovering = false

    var body: some View {
        let selected = tabs.selectedID == browser.id
        let title = browser.host ?? "New Tab"
        // A Button, not a tap gesture: buttons take the first click into an
        // inactive window, so one click on a tab switches to it.
        Button { tabs.selectedID = browser.id } label: {
            HStack(spacing: 6) {
                Group {
                    if browser.loading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: browser.host == nil ? "house" : "server.rack")
                            .font(.system(size: 11))
                    }
                }
                .frame(width: 14)
                .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .padding(.trailing, 28)  // room for the close button on top
            .frame(minWidth: 100, maxWidth: 220, minHeight: 28, maxHeight: 28)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color(nsColor: .controlBackgroundColor)
                          : hovering ? Color.primary.opacity(0.06) : Color.clear)
                    .shadow(color: .black.opacity(selected ? 0.15 : 0), radius: 0.5, y: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tab \(title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .testTarget("Tab \(title)")
        .overlay(alignment: .trailing) {
            Button { tabs.close(browser) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering || selected ? 1 : 0)
            .help("Close tab")
            .accessibilityLabel("Close tab \(title)")
            .testTarget("Close tab \(title)")
            .padding(.trailing, 8)
        }
        .onHover { hovering = $0 }
        .help(browser.host.map { "\($0):\(browser.cwd)" } ?? "New tab")
        .contextMenu {
            Button("Close Tab") { tabs.close(browser) }
            Button("Close Other Tabs") { tabs.closeOthers(browser) }
                .disabled(tabs.browsers.count == 1)
        }
    }
}

/// Icon button with a hover highlight, optionally with a text label.
struct BarButton: View {
    let symbol: String
    var title: String?
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                if let title { Text(title).font(.system(size: 12)) }
            }
            .padding(.horizontal, title == nil ? 0 : 8)
            .frame(minWidth: 28, minHeight: 26)
            .background(hovering && enabled ? Color.primary.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.5))
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(title ?? help)
        .testTarget(help)
    }
}
