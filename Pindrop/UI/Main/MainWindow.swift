//
//  MainWindow.swift
//  Pindrop
//
//  Main application window with sidebar navigation
//

import SwiftUI
import Observation
import SwiftData
import AppKit
import PindropCore
import PindropData
import PindropSpeech

// MARK: - Navigation

enum MainNavGroup: String, CaseIterable, Identifiable, Sendable {
    case capture
    case workspace
    case tools

    var id: String { rawValue }

    func title(locale: Locale) -> String {
        switch self {
        case .capture:
            localized("Capture", locale: locale)
        case .workspace:
            localized("Workspace", locale: locale)
        case .tools:
            localized("Tools", locale: locale)
        }
    }
}

enum MainNavItem: String, CaseIterable, Identifiable, Sendable {
    case dictate = "dictate"
    case notes = "notes"
    case library = "library"
    case stats = "stats"
    case dictionary = "dictionary"
    case models = "models"

    /// Raw values retired when Voice Note and Meeting merged into Notes. Older
    /// persisted selections, View-menu round-trips, MCP calls, and deep links can
    /// still carry them, so every entry point resolves through `resolve(rawValue:)`.
    static let legacyRawValueAliases: [String: MainNavItem] = [
        "voice-note": .notes,
        "meeting": .notes
    ]

    /// The single resolution point for externally supplied raw values.
    /// Use this instead of `MainNavItem(rawValue:)` everywhere.
    static func resolve(rawValue: String) -> MainNavItem? {
        MainNavItem(rawValue: rawValue) ?? legacyRawValueAliases[rawValue]
    }

    static let sidebarGroups: [(group: MainNavGroup, items: [MainNavItem])] = [
        (.capture, [.dictate, .notes]),
        (.workspace, [.library, .stats]),
        (.tools, [.dictionary, .models])
    ]
    static let allSidebarItems = sidebarGroups.flatMap { $0.items }

    static func viewMenuShortcut(for item: MainNavItem) -> String {
        guard let index = allSidebarItems.firstIndex(of: item) else {
            preconditionFailure("Every main navigation item must have a View-menu shortcut.")
        }
        return String(index + 1)
    }

    var id: String { rawValue }
    var accessibilityIdentifierComponent: String { rawValue }

    func title(locale: Locale) -> String {
        switch self {
        case .dictate:
            localized("Dictate", locale: locale)
        case .notes:
            localized("Notes", locale: locale)
        case .library:
            localized("Library", locale: locale)
        case .stats:
            localized("Stats", locale: locale)
        case .dictionary:
            localized("Dictionary", locale: locale)
        case .models:
            localized("Models", locale: locale)
        }
    }

    var icon: String {
        switch self {
        case .dictate: "waveform"
        case .notes: "note.text"
        case .library: "books.vertical"
        case .stats: "chart.xyaxis.line"
        case .dictionary: "text.book.closed"
        case .models: "cpu"
        }
    }
}

/// Sub-route inside the Notes destination. The sidebar stays on `.notes`
/// whichever leg is showing.
enum NotesRoute: Equatable, Sendable {
    case list
    case note(UUID)

    var openNoteID: UUID? {
        if case .note(let id) = self { return id }
        return nil
    }
}

/// One start request for a note that records. `noteID` is `nil` when the capture
/// should create its own note; `includeSystemAudio` selects the second source.
struct NoteCaptureRequest: Equatable, Sendable {
    var noteID: UUID?
    var includeSystemAudio: Bool
    var expectedSpeakerCount: Int?

    init(noteID: UUID? = nil, includeSystemAudio: Bool = false, expectedSpeakerCount: Int? = nil) {
        self.noteID = noteID
        self.includeSystemAudio = includeSystemAudio
        self.expectedSpeakerCount = expectedSpeakerCount
    }
}

struct LibraryOpenRequest: Equatable, Sendable {
    let recordID: UUID
    let generation: UInt
}

@MainActor
@Observable
final class MainWindowRouteState {
    private(set) var selectedItem: MainNavItem = .dictate
    private(set) var notesRoute: NotesRoute = .list
    private(set) var libraryOpenRequest: LibraryOpenRequest?
    private(set) var librarySearchRequest: UInt?

    private var nextLibraryRequestGeneration: UInt = 0
    private var nextLibrarySearchGeneration: UInt = 0

    func navigate(to item: MainNavItem) {
        // Picking Notes in the sidebar always lands on the list; `openNote`
        // is the only way into a note page.
        if item == .notes {
            notesRoute = .list
        }
        selectedItem = item
    }

    /// Resolves a raw value (persisted selection, menu round-trip, deep link)
    /// through the legacy alias map, then navigates. Unknown values are ignored.
    func navigate(toRawValue rawValue: String) {
        guard let item = MainNavItem.resolve(rawValue: rawValue) else { return }
        navigate(to: item)
    }

    /// Opens a note in the main window and keeps the sidebar on Notes.
    func openNote(id: UUID) {
        notesRoute = .note(id)
        selectedItem = .notes
    }

    /// Returns the Notes destination to its list, leaving the selection alone.
    func closeNote() {
        notesRoute = .list
    }

    func openLibrary(recordID: UUID) {
        nextLibraryRequestGeneration &+= 1
        libraryOpenRequest = LibraryOpenRequest(
            recordID: recordID,
            generation: nextLibraryRequestGeneration
        )
        selectedItem = .library
    }

    func focusLibrarySearch() {
        nextLibrarySearchGeneration &+= 1
        librarySearchRequest = nextLibrarySearchGeneration
        selectedItem = .library
    }

    func consumeLibraryOpenRequest(generation: UInt) {
        guard libraryOpenRequest?.generation == generation else { return }
        libraryOpenRequest = nil
    }

    func consumeLibrarySearchRequest(generation: UInt) {
        guard librarySearchRequest == generation else { return }
        librarySearchRequest = nil
    }
}

// MARK: - Window chrome metrics

enum MainWindowChrome {
    /// Space under standard traffic lights so top chrome/content never collides
    /// (button row + breathing room). Applied to whichever panel occupies top-left.
    static let trafficLightClearance: CGFloat = 36
}

// MARK: - Main Window View

struct MainWindow: View {
    @ObservedObject private var theme = PindropThemeController.shared
    @ObservedObject var settingsStore: SettingsStore
    let routeState: MainWindowRouteState
    let floatingIndicatorState: FloatingIndicatorState?
    let mediaTranscriptionState: MediaTranscriptionFeatureState?
    let recordingState: RecordingFeatureState?
    let modelManager: ModelManager?
    let onImportMediaFiles: (([URL], TranscriptionJobOptions) -> Void)?
    let onSubmitMediaLink: ((String, TranscriptionJobOptions) -> Void)?
    let onDownloadDiarizationModel: (() -> Void)?
    let onStartDictation: (() -> Void)?
    let onStartNoteCapture: ((NoteCaptureRequest) -> Bool)?
    let onOpenSettings: (SettingsTab) -> Void

    private var isCaptureBusy: Bool {
        recordingState?.isCaptureBusy == true
    }

    var body: some View {
        ZStack {
            AppColors.windowBackground
                .ignoresSafeArea()

            HStack(spacing: 0) {
                if settingsStore.selectedSidebarPosition == .leading {
                    sidebarPanel
                        .environment(\.layoutDirection, settingsStore.selectedAppLocale.layoutDirection)
                }
                detailPanel
                    .environment(\.layoutDirection, settingsStore.selectedAppLocale.layoutDirection)
                if settingsStore.selectedSidebarPosition == .trailing {
                    sidebarPanel
                        .environment(\.layoutDirection, settingsStore.selectedAppLocale.layoutDirection)
                }
            }
            .environment(\.layoutDirection, .leftToRight)
            .ignoresSafeArea()
        }
        .frame(
            minWidth: AppTheme.Window.mainMinWidth,
            minHeight: AppTheme.Window.mainMinHeight
        )
        .environment(\.locale, settingsStore.selectedAppLocale.locale)
        .environment(\.layoutDirection, settingsStore.selectedAppLocale.layoutDirection)
        .themeRefresh()
    }

    private var isLeadingSidebar: Bool {
        settingsStore.selectedSidebarPosition == .leading
    }

    private var sidebarPanel: some View {
        MainSidebar(
            isExpanded: $settingsStore.sidebarExpanded,
            position: settingsStore.selectedSidebarPosition,
            selectedNav: routeState.selectedItem,
            floatingIndicatorState: floatingIndicatorState,
            /// Leading sidebar owns top-left → clear traffic lights; trailing does not.
            reservesTrafficLightClearance: isLeadingSidebar,
            onSelect: routeState.navigate,
            onOpenSettings: { onOpenSettings(.general) }
        )
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var detailPanel: some View {
        VStack(spacing: 0) {
            // Trailing sidebar: detail occupies top-left under the traffic lights.
            if !isLeadingSidebar {
                trafficLightDragStrip
            }
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.contentBackground)
        .layoutPriority(1)
        .zIndex(1)
    }

    /// Clear strip that stays window-draggable via `isMovableByWindowBackground`
    /// (pages that opt out of drag live below this, not inside it).
    private var trafficLightDragStrip: some View {
        Color.clear
            .frame(height: MainWindowChrome.trafficLightClearance)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
    }

    // MARK: - Detail Content

    @ViewBuilder
    private var detailContent: some View {
        switch routeState.selectedItem {
        case .dictate:
            DictateView(
                settingsStore: settingsStore,
                recordingState: recordingState,
                isCaptureBusy: isCaptureBusy,
                onStartDictation: onStartDictation,
                onOpenLibrary: { routeState.navigate(to: .library) },
                onShowMoreStats: { routeState.navigate(to: .stats) },
                onOpenLibraryRecord: routeState.openLibrary,
                onDownloadDiarizationModel: onDownloadDiarizationModel
            )
        case .library:
            HistoryView(
                libraryOpenRequest: routeState.libraryOpenRequest,
                librarySearchRequest: routeState.librarySearchRequest,
                onConsumeLibraryOpenRequest: routeState.consumeLibraryOpenRequest,
                onConsumeLibrarySearchRequest: routeState.consumeLibrarySearchRequest,
                mediaTranscriptionState: mediaTranscriptionState,
                recordingState: recordingState,
                settingsStore: settingsStore,
                onImportMediaFiles: onImportMediaFiles,
                onSubmitMediaLink: onSubmitMediaLink,
                onDownloadDiarizationModel: onDownloadDiarizationModel
            )
            .accessibilityIdentifier("main.destination.library")
        case .notes:
            switch routeState.notesRoute {
            case .list:
                NotesView(
                    onOpenNote: { routeState.openNote(id: $0) },
                    onStartNoteCapture: onStartNoteCapture
                )
                .accessibilityIdentifier("main.destination.notes")
            case .note(let noteID):
                NotePageView(noteID: noteID, onBack: routeState.closeNote)
                    .accessibilityIdentifier("main.destination.note")
            }
        case .stats:
            StatsView()
                .accessibilityIdentifier("main.destination.stats")
        case .dictionary:
            DictionaryView()
                .accessibilityIdentifier("main.destination.dictionary")
        case .models:
            if let modelManager {
                ModelsSettingsView(settings: settingsStore, modelManager: modelManager)
                    .accessibilityIdentifier("main.destination.models")
            } else {
                comingSoonView(for: .models)
                    .accessibilityIdentifier("main.destination.models")
            }
        }
    }

    private func comingSoonView(for item: MainNavItem) -> some View {
        VStack(spacing: AppTheme.Spacing.lg) {
            Image(systemName: item.icon)
                .font(.system(size: 48))
                .foregroundStyle(AppColors.textTertiary)

            Text(item.title(locale: settingsStore.selectedAppLocale.locale))
                .font(AppTypography.title)
                .foregroundStyle(AppColors.textPrimary)

            Text("Coming Soon")
                .font(AppTypography.body)
                .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.contentBackground)
    }
}



// MARK: - Sidebar

private struct MainSidebar: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @Binding var isExpanded: Bool
    let position: SidebarPosition
    let selectedNav: MainNavItem
    @ObservedObject private var indicatorState: FloatingIndicatorState
    /// When true, insert a draggable top strip so content clears traffic lights.
    let reservesTrafficLightClearance: Bool
    let onSelect: (MainNavItem) -> Void
    let onOpenSettings: () -> Void

    /// Aggregate library size only — never materialize TranscriptionRecord rows here.
    @State private var libraryCount = 0
    @State private var libraryCountRefreshGeneration: UInt = 0
    @State private var isCollapseHovered = false
    @State private var isSettingsHovered = false

    init(
        isExpanded: Binding<Bool>,
        position: SidebarPosition,
        selectedNav: MainNavItem,
        floatingIndicatorState: FloatingIndicatorState?,
        reservesTrafficLightClearance: Bool,
        onSelect: @escaping (MainNavItem) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self._isExpanded = isExpanded
        self.position = position
        self.selectedNav = selectedNav
        self._indicatorState = ObservedObject(wrappedValue: floatingIndicatorState ?? FloatingIndicatorState())
        self.reservesTrafficLightClearance = reservesTrafficLightClearance
        self.onSelect = onSelect
        self.onOpenSettings = onOpenSettings
    }

    private var currentWidth: CGFloat {
        isExpanded ? AppTheme.Window.sidebarWidth : AppTheme.Window.sidebarCollapsedWidth
    }

    private var statusPhase: StatusCardPhase {
        StatusCardPhase(state: indicatorState)
    }

    /// Stable identity for the active SwiftData container so count reloads when it changes.
    private var modelContainerIdentity: ObjectIdentifier {
        ObjectIdentifier(modelContext.container)
    }

    var body: some View {
        VStack(spacing: 0) {
            if reservesTrafficLightClearance {
                // Window-draggable strip (no drag-blocker) under real traffic lights.
                Color.clear
                    .frame(height: MainWindowChrome.trafficLightClearance)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }

            appHeader

            mainNavSection
                .padding(.top, isExpanded ? 0 : AppTheme.Spacing.sm)

            Spacer(minLength: 8)

            bottomSection
        }
        .padding(.top, 16)
        .padding(.leading, isExpanded ? 16 : 8)
        .padding(.trailing, isExpanded ? 12 : 8)
        .padding(.bottom, 12)
        .frame(width: currentWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AppColors.sidebarBackground)
        // Physical content-edge divider. Sidebar inherits locale layoutDirection
        // for labels; the overlay HStack is force-LTR so the 1 pt rule sits on the
        // absolute left/right edge (not the outer window edge under RTL).
        .overlay {
            HStack(spacing: 0) {
                if position == .trailing {
                    Rectangle()
                        .fill(AppColors.border)
                        .frame(width: 1)
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(AppColors.border)
                        .frame(width: 1)
                }
            }
            .environment(\.layoutDirection, .leftToRight)
            .allowsHitTesting(false)
        }
        .appAnimation(.smooth, value: isExpanded)
        .task(id: modelContainerIdentity) {
            scheduleLibraryCountRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .historyStoreDidChange)) { _ in
            scheduleLibraryCountRefresh()
        }
    }

    /// Coalesces bursty history notifications to a single latest-value count fetch.
    private func scheduleLibraryCountRefresh() {
        libraryCountRefreshGeneration &+= 1
        let generation = libraryCountRefreshGeneration
        Task { @MainActor in
            await Task.yield()
            guard generation == libraryCountRefreshGeneration else { return }
            refreshLibraryCount()
        }
    }

    private func refreshLibraryCount() {
        do {
            let count = try modelContext.fetchCount(FetchDescriptor<TranscriptionRecord>())
            if libraryCount != count {
                libraryCount = count
            }
        } catch {
            Log.ui.error("Failed to fetch library count: \(error.localizedDescription)")
        }
    }

    // MARK: - App Header

    private var appHeader: some View {
        Group {
            if isExpanded {
                Text("Pindrop")
                    .font(AppTypography.wordmark)
                    .tracking(AppTypography.wordmarkTracking)
                    .foregroundStyle(AppColors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 28)
            } else {
                Image("PindropIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(AppColors.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 16)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Main Navigation

    private var mainNavSection: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 14 : 8) {
            ForEach(MainNavGroup.allCases) { group in
                if let section = MainNavItem.sidebarGroups.first(where: { $0.group == group }) {
                    VStack(alignment: .leading, spacing: 2) {
                        if isExpanded {
                            Text(group.title(locale: locale))
                                .font(AppTypography.monoSmall)
                                .foregroundStyle(AppColors.textTertiary)
                                .textCase(.uppercase)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 4)
                                .accessibilityIdentifier("sidebar.group.\(group.rawValue)")
                        }

                        ForEach(section.items) { item in
                            SidebarItem(
                                title: item.title(locale: locale),
                                systemImage: item.icon,
                                count: item == .library && isExpanded && libraryCount > 0 ? libraryCount : nil,
                                isCollapsed: !isExpanded,
                                accessibilityIdentifier: "sidebar.nav.\(item.accessibilityIdentifierComponent)",
                                isSelected: selectedNav == item,
                                action: { onSelect(item) }
                            )
                        }
                    }
                }
            }
        }
        .padding(.trailing, isExpanded ? 4 : 0)
    }

    // MARK: - Bottom Section

    private var bottomSection: some View {
        VStack(spacing: isExpanded ? 8 : 10) {
            statusFooter
            collapseButton
            settingsButton
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        if isExpanded {
            StatusCard(phase: statusPhase, readyTitle: localized("Ready", locale: locale))
        } else {
            StatusCardDot(phase: statusPhase)
                .frame(maxWidth: .infinity)
        }
    }

    private var settingsButton: some View {
        Button(action: onOpenSettings) {
            Group {
                if isExpanded {
                    HStack(spacing: 10) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppColors.textSecondary)
                            .frame(width: 18, height: 18)
                        Text(localized("Settings", locale: locale))
                            .font(AppTypography.labelStrong)
                            .foregroundStyle(AppColors.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text("⌘,")
                            .font(AppTypography.monoSmall)
                            .foregroundStyle(AppColors.textTertiary)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                } else {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(width: 18, height: 18)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSettingsHovered ? AppColors.sidebarItemHover : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.settings")
        .accessibilityLabel(localized("Settings", locale: locale))
        .help(localized("Settings", locale: locale))
        .onHover { hovering in isSettingsHovered = hovering }
    }

    private var collapseButton: some View {
        let accessibilityTitle = localized(isExpanded ? "Collapse" : "Expand", locale: locale)
        let icon = position == .trailing
            ? (isExpanded ? "sidebar.right" : "sidebar.left")
            : (isExpanded ? "sidebar.left" : "sidebar.right")
        return Button {
            withAnimation(reduceMotion ? nil : AppTheme.Animation.smooth) {
                isExpanded.toggle()
            }
        } label: {
            Group {
                if isExpanded {
                    HStack(spacing: 10) {
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppColors.textSecondary)
                            .frame(width: 18, height: 18)
                        Text(localized("Collapse", locale: locale))
                            .font(AppTypography.labelStrong)
                            .foregroundStyle(AppColors.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(width: 18, height: 18)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isCollapseHovered ? AppColors.sidebarItemHover : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityTitle)
        .help(accessibilityTitle)
        .onHover { hovering in isCollapseHovered = hovering }
    }
}

// MARK: - Main Window Controller

@MainActor
final class MainWindowController {

    /// Stable identifier so list key monitors can require the *main* window
    /// (not Settings / Note Editor / other panels) to be key.
    static let windowIdentifier = NSUserInterfaceItemIdentifier("tech.watzon.pindrop.main-window")

    private var window: NSWindow?
    private var modelContainer: ModelContainer?
    private var floatingIndicatorState: FloatingIndicatorState?
    private var mediaTranscriptionState: MediaTranscriptionFeatureState?
    private var recordingState: RecordingFeatureState?
    private var modelManager: ModelManager?
    private var settingsStore: SettingsStore?
    let routeState = MainWindowRouteState()
    var onImportMediaFiles: (([URL], TranscriptionJobOptions) -> Void)?
    var onSubmitMediaLink: ((String, TranscriptionJobOptions) -> Void)?
    var onDownloadDiarizationModel: (() -> Void)?
    var onStartDictation: (() -> Void)?
    var onStartNoteCapture: ((NoteCaptureRequest) -> Bool)?
    var onOpenSettings: ((SettingsTab) -> Void)?

    /// The main app window, if created. Used by list keyboard monitors for identity checks.
    var nsWindow: NSWindow? { window }

    var isWindowKey: Bool {
        window?.isKeyWindow == true
    }

    /// Whether `window` is the Pindrop main window and currently key.
    static func isMainWindowKey(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.identifier == windowIdentifier && window.isKeyWindow
    }

    func setModelContainer(_ container: ModelContainer) {
        self.modelContainer = container
    }

    func configureCapture(
        floatingIndicatorState: FloatingIndicatorState,
        recordingState: RecordingFeatureState? = nil,
        onStartDictation: @escaping () -> Void,
        onStartNoteCapture: @escaping (NoteCaptureRequest) -> Bool
    ) {
        self.floatingIndicatorState = floatingIndicatorState
        self.recordingState = recordingState
        self.onStartDictation = onStartDictation
        self.onStartNoteCapture = onStartNoteCapture
    }

    func configureTranscribeFeature(
        state: MediaTranscriptionFeatureState,
        modelManager: ModelManager,
        settingsStore: SettingsStore,
        onImportMediaFiles: @escaping ([URL], TranscriptionJobOptions) -> Void,
        onSubmitMediaLink: @escaping (String, TranscriptionJobOptions) -> Void,
        onDownloadDiarizationModel: @escaping () -> Void
    ) {
        self.mediaTranscriptionState = state
        self.modelManager = modelManager
        self.settingsStore = settingsStore
        self.onImportMediaFiles = onImportMediaFiles
        self.onSubmitMediaLink = onSubmitMediaLink
        self.onDownloadDiarizationModel = onDownloadDiarizationModel
    }

    func show() {
        presentWindow()
    }

    func navigate(to item: MainNavItem) {
        routeState.navigate(to: item)
        presentWindow()
    }

    /// Resolves a raw value through the legacy alias map before navigating.
    func navigate(toRawValue rawValue: String) {
        guard let item = MainNavItem.resolve(rawValue: rawValue) else {
            Log.ui.warning("Ignored navigation to unknown destination \(rawValue)")
            return
        }
        navigate(to: item)
    }

    /// Opens a note in the main window. Replaces the separate editor window as
    /// the default presenter; `NoteEditorWindowController` survives as a pop-out.
    func openNote(id: UUID) {
        routeState.openNote(id: id)
        presentWindow()
    }

    func openLibrary(recordID: UUID) {
        routeState.openLibrary(recordID: recordID)
        presentWindow()
    }

    func focusLibrarySearch() {
        routeState.focusLibrarySearch()
        presentWindow()
    }

    func showSettings(tab: SettingsTab = .general) {
        guard let onOpenSettings else {
            Log.ui.error("Settings presenter not set - cannot show settings")
            return
        }

        onOpenSettings(tab)
    }

    private func presentWindow() {
        guard let container = modelContainer else {
            Log.ui.error("ModelContainer not set - cannot show MainWindow")
            return
        }
        guard let settingsStore else {
            Log.ui.error("SettingsStore not set - cannot show MainWindow")
            return
        }

        if window == nil {
            let mainView = MainWindow(
                settingsStore: settingsStore,
                routeState: routeState,
                floatingIndicatorState: floatingIndicatorState,
                mediaTranscriptionState: mediaTranscriptionState,
                recordingState: recordingState,
                modelManager: modelManager,
                onImportMediaFiles: onImportMediaFiles,
                onSubmitMediaLink: onSubmitMediaLink,
                onDownloadDiarizationModel: onDownloadDiarizationModel,
                onStartDictation: onStartDictation,
                onStartNoteCapture: onStartNoteCapture,
                onOpenSettings: onOpenSettings ?? { _ in
                    Log.ui.error("Settings presenter not set - cannot show settings")
                }
            )
                .modelContainer(container)
            // Standard hosting controller — full-size transparent titlebar provides
            // correct traffic-light / drag regions without zeroing safe areas.
            let hostingController = NSHostingController(rootView: mainView)

            let window = NSWindow(
                contentRect: NSRect(
                    x: 0,
                    y: 0,
                    width: AppTheme.Window.mainDefaultWidth,
                    height: AppTheme.Window.mainDefaultHeight
                ),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = hostingController
            window.title = "Pindrop"
            window.identifier = Self.windowIdentifier
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.toolbar = nil
            window.toolbarStyle = .unifiedCompact
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(AppColors.windowBackground)
            window.isOpaque = true
            window.hasShadow = true
            window.setContentSize(NSSize(
                width: AppTheme.Window.mainDefaultWidth,
                height: AppTheme.Window.mainDefaultHeight
            ))
            window.minSize = NSSize(
                width: AppTheme.Window.mainMinWidth,
                height: AppTheme.Window.mainMinHeight
            )
            window.center()
            window.isReleasedWhenClosed = false
            // Menu-bar app owns presentation; do not let AppKit restore this window.
            window.isRestorable = false
            PindropThemeController.shared.apply(to: window)
            applyInterfaceLayoutDirection(to: window, locale: settingsStore.selectedAppLocale.locale)

            self.window = window

        }

        PindropThemeController.shared.apply(to: window)
        if let window {
            applyInterfaceLayoutDirection(to: window, locale: settingsStore.selectedAppLocale.locale)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { self.positionTrafficLights() }

    }

    /// Positions standard traffic lights in the leading-sidebar top pad (spec §3).
    /// Real system controls — only origin is adjusted; size stays AppKit-native.
    private func positionTrafficLights() {
        guard let window = window,
              let close = window.standardWindowButton(.closeButton),
              let mini = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let superview = close.superview else { return }

        // Match sidebar leading/top pad (16) and design gap (8) between controls.
        let pad: CGFloat = 16
        let gap: CGFloat = 8
        let bw = close.frame.width
        let bh = close.frame.height
        // NSView coords: origin bottom-left; pin tops `pad` from superview top.
        let y = superview.bounds.height - pad - bh

        close.setFrameOrigin(NSPoint(x: pad, y: y))
        mini.setFrameOrigin(NSPoint(x: pad + bw + gap, y: y))
        zoom.setFrameOrigin(NSPoint(x: pad + 2 * (bw + gap), y: y))

        for btn in [close, mini, zoom] {
            btn.autoresizingMask = [.minYMargin]
        }
        zoom.isHidden = true
    }

    func hide() {
        window?.orderOut(nil)
    }

    func toggle() {
        if window?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    var isVisible: Bool {
        window?.isVisible == true
    }
}

#Preview("Main Window - Light") {
    MainWindow(
        settingsStore: SettingsStore(),
        routeState: MainWindowRouteState(),
        floatingIndicatorState: nil,
        mediaTranscriptionState: nil,
        recordingState: nil,
        modelManager: nil,
        onImportMediaFiles: nil,
        onSubmitMediaLink: nil,
        onDownloadDiarizationModel: nil,
        onStartDictation: nil,
        onStartNoteCapture: nil,
        onOpenSettings: { _ in }
    )
        .modelContainer(PreviewContainer.empty)
        .preferredColorScheme(.light)
        .frame(width: AppTheme.Window.mainDefaultWidth, height: AppTheme.Window.mainDefaultHeight)
}

#Preview("Main Window - Dark") {
    MainWindow(
        settingsStore: SettingsStore(),
        routeState: MainWindowRouteState(),
        floatingIndicatorState: nil,
        mediaTranscriptionState: nil,
        recordingState: nil,
        modelManager: nil,
        onImportMediaFiles: nil,
        onSubmitMediaLink: nil,
        onDownloadDiarizationModel: nil,
        onStartDictation: nil,
        onStartNoteCapture: nil,
        onOpenSettings: { _ in }
    )
        .modelContainer(PreviewContainer.empty)
        .preferredColorScheme(.dark)
        .frame(width: AppTheme.Window.mainDefaultWidth, height: AppTheme.Window.mainDefaultHeight)
}
