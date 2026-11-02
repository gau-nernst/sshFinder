import AppKit
import SwiftUI

/// What a new tab shows: a connect box with Saved and Recent hosts below it.
/// While typing, host suggestions cover the lists.
struct StartPage: View {
    @Environment(Browser.self) private var browser
    @State private var textSelection: TextSelection?
    @FocusState private var focused: Bool

    var body: some View {
        // One layout that always scrolls, with the box at a fixed height: swapping
        // between a centered and a scrolling layout rebuilt the connect box and
        // dropped its focus as soon as the dropdown made the page taller.
        GeometryReader { geo in
            ScrollView {
                content
                    .padding(.top, max(28, geo.size.height * 0.14))
                    .padding(.bottom, 48)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var content: some View {
        @Bindable var browser = browser
        let store = browser.store
        let q = browser.hostQuery.trimmingCharacters(in: .whitespaces)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                Text("Connect to a host").font(.title2.weight(.semibold))
            }
            .padding(.bottom, 20)
            TextField("Host or alias from ~/.ssh/config", text: $browser.hostQuery, selection: $textSelection)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($focused)
                .onSubmit {
                    if let pattern = browser.submitHostQuery() { fill(pattern) }
                }
                // Focus once the box is in the window; set in onAppear it was
                // ignored for a tab opened with +.
                .task {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    focused = true
                }
            // The dropdown is a layer over the lists, inside the page's own
            // bounds, so it neither pushes the page around nor misses clicks.
            ZStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 24) {
                    if !store.savedHosts.isEmpty {
                        HostSection(title: "Saved", hosts: store.savedHosts)
                    }
                    if !store.recentUnsaved.isEmpty {
                        HostSection(title: "Recent", hosts: store.recentUnsaved)
                    }
                    if store.savedHosts.isEmpty && store.recentHosts.isEmpty {
                        Text("Hosts you connect to will show up here. Click ☆ on one to keep it under Saved.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                if !q.isEmpty && !q.contains(":") {
                    dropdown(q: q, suggestions: store.suggestions(for: q))
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: 520)
    }

    private func dropdown(q: String, suggestions: [HostSuggestion]) -> some View {
        let store = browser.store
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions, id: \.self) { s in
                Button {
                    if s.isPattern {
                        fill(s.host)
                    } else {
                        browser.hostQuery = ""
                        browser.open(host: s.host)
                    }
                } label: {
                    HStack {
                        Text(s.host).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(s.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(s.isPattern ? "Fill in, then replace the *" : "Connect to \(s.host)")
                .testTarget("Suggestion \(s.host)")
            }
            if let pattern = store.matchingPattern(q) {
                hint("checkmark.circle.fill", "Matches \(pattern)", .green)
            } else if suggestions.isEmpty && !store.isKnownHost(q) {
                hint("questionmark.circle", "Not in ssh config. Return tries it anyway.", .secondary)
            }
        }
        .padding(.vertical, 4)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func hint(_ symbol: String, _ text: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
    }

    /// Put a pattern in the field with its `*` selected, ready to type over.
    private func fill(_ pattern: String) {
        browser.hostQuery = pattern
        focused = true
        if let star = pattern.firstIndex(of: "*") {
            textSelection = TextSelection(range: star..<pattern.index(after: star))
        }
    }
}

struct HostSection: View {
    let title: String
    let hosts: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(hosts.enumerated()), id: \.element) { i, h in
                    if i > 0 { Divider().padding(.leading, 36) }
                    HostRow(host: h)
                }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        }
    }
}

/// Click to connect; the star saves or unsaves. Saved hosts always show a
/// filled star, recent ones show an empty star on hover.
struct HostRow: View {
    @Environment(Browser.self) private var browser
    let host: String
    @State private var hovering = false

    var body: some View {
        let store = browser.store
        let saved = store.savedHosts.contains(host)
        Button { browser.open(host: host) } label: {
            HStack(spacing: 10) {
                Image(systemName: "server.rack").foregroundStyle(.secondary).frame(width: 18)
                Text(host).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 36)  // room for the star on top
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(hovering ? Color.primary.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Connect to \(host)")
        .accessibilityLabel("Connect to \(host)")
        .testTarget("Connect to \(host)")
        .overlay(alignment: .trailing) {
            Button { store.toggleSaved(host) } label: {
                Image(systemName: saved ? "star.fill" : "star")
                    .foregroundStyle(saved ? Color.yellow : Color.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(saved || hovering ? 1 : 0)
            .help(saved ? "Remove from Saved" : "Save")
            .accessibilityLabel(saved ? "Remove \(host) from Saved" : "Save \(host)")
            .testTarget("Star \(host)")
            .padding(.trailing, 8)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button(saved ? "Remove from Saved" : "Save") { store.toggleSaved(host) }
        }
    }
}
