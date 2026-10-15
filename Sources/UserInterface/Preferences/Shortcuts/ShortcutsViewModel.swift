// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine
import AppKit
class ShortcutsViewModel: ObservableObject {
    enum Capture: Equatable {
        case command(CommandWrapper)
        case search
    }

    struct Reassignment: Identifiable {
        let id = UUID()
        let command: CommandWrapper
        let key: ShortcutsKey
        let owners: Set<ShortcutBinding.Owner>
        let names: [String]
        let canReassign: Bool
        let configuration: [Int: ShortcutOverride]
        let fileURL: URL?
    }

    enum PersistenceFailure {
        case load, save

        var message: String {
            switch self {
            case .load:
                return NSLocalizedString("settings.shortcuts.persistence.loadFailed", value: "Saved shortcuts could not be read. Retry, or restore all shortcuts to keep a recovery copy and use the defaults.", comment: "Shortcuts settings - Configuration could not be loaded; edits are blocked until retry or explicit recovery")
            case .save:
                return NSLocalizedString("settings.shortcuts.persistence.saveFailed", value: "The change could not be saved. Your previous shortcuts are still active. Try the change again.", comment: "Shortcuts settings - A failed save leaves the previous shortcuts active")
            }
        }
    }

    @Published var sections: [(category: String, subtitle: String?, items: [ShortcutItem])] = []
    @Published var capture: Capture?
    @Published var searchedKey: ShortcutsKey?
    @Published var reassignment: Reassignment?
    @Published var recordingMessage: String?
    @Published private(set) var reservedShortcuts: [ReservedShortcutItem] = []
    @Published var hiddenGroups: Set<Shortcuts.Group> = [.help, .bookmarks]
    @Published private(set) var persistenceFailure: PersistenceFailure?
    private var cancellables = Set<AnyCancellable>()
    private let additionalBindings: () -> [ShortcutBinding]
    private(set) var inventory = ShortcutInventory(bindings: [])

    var canEdit: Bool { persistenceFailure != .load }

    var editingCommand: CommandWrapper? {
        get {
            if case .command(let command) = capture { return command }
            return nil
        }
        set { capture = newValue.map(Capture.command) }
    }
    
    init(additionalBindings: @escaping () -> [ShortcutBinding] = Shortcuts.additionalBindings) {
        self.additionalBindings = additionalBindings
        SpaceManager.shared.$spaces
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildSections()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .shortcutsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.capture = nil
                self.reassignment = nil
                self.refreshLoadFailure()
                self.rebuildSections()
            }
            .store(in: &cancellables)
        refreshLoadFailure()
        rebuildSections()
    }
    
    func rebuildSections() {
        let snapshot = Shortcuts.bindingInventory(additionalBindings: additionalBindings())
        inventory = ShortcutInventory(bindings: snapshot.bindings.filter { binding in
            binding.commandID.flatMap(CommandWrapper.init(rawValue:)).map(shouldShow) ?? true
        })
        var newSections: [(category: String, subtitle: String?, items: [ShortcutItem])] = []
        
        Shortcuts.Group.allCases
            .filter { !hiddenGroups.contains($0) }
            .forEach { group in
                let items = group.commands.filter(shouldShow).map(makeItem)
                
                if !items.isEmpty {
                    newSections.append((category: group.title, subtitle: group.subtitle, items: items))
                }
            }
        
        // Discover remaining browser commands from the live tables. Keep saved
        // commands available after disabling them removes their runtime binding.
        let grouped = Set(Shortcuts.configurableCommands)
        let discovered = Set(inventory.bindings.compactMap(\.commandID)
            + Array(Shortcuts.configuration.overrides.keys))
            .compactMap(CommandWrapper.init(rawValue:))
            .filter { !grouped.contains($0) && !$0.isSystemShortcut && shouldShow($0)
                && $0 != .IDC_SHOW_READING_MODE_KEYBOARD }
            .sorted { $0.rawValue < $1.rawValue }
        if !discovered.isEmpty {
            newSections.append((category: NSLocalizedString(
                "settings.shortcuts.group.otherBrowser", value: "Other Browser Commands",
                comment: "Shortcuts settings - Additional customizable browser commands"),
                subtitle: nil, items: discovered.map(makeItem)))
        }
        sections = newSections
        let editable = Set(sections.flatMap(\.items).map { ShortcutBinding.Owner.command($0.command.rawValue) })
        let unlisted = Dictionary(grouping: inventory.bindings.filter {
            guard !editable.contains($0.owner), case .command(let id) = $0.owner else { return false }
            return CommandWrapper(rawValue: id)?.isSystemShortcut != true
        }, by: \.owner)
        reservedShortcuts = unlisted.keys.sorted { $0.precedes($1) }.map { owner in
            ReservedShortcutItem(id: owner, name: displayName(for: owner),
                                 keys: Array(Set(unlisted[owner, default: []].map(\.key)))
                                    .sorted { $0.displayString < $1.displayString })
        }
    }

    private func makeItem(_ command: CommandWrapper) -> ShortcutItem {
        let bindings = inventory.bindings(for: command.rawValue)
        // Chromium owns defaults for commands absent from Phi's default table.
        // An explicit disable must never fall back to a stale runtime snapshot.
        let key = Shortcuts.key(for: command) ?? (Shortcuts.isOverridden(command) ? nil : bindings.first?.key)
        return ShortcutItem(
            id: command, command: command, name: displayName(for: command),
            shortcutKey: key, shortcutDisplay: shortcutDisplay(for: command, key: key),
            isOverridden: Shortcuts.isOverridden(command),
            conflictingCommandNames: findConflictingCommands(for: command).map { displayName(for: $0) },
            searchKeywords: searchKeywords(for: command),
            aliases: Array(Set(bindings.map(\.key))).sorted { $0.displayString < $1.displayString }
        )
    }

    private func shortcutDisplay(
        for command: CommandWrapper,
        key: ShortcutsKey?
    ) -> String {
        guard let key else {
            return NSLocalizedString(
                "settings.shortcuts.unassignedPlaceholder",
                value: "Add New",
                comment: "Shortcuts settings - Placeholder text when no shortcut is assigned"
            )
        }

        // AppKit reports the shifted characters for these default events, so
        // execution stores "{" and "}". Keep the settings label in the
        // familiar physical-key notation without changing global key identity.
        guard key == Shortcuts.DefaultShortcuts[command] else {
            return key.displayString
        }
        switch command {
        case .IDC_SELECT_PREVIOUS_TAB:
            return ShortcutsKey(
                characters: "[",
                modifiers: key.modifiers
            ).displayString
        case .IDC_SELECT_NEXT_TAB:
            return ShortcutsKey(
                characters: "]",
                modifiers: key.modifiers
            ).displayString
        default:
            return key.displayString
        }
    }
    
    private func findConflictingCommands(for command: CommandWrapper) -> [ShortcutBinding.Owner] {
        let owners = Set(inventory.bindings(for: command.rawValue).flatMap { binding in
            inventory.conflicts(for: command.rawValue, key: binding.key,
                                in: binding.scope).map(\.owner)
        })
        return owners.sorted { $0.precedes($1) }
    }

    private func shouldShow(_ command: CommandWrapper) -> Bool {
        guard !Shortcuts.disabledShortcutCommands.contains(command) else { return false }
        guard let index = command.spaceSelectionIndex else {
            return true
        }
        return index < SpaceManager.shared.spaces.count
    }

    private func displayName(for command: CommandWrapper) -> String {
        if let index = command.spaceSelectionIndex {
            let spaces = SpaceManager.shared.spaces
            if spaces.indices.contains(index) {
                return String(
                    format: NSLocalizedString("settings.shortcuts.activateSpaceCommandTitle", value: "Go to Space \"%@\"", comment: "Shortcuts settings - Command title to activate the Space at this position"),
                    spaces[index].name
                )
            }
        }
        return command.localizedShortcutTitle
    }

    private func displayName(for owner: ShortcutBinding.Owner) -> String {
        let command = owner.commandID.flatMap(CommandWrapper.init(rawValue:))
        if let command, Shortcuts.configurableCommands.contains(command) {
            return displayName(for: command)
        }
        if let title = inventory.bindings.first(where: { $0.owner == owner && $0.title?.isEmpty == false })?.title {
            return title
        }
        if let command { return displayName(for: command) }
        return NSLocalizedString("settings.shortcuts.reservedOwner", value: "Reserved browser shortcut", comment: "Shortcuts settings - An active browser binding that cannot be customized in this version")
    }

    func matchesSearch(_ owner: ShortcutBinding.Owner) -> Bool {
        guard let searchedKey else { return true }
        return inventory.occupants(of: searchedKey).contains { $0.owner == owner }
    }

    func handleCaptureEvent(_ event: NSEvent) {
        guard event.type == .keyDown, let capture else { return }
        let action = ShortcutsKey.recordingAction(for: event)
        if capture == .search {
            if action != .cancel { searchedKey = ShortcutsKey.eventKeys(for: event)?.canonical }
            self.capture = nil
            return
        }
        guard case .command(let command) = capture else { return }
        switch action {
        case .cancel:
            self.capture = nil
        case .disable:
            disableShortcut(for: command)
        case .key(let key):
            requestCustomShortcut(for: command, key: key)
        case .unsupported:
            recordingMessage = event.keyCode == 53
                ? NSLocalizedString("settings.shortcuts.recording.escapeModifiers", value: "Escape shortcuts require Command or Control.", comment: "Shortcuts settings - macOS menu matching does not support Escape with only Shift or Option")
                : NSLocalizedString("settings.shortcuts.recording.unsupported", value: "Use a modifier key. Letters and symbols require Command, Control, or Option.", comment: "Shortcuts settings - Recording rejected an unmodified key or a Shift-only printable key to preserve normal typing")
        }
    }

    func requestCustomShortcut(for command: CommandWrapper, key: ShortcutsKey) {
        capture = nil
        recordingMessage = nil
        rebuildSections()
        let owners = Set(inventory.conflicts(for: command.rawValue, key: key,
                                            in: command.shortcutScope).map(\.owner))
        guard !owners.isEmpty else {
            setCustomShortcut(for: command, key: key)
            return
        }
        let configurable = Set(sections.flatMap(\.items).map { $0.command.rawValue })
        reassignment = Reassignment(
            command: command, key: key, owners: owners,
            names: owners.sorted { $0.precedes($1) }.map { displayName(for: $0) },
            canReassign: owners.allSatisfy { $0.commandID.map(configurable.contains) ?? false },
            configuration: Shortcuts.configuration.overrides,
            fileURL: Shortcuts.configuration.fileURL
        )
    }

    func confirmReassignment(_ pending: Reassignment?) {
        guard let pending, pending.canReassign else { return }
        reassignment = nil
        rebuildSections()
        let currentOwners = Set(inventory.conflicts(for: pending.command.rawValue,
                                                   key: pending.key, in: pending.command.shortcutScope).map(\.owner))
        guard currentOwners == pending.owners,
              Shortcuts.configuration.overrides == pending.configuration,
              Shortcuts.configuration.fileURL == pending.fileURL else {
            recordingMessage = NSLocalizedString("settings.shortcuts.reassignment.changed", value: "Shortcuts changed while you were reviewing them. Record the shortcut again to review the current conflicts.", comment: "Shortcuts settings - A stale conflict confirmation was canceled without changing any bindings")
            return
        }
        apply(Shortcuts.setOverride(.custom(pending.key), for: pending.command,
                                   disabling: pending.owners.compactMap(\.commandID)))
    }

    private func searchKeywords(for command: CommandWrapper) -> [String] {
        var keywords = command.searchKeywords
        keywords.append(displayName(for: command))
        if let index = command.spaceSelectionIndex {
            let spaces = SpaceManager.shared.spaces
            if spaces.indices.contains(index) {
                keywords.append(spaces[index].name)
                keywords.append("space \(index + 1)")
            }
        }
        return Array(Set(keywords.map { $0.lowercased() }))
    }
    
    func setCustomShortcut(for command: CommandWrapper, key: ShortcutsKey) {
        apply(Shortcuts.setOverride(.custom(key), for: command))
    }
    
    /// Disables the shortcut by storing an explicit empty override.
    func disableShortcut(for command: CommandWrapper) {
        apply(Shortcuts.setOverride(.disabled, for: command))
    }
    
    /// Restores the default shortcut for the command.
    func restoreDefaultShortcut(for command: CommandWrapper) {
        apply(Shortcuts.setOverride(nil, for: command))
    }
    
    func restoreAllShortcuts() {
        apply(Shortcuts.restoreOverrides())
    }

    func retryLoadingShortcuts() {
        apply(Shortcuts.reloadOverrides())
    }

    func dismissSaveFailure() {
        if persistenceFailure == .save { persistenceFailure = nil }
    }

    private func refreshLoadFailure() {
        if Shortcuts.configuration.loadError != nil {
            persistenceFailure = .load
        } else if persistenceFailure == .load {
            persistenceFailure = nil
        }
    }

    private func apply(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            persistenceFailure = nil
        case .failure:
            persistenceFailure = Shortcuts.configuration.loadError == nil ? .save : .load
        }
        editingCommand = nil
        rebuildSections()
    }
}

private extension CommandWrapper {
    var localizedShortcutTitle: String {
        switch self {
        case .IDC_OPTIONS:
            return NSLocalizedString("settings.shortcuts.command.openSettings", value: "Settings", comment: "Shortcuts settings - Command title for opening Phi settings")
        case .IDC_EXIT:
            return NSLocalizedString("settings.shortcuts.command.quitApp", value: "Quit Phi", comment: "Shortcuts settings - Command title for quitting Phi")
        case .IDC_MOVE_TAB_NEXT:
            return NSLocalizedString("settings.shortcuts.command.moveTabRight", value: "Move Tab Right", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_MOVE_TAB_PREVIOUS:
            return NSLocalizedString("settings.shortcuts.command.moveTabLeft", value: "Move Tab Left", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_SHOW_AVATAR_MENU:
            return NSLocalizedString("settings.shortcuts.command.showProfiles", value: "Show Profiles Menu", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_FOCUS_NEXT_PANE:
            return NSLocalizedString("settings.shortcuts.command.focusNextPane", value: "Focus Next Pane", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_FOCUS_PREVIOUS_PANE:
            return NSLocalizedString("settings.shortcuts.command.focusPreviousPane", value: "Focus Previous Pane", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_FOCUS_INACTIVE_POPUP_FOR_ACCESSIBILITY:
            return NSLocalizedString("settings.shortcuts.command.focusPopup", value: "Focus Open Popup", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_SHOW_READING_MODE_KEYBOARD:
            return NSLocalizedString("settings.shortcuts.command.showReadingMode", value: "Show Reading Mode", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_ADD_NEW_TAB_TO_GROUP:
            return NSLocalizedString("settings.shortcuts.command.addTabToGroup", value: "Add New Tab to Group", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_CREATE_NEW_TAB_GROUP:
            return NSLocalizedString("settings.shortcuts.command.createTabGroup", value: "Create New Tab Group", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_CLOSE_TAB_GROUP:
            return NSLocalizedString("settings.shortcuts.command.closeTabGroup", value: "Close Tab Group", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_FOCUS_NEXT_TAB_GROUP:
            return NSLocalizedString("settings.shortcuts.command.focusNextTabGroup", value: "Focus Next Tab Group", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_FOCUS_PREV_TAB_GROUP:
            return NSLocalizedString("settings.shortcuts.command.focusPreviousTabGroup", value: "Focus Previous Tab Group", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_DEBUG_TOGGLE_TABLET_MODE:
            return NSLocalizedString("settings.shortcuts.command.toggleTabletMode", value: "Toggle Tablet Mode", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_DEBUG_PRINT_VIEW_TREE:
            return NSLocalizedString("settings.shortcuts.command.printViewTree", value: "Print View Tree", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_DEBUG_PRINT_VIEW_TREE_DETAILS:
            return NSLocalizedString("settings.shortcuts.command.printViewTreeDetails", value: "Print View Tree Details", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_OPEN_FILE:
            return NSLocalizedString("settings.shortcuts.command.openFile", value: "Open File…", comment: "Shortcuts settings - Command title for opening a local file")
        case .IDC_NEW_TAB:
            return NSLocalizedString("settings.shortcuts.command.newTab", value: "New Tab", comment: "Shortcuts settings - Command title for opening a new tab")
        case .IDC_NEW_WINDOW:
            return NSLocalizedString("settings.shortcuts.command.newWindow", value: "New Window", comment: "Shortcuts settings - Command title for opening a new window")
        case .IDC_NEW_INCOGNITO_WINDOW:
            return NSLocalizedString("settings.shortcuts.command.newIncognitoWindow", value: "New Incognito Window", comment: "Shortcuts settings - Command title for opening a new Incognito window")
        case .PHI_NEW_INCOGNITO_SPACE:
            return NSLocalizedString("app.fileMenu.createNewIncognitoSpace", value: "New Incognito Space", comment: "File menu and Shortcuts settings - Command title for creating a new Incognito Space")
        case .PHI_NEW_KIOSK_WINDOW:
            return NSLocalizedString("settings.shortcuts.command.newKioskWindow", value: "New Kiosk Window", comment: "Shortcuts settings - Command title for opening a new Kiosk window")
        case .PHI_KIOSK_OPEN_IN_SPACE:
            return NSLocalizedString("settings.shortcuts.command.kioskOpenInSpace", value: "Open Kiosk or Peek in current Space", comment: "Shortcuts settings - Open the Kiosk page in the toolbar's target Space or expand Peek into a regular tab in the current Space")
        case .PHI_KIOSK_CHOOSE_SPACE:
            return NSLocalizedString("settings.shortcuts.command.kioskChooseSpace", value: "Show Kiosk \"Open in\" Menu", comment: "Shortcuts settings - Show the Open in menu for selecting a destination Space in a Kiosk window")
        case .IDC_RESTORE_TAB:
            return NSLocalizedString("settings.shortcuts.command.reopenClosedTab", value: "Reopen Closed Tab", comment: "Shortcuts settings - Command title for reopening the most recently closed tab")
        case .IDC_FOCUS_LOCATION:
            return NSLocalizedString("settings.shortcuts.command.focusAddressBar", value: "Focus Address Bar", comment: "Shortcuts settings - Command title for moving keyboard focus to the address bar")
        case .IDC_CLOSE_WINDOW:
            return NSLocalizedString("settings.shortcuts.command.closeWindow", value: "Close Window", comment: "Shortcuts settings - Command title for closing the current window")
        case .IDC_CLOSE_TAB:
            return NSLocalizedString("settings.shortcuts.command.closeTab", value: "Close Tab", comment: "Shortcuts settings - Command title for closing the current tab")
        case .IDC_PRINT:
            return NSLocalizedString("settings.shortcuts.command.printPage", value: "Print…", comment: "Shortcuts settings - Command title for printing the current page")
        case .PHI_SHARE_PAGE:
            return NSLocalizedString("settings.shortcuts.command.sharePage", value: "Share Page", comment: "Shortcuts settings - Command title for sharing the current page via the macOS share picker")
        case .PHI_COPY_URL:
            return NSLocalizedString("settings.shortcuts.command.copyURL", value: "Copy URL", comment: "Shortcuts settings - Command title for copying the current URL")
        case .PHI_TOGGLE_READER:
            return NSLocalizedString("settings.shortcuts.command.toggleReaderView", value: "Toggle Reader View", comment: "Shortcuts settings - Command title for switching the current page between Reader View and the normal page")
        case .PHI_SAVE_FOR_LATER:
            return NSLocalizedString("settings.shortcuts.command.saveToFolio", value: "Save to Folio", comment: "Shortcuts settings - Command title for saving the current page for later as markdown plus a webpage copy")
        case .IDC_FIND:
            return NSLocalizedString("settings.shortcuts.command.findOnPage", value: "Find", comment: "Shortcuts settings - Command title for finding text on the current page")
        case .IDC_FIND_NEXT:
            return NSLocalizedString("settings.shortcuts.command.findNextMatch", value: "Find Next", comment: "Shortcuts settings - Command title for selecting the next match on the current page")
        case .IDC_FIND_PREVIOUS:
            return NSLocalizedString("settings.shortcuts.command.findPreviousMatch", value: "Find Previous", comment: "Shortcuts settings - Command title for selecting the previous match on the current page")
        case .IDC_FOCUS_SEARCH:
            return NSLocalizedString("settings.shortcuts.command.searchTheWeb", value: "Search the Web...", comment: "Shortcuts settings - Command title for starting a web search")
        case .IDC_STOP:
            return NSLocalizedString("settings.shortcuts.command.stopLoading", value: "Stop", comment: "Shortcuts settings - Command title for stopping the current page from loading")
        case .IDC_RELOAD:
            return NSLocalizedString("settings.shortcuts.command.reloadPage", value: "Reload Page", comment: "Shortcuts settings - Command title for reloading the current page")
        case .IDC_RELOAD_BYPASSING_CACHE:
            return NSLocalizedString("settings.shortcuts.command.forceReload", value: "Force Reload Page", comment: "Shortcuts settings - Reload the page without using cached content")
        case .IDC_ZOOM_NORMAL:
            return NSLocalizedString("settings.shortcuts.command.resetZoom", value: "Zoom Normal", comment: "Shortcuts settings - Command title for restoring the default page zoom level")
        case .IDC_ZOOM_PLUS:
            return NSLocalizedString("settings.shortcuts.command.zoomIn", value: "Zoom Plus", comment: "Shortcuts settings - Command title for increasing the page zoom level")
        case .IDC_ZOOM_MINUS:
            return NSLocalizedString("settings.shortcuts.command.zoomOut", value: "Zoom Minus", comment: "Shortcuts settings - Command title for decreasing the page zoom level")
        case .IDC_VIEW_SOURCE:
            return NSLocalizedString("settings.shortcuts.command.viewPageSource", value: "View Page Source", comment: "Shortcuts settings - Command title for viewing the current page source")
        case .IDC_DEV_TOOLS:
            return NSLocalizedString("settings.shortcuts.command.openDeveloperTools", value: "Open DevTools", comment: "Shortcuts settings - Command title for opening developer tools")
        case .IDC_DEV_TOOLS_INSPECT:
            return NSLocalizedString("settings.shortcuts.command.inspectWithDeveloperTools", value: "Dev Tools Inspect", comment: "Shortcuts settings - Command title for inspecting the page with developer tools")
        case .IDC_DEV_TOOLS_CONSOLE:
            return NSLocalizedString("settings.shortcuts.command.openDeveloperConsole", value: "Dev Tools Console", comment: "Shortcuts settings - Command title for opening the developer tools console")
        case .PHI_TOGGLE_SIDEBAR:
            return NSLocalizedString("settings.shortcuts.command.toggleSidebar", value: "Toggle Sidebar", comment: "Shortcuts settings - Command title for showing or hiding the sidebar")
        case .PHI_TOGGLE_CHATBAR:
            return NSLocalizedString("settings.shortcuts.command.toggleChatbar", value: "Toggle Chatbar", comment: "Shortcuts settings - Command title for showing or hiding the Chatbar")
        case .PHI_NEW_CONVERSATION:
            return NSLocalizedString("settings.shortcuts.command.newConversation", value: "New Conversation", comment: "Shortcuts settings - Command title for starting a new conversation")
        case .IDC_HOME:
            return NSLocalizedString("settings.shortcuts.command.goHome", value: "Home", comment: "Shortcuts settings - Command title for opening the home page")
        case .IDC_BACK:
            return NSLocalizedString("settings.shortcuts.command.goBack", value: "Back", comment: "Shortcuts settings - Command title for navigating back")
        case .IDC_FORWARD:
            return NSLocalizedString("settings.shortcuts.command.goForward", value: "Forward", comment: "Shortcuts settings - Command title for navigating forward")
        case .IDC_SHOW_HISTORY:
            return NSLocalizedString("settings.shortcuts.command.showHistory", value: "Show History", comment: "Shortcuts settings - Command title for showing browsing history")
        case .IDC_MANAGE_EXTENSIONS:
            return NSLocalizedString("settings.shortcuts.command.manageExtensions", value: "Extensions", comment: "Shortcuts settings - Command title for managing browser extensions")
        case .IDC_SHOW_DOWNLOADS:
            return NSLocalizedString("settings.shortcuts.command.showDownloads", value: "Downloads", comment: "Shortcuts settings - Command title for showing downloads")
        case .PHI_TAB_SWITCHER_FORWARD:
            return NSLocalizedString("settings.shortcuts.command.showTabSwitcher", value: "Show Tab Switcher", comment: "Shortcuts settings - Command title for showing the tab switcher in forward order")
        case .PHI_TAB_SWITCHER_BACKWARD:
            return NSLocalizedString("settings.shortcuts.command.showTabSwitcherReverse", value: "Show Tab Switcher(Reverse)", comment: "Shortcuts settings - Command title for showing the tab switcher in reverse order")
        case .IDC_NEW_TAB_TO_RIGHT:
            return NSLocalizedString("settings.shortcuts.command.newTabToRight", value: "New Tab To Right", comment: "Shortcuts settings - Command title for opening a new tab to the right of the current tab")
        case .IDC_SELECT_NEXT_TAB:
            return NSLocalizedString("settings.shortcuts.command.selectNextTab", value: "Select Next Tab", comment: "Shortcuts settings - Command title for selecting the next tab")
        case .IDC_SELECT_PREVIOUS_TAB:
            return NSLocalizedString("settings.shortcuts.command.selectPreviousTab", value: "Select Previous Tab", comment: "Shortcuts settings - Command title for selecting the previous tab")
        case .IDC_SELECT_TAB_0:
            return Self.localizedTabSelectionTitle(number: 1)
        case .IDC_SELECT_TAB_1:
            return Self.localizedTabSelectionTitle(number: 2)
        case .IDC_SELECT_TAB_2:
            return Self.localizedTabSelectionTitle(number: 3)
        case .IDC_SELECT_TAB_3:
            return Self.localizedTabSelectionTitle(number: 4)
        case .IDC_SELECT_TAB_4:
            return Self.localizedTabSelectionTitle(number: 5)
        case .IDC_SELECT_TAB_5:
            return Self.localizedTabSelectionTitle(number: 6)
        case .IDC_SELECT_TAB_6:
            return Self.localizedTabSelectionTitle(number: 7)
        case .IDC_SELECT_TAB_7:
            return Self.localizedTabSelectionTitle(number: 8)
        case .IDC_SELECT_LAST_TAB:
            return NSLocalizedString("settings.shortcuts.command.selectLastTab", value: "Select Last Tab", comment: "Shortcuts settings - Command title for selecting the last tab")
        case .IDC_DUPLICATE_TAB:
            return NSLocalizedString("settings.shortcuts.command.duplicateTab", value: "Duplicate Tab", comment: "Shortcuts settings - Command title for duplicating the current tab")
        case .IDC_WINDOW_MUTE_SITE:
            return NSLocalizedString("settings.shortcuts.command.muteSite", value: "Mute Site", comment: "Shortcuts settings - Command title for muting audio from the current site")
        case .PHI_FARRINGDON_TOGGLE:
            return NSLocalizedString("settings.shortcuts.command.organizeTabsWithAI", value: "Organize Tabs with AI", comment: "Shortcuts settings - Command title for organizing tabs with AI")
        case .IDC_TAB_SEARCH:
            return NSLocalizedString("settings.shortcuts.command.searchTabs", value: "Tab Search", comment: "Shortcuts settings - Command title for searching open tabs")
        case .PHI_SELECT_NEXT_SPACE:
            return NSLocalizedString("settings.shortcuts.command.selectNextSpace", value: "Next Space", comment: "Shortcuts settings - Command title for selecting the next Space")
        case .PHI_SELECT_PREVIOUS_SPACE:
            return NSLocalizedString("settings.shortcuts.command.selectPreviousSpace", value: "Previous Space", comment: "Shortcuts settings - Command title for selecting the previous Space")
        default:
            return displayName
        }
    }

    private static func localizedTabSelectionTitle(number: Int) -> String {
        String(
            format: NSLocalizedString("settings.shortcuts.command.selectNumberedTab", value: "Select Tab %d", comment: "Shortcuts settings - Command title for selecting a numbered tab; %d is the tab position"),
            number
        )
    }
}

struct ShortcutItem: Identifiable {
    let id: CommandWrapper
    let command: CommandWrapper
    let name: String
    let shortcutKey: ShortcutsKey?
    let shortcutDisplay: String
    let isOverridden: Bool
    let conflictingCommandNames: [String]
    let searchKeywords: [String]
    var aliases: [ShortcutsKey] = []
    
    var hasConflict: Bool {
        !conflictingCommandNames.isEmpty
    }
}

struct ReservedShortcutItem: Identifiable {
    let id: ShortcutBinding.Owner
    let name: String
    let keys: [ShortcutsKey]
}
