import SwiftUI

enum MenuRoute: Hashable {
    case history
    case settings
}

/// The menu that slides over the page: address field, page actions, bookmarks, and the way into
/// History and Settings. Everything here uses the normal tvOS focus system.
@MainActor
struct MenuView: View {
    let browser: BrowserViewController
    @ObservedObject var model: BrowserModel
    @ObservedObject private var preferences = Preferences.shared
    @ObservedObject private var library = Library.shared

    @State private var address = ""
    @State private var path: [MenuRoute] = []
    @Namespace private var focusScope

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 28), count: 4)

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 44) {
                    header
                    addressField
                    actions
                    bookmarks
                    remoteHelp
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 60)
                .focusScope(focusScope)
            }
            .navigationDestination(for: MenuRoute.self) { route in
                switch route {
                case .history: HistoryView(browser: browser)
                case .settings: SettingsView(browser: browser)
                }
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.title.isEmpty ? "Clearbrowse" : model.title)
                .font(.title3)
                .fontWeight(.semibold)
                .lineLimit(1)
            if let url = model.url, isWebAddress(url) {
                Text(url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Type an address or a search, or pick a bookmark.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var addressField: some View {
        TextField("Search or enter address", text: $address)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit {
                let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                browser.closeMenu { browser.open(text: text) }
            }
    }

    private var actions: some View {
        LazyVGrid(columns: columns, spacing: 28) {
            if model.hasVideo {
                // Starts focused, so full screen is Play/Pause and then one click.
                MenuButton(title: "Full Screen Video", systemImage: "arrow.up.left.and.arrow.down.right") {
                    browser.closeMenu { browser.enterTheater() }
                }
                .prefersDefaultFocus(true, in: focusScope)
            }
            if model.playerURL != nil {
                MenuButton(title: "Open in Apple TV Player", systemImage: "play.rectangle") {
                    browser.closeMenu { browser.openInPlayer() }
                }
            }
            if model.blockedPopup != nil {
                MenuButton(title: "Open Blocked Pop-up", systemImage: "rectangle.on.rectangle") {
                    browser.closeMenu { browser.openBlockedPopup() }
                }
            }
            MenuButton(title: "Back", systemImage: "chevron.backward", isEnabled: model.canGoBack) {
                browser.closeMenu { browser.goBack() }
            }
            MenuButton(title: "Forward", systemImage: "chevron.forward", isEnabled: model.canGoForward) {
                browser.closeMenu { browser.goForward() }
            }
            MenuButton(
                title: model.isLoading ? "Stop" : "Reload",
                systemImage: model.isLoading ? "xmark" : "arrow.clockwise",
                isEnabled: model.url != nil
            ) {
                browser.closeMenu { browser.reloadOrStop() }
            }
            MenuButton(
                title: library.isBookmarked(model.url) ? "Remove Bookmark" : "Add Bookmark",
                systemImage: library.isBookmarked(model.url) ? "star.fill" : "star",
                isEnabled: model.url.map { isWebAddress($0) } ?? false
            ) {
                browser.toggleBookmark()
            }
            MenuButton(title: "Zoom Out", systemImage: "minus.magnifyingglass", isEnabled: preferences.zoomPercent > (Preferences.zoomSteps.first ?? 0)) {
                if preferences.stepZoom(by: -1) { browser.applyZoom() }
            }
            MenuButton(title: "Zoom In (\(preferences.zoomPercent)%)", systemImage: "plus.magnifyingglass", isEnabled: preferences.zoomPercent < (Preferences.zoomSteps.last ?? 0)) {
                if preferences.stepZoom(by: 1) { browser.applyZoom() }
            }
            MenuButton(title: "History", systemImage: "clock") {
                path.append(.history)
            }
            MenuButton(title: "Settings", systemImage: "gearshape") {
                path.append(.settings)
            }
        }
    }

    private var bookmarks: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Bookmarks")
                .font(.headline)
            if library.bookmarks.isEmpty {
                Text("Open a page, then choose Add Bookmark to keep it here.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, spacing: 28) {
                    ForEach(library.bookmarks) { bookmark in
                        Button {
                            open(bookmark.url)
                        } label: {
                            SiteLabel(title: bookmark.title, detail: bookmark.host)
                        }
                        .contextMenu {
                            Button("Remove Bookmark", role: .destructive) {
                                library.removeBookmark(bookmark)
                            }
                        }
                    }
                }
            }
        }
    }

    private var remoteHelp: some View {
        Text("Remote: swipe to move the cursor, click to select, arrow buttons to scroll. Play/Pause opens this menu and Back closes it.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: Helpers

    private func isWebAddress(_ url: URL) -> Bool {
        url.scheme?.lowercased().hasPrefix("http") == true
    }

    private func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        browser.closeMenu { browser.load(url) }
    }
}

/// One of the menu's action buttons.
struct MenuButton: View {
    let title: String
    let systemImage: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
        }
        .disabled(!isEnabled)
    }
}

/// A page title with a smaller line under it.
struct SiteLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .lineLimit(1)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - History

@MainActor
struct HistoryView: View {
    let browser: BrowserViewController
    @ObservedObject private var library = Library.shared
    @State private var confirmClear = false

    var body: some View {
        List {
            if library.history.isEmpty {
                Text("Pages you visit will appear here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(library.history) { item in
                    Button {
                        guard let url = URL(string: item.url) else { return }
                        browser.closeMenu { browser.load(url) }
                    } label: {
                        SiteLabel(
                            title: item.title,
                            detail: item.host + " · " + item.date.formatted(.relative(presentation: .named))
                        )
                    }
                    .contextMenu {
                        Button("Remove from History", role: .destructive) {
                            library.removeHistory(item)
                        }
                    }
                }
                Button("Clear History", role: .destructive) {
                    confirmClear = true
                }
            }
        }
        .navigationTitle("History")
        .confirmationDialog("Clear all history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { library.clearHistory() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Settings

@MainActor
struct SettingsView: View {
    let browser: BrowserViewController
    @ObservedObject private var preferences = Preferences.shared
    @State private var confirmClear = false

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                Picker("Show sites as", selection: $preferences.siteMode) {
                    ForEach(SiteMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("Page zoom", selection: $preferences.zoomPercent) {
                    ForEach(Preferences.zoomSteps, id: \.self) { step in
                        Text("\(step)%").tag(step)
                    }
                }
                Picker("Search with", selection: $preferences.searchEngine) {
                    ForEach(SearchEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
            } header: {
                Text("Pages")
            } footer: {
                Text("Desktop gives the fullest version of most sites. If a site misbehaves or its video won't start, try Tablet or Phone. Changing this reloads the page.")
            }

            Section {
                Picker("Cursor speed", selection: $preferences.cursorSpeed) {
                    ForEach(Preferences.cursorSpeeds) { speed in
                        Text(speed.title).tag(speed.value)
                    }
                }
            } header: {
                Text("Remote")
            } footer: {
                Text("Swipe to move the cursor; push against an edge to scroll. Click to select. The arrow buttons scroll. Play/Pause opens the menu. Back goes back a page. In full-screen video, Play/Pause pauses, left and right skip 10 seconds, and Back leaves full screen.")
            }

            Section {
                Toggle("Block pop-up windows", isOn: $preferences.blockPopups)
                Toggle("Reopen the last page at launch", isOn: $preferences.reopenLastPage)
            } header: {
                Text("Behavior")
            }

            Section {
                Button("Clear Cookies and Website Data", role: .destructive) {
                    confirmClear = true
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Signs you out of every site. Bookmarks and history are kept.")
            }

            Section("About") {
                LabeledContent("Version", value: version)
                LabeledContent("tvOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            }
        }
        .navigationTitle("Settings")
        .onChange(of: preferences.siteMode) {
            browser.applySiteMode()
        }
        .onChange(of: preferences.zoomPercent) {
            browser.applyZoom()
        }
        .confirmationDialog("Clear cookies and website data?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { browser.clearWebsiteData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll be signed out of every site.")
        }
    }
}
