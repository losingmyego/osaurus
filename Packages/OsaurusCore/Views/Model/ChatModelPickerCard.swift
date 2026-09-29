import AppKit
import SwiftUI

private enum ChatPickerLayout {
    static let rowHeight: CGFloat = 36
    static let rowSpacing: CGFloat = 2
    static let columnWidth: CGFloat = 240
    static let reasoningColumnWidth: CGFloat = 200
    static let columnSpacing: CGFloat = 20
    static let padding: CGFloat = 16
}

/// Only presentation values survive while the outgoing column is clipped away.
/// Actions always resolve against the currently selected model's control.
private struct ChatPickerReasoningSnapshot: Equatable {
    struct Row: Identifiable, Equatable {
        let id: String
        let label: String
        let help: String
    }

    let modelID: String?
    let optionID: String
    let rows: [Row]
    let selectedID: String?
}

/// The chat-only, column-based picker. Selection and option persistence remain
/// owned by FloatingInputCard; browsing another provider never changes a model.
struct ChatModelPickerCard: View {
    let providers: [ChatModelPickerProvider]
    @Binding var selectedModel: String?
    let optionsControl: ModelPickerOptionsControl?
    let onExploreLocal: () -> Void
    let onExploreCloud: () -> Void
    let onSizeChange: (CGSize) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.anchoredCardMetrics) private var cardMetrics
    @State private var browsedProviderID: String?
    @State private var search = ""
    @State private var showingOptions = false
    @ObservedObject var favorites = FavoriteModelsStore.shared
    @FocusState private var focus: String?
    @State private var keyboardNavigation = false
    @State private var retainedReasoning: ChatPickerReasoningSnapshot?
    @State private var visibleReasoningWidth: CGFloat = 0

    private var provider: ChatModelPickerProvider? {
        providers.first { $0.id == browsedProviderID }
            ?? providers.first { $0.models.contains { $0.id == selectedModel } }
            ?? providers.first { $0.isActive }
    }

    private var models: [ModelPickerItem] {
        guard let provider else { return [] }
        return provider.models.filter {
            search.isEmpty || $0.displayName.localizedStandardContains(search)
                || $0.id.localizedStandardContains(search)
        }
    }

    private var control: ModelPickerOptionsControl? {
        guard provider?.models.contains(where: { $0.id == selectedModel }) == true else { return nil }
        return optionsControl
    }

    private static func reasoningOption(in control: ModelPickerOptionsControl?) -> ModelOptionDefinition? {
        guard let option = control?.options.first(where: { $0.id == "reasoningEffort" }),
            case .segmented(let segments) = option.kind, segments.count > 1
        else { return nil }
        return option
    }

    private var reasoning: ModelOptionDefinition? {
        Self.reasoningOption(in: control)
    }

    private static func hasAdditionalOptions(in control: ModelPickerOptionsControl?) -> Bool {
        guard let control else { return false }
        let reasoningID = reasoningOption(in: control)?.id
        return control.thinking != nil || control.options.contains { $0.id != reasoningID }
    }

    private var hasAdditionalOptions: Bool {
        Self.hasAdditionalOptions(in: control)
    }

    private var columnWidth: CGFloat {
        guard let availableWidth = cardMetrics?.availableSize.width else { return ChatPickerLayout.columnWidth }
        let threeColumnChrome = 2 * ChatPickerLayout.padding + 2 * ChatPickerLayout.columnSpacing
        let fullColumnsWidth = 2 * ChatPickerLayout.columnWidth + ChatPickerLayout.reasoningColumnWidth
        let scale = min(1, max(0, availableWidth - threeColumnChrome) / fullColumnsWidth)
        return max(1, ChatPickerLayout.columnWidth * scale)
    }

    private var reasoningColumnWidth: CGFloat {
        columnWidth * ChatPickerLayout.reasoningColumnWidth / ChatPickerLayout.columnWidth
    }

    private var twoColumnWidth: CGFloat {
        2 * columnWidth + ChatPickerLayout.columnSpacing + 2 * ChatPickerLayout.padding
    }

    private var reasoningIsRevealed: Bool {
        currentReasoning != nil
            && visibleReasoningWidth >= reasoningColumnWidth + ChatPickerLayout.columnSpacing - 0.5
    }

    private var currentReasoning: ChatPickerReasoningSnapshot? {
        guard let reasoning, let control, case .segmented(let segments) = reasoning.kind else { return nil }
        return ChatPickerReasoningSnapshot(
            modelID: selectedModel,
            optionID: reasoning.id,
            rows: segments.map { segment in
                ChatPickerReasoningSnapshot.Row(
                    id: segment.id,
                    label: segment.label,
                    help: control.capabilities?.levels.first { $0.id == segment.id }?.description ?? segment.label
                )
            },
            selectedID: control.values[reasoning.id]?.stringValue ?? control.defaults[reasoning.id]?.stringValue
        )
    }

    static func initialSize(
        providers: [ChatModelPickerProvider],
        selectedModel: String?,
        optionsControl: ModelPickerOptionsControl?
    ) -> CGSize {
        let provider = providers.first { $0.models.contains { $0.id == selectedModel } }
            ?? providers.first { $0.isActive }
        let control = provider?.models.contains { $0.id == selectedModel } == true ? optionsControl : nil
        return cardSize(provider: provider, providerCount: providers.count, control: control,
                        columnWidth: ChatPickerLayout.columnWidth,
                        reasoningColumnWidth: ChatPickerLayout.reasoningColumnWidth, showingOptions: false)
    }

    private var preferredSize: CGSize {
        Self.cardSize(provider: provider, providerCount: providers.count, control: control,
                      columnWidth: columnWidth, reasoningColumnWidth: reasoningColumnWidth, showingOptions: showingOptions)
    }

    private static func cardSize(
        provider: ChatModelPickerProvider?,
        providerCount: Int,
        control: ModelPickerOptionsControl?,
        columnWidth: CGFloat,
        reasoningColumnWidth: CGFloat,
        showingOptions: Bool
    ) -> CGSize {
        let twoColumnWidth = 2 * columnWidth + ChatPickerLayout.columnSpacing + 2 * ChatPickerLayout.padding
        if showingOptions { return CGSize(width: twoColumnWidth, height: 380) }
        let reasoning = reasoningOption(in: control)
        let reasoningCount: Int
        if let reasoning, case .segmented(let segments) = reasoning.kind {
            reasoningCount = segments.count
        } else {
            reasoningCount = 0
        }
        let count = min(8, max(providerCount, max(provider?.models.count ?? 0, reasoningCount)))
        let modelFooter = (provider?.isLocal == true || provider?.isOsaurusCloud == true ? 44 : 0)
            + (hasAdditionalOptions(in: control) ? 44 : 0)
        let searchHeight = (provider?.models.count ?? 0) > 10 ? 38 : 0
        let rowsHeight = CGFloat(count) * ChatPickerLayout.rowHeight
            + CGFloat(max(0, count - 1)) * ChatPickerLayout.rowSpacing
        return CGSize(width: twoColumnWidth + (reasoning == nil ? 0 : reasoningColumnWidth + ChatPickerLayout.columnSpacing),
                      height: min(480, max(236, 68 + rowsHeight + CGFloat(modelFooter + searchHeight))))
    }

    var body: some View {
        Group {
            if showingOptions, let optionsControl {
                ChatModelOptionsPanel(control: optionsControl) {
                    showingOptions = false
                    DispatchQueue.main.async { focus = "options" }
                }
            } else {
                columns
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.primaryBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [theme.glassEdgeLight.opacity(0.2), theme.primaryBorder.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .font(theme.font(size: CGFloat(theme.bodySize)))
        .foregroundStyle(theme.primaryText)
        .onAppear {
            keyboardNavigation = NSApp.currentEvent?.type == .keyDown
            reportSize()
            focus = provider.map { "provider:\($0.id)" } ?? providers.first.map { "provider:\($0.id)" }
        }
        .onChange(of: preferredSize) { _, _ in reportSize() }
        .onChange(of: currentReasoning, initial: true) { previous, current in
            if let current {
                retainedReasoning = current
            } else {
                retainedReasoning = visibleReasoningWidth > 0 ? previous ?? retainedReasoning : nil
            }
            restoreReasoningFocusIfNeeded(current)
        }
        .onChange(of: reasoningIsRevealed) { _, revealed in
            if !revealed { restoreReasoningFocusIfNeeded(nil) }
        }
        .onChange(of: providers) { _, updated in
            if !updated.contains(where: { $0.id == browsedProviderID && $0.isActive }) {
                browsedProviderID = nil
            }
        }
        .onChange(of: optionsControl == nil) { _, missing in
            if missing { showingOptions = false }
        }
        .onKeyPress(phases: .down) { _ in
            keyboardNavigation = true
            return .ignored
        }
        .onMoveCommand { direction in
            keyboardNavigation = true
            moveFocus(direction)
        }
        .accessibilityIdentifier("chat-model-picker")
    }

    private var columns: some View {
        GeometryReader { geometry in
            let slotWidth = min(reasoningColumnWidth + ChatPickerLayout.columnSpacing,
                                max(0, geometry.size.width - twoColumnWidth))
            HStack(alignment: .top, spacing: 0) {
                providerColumn.frame(width: columnWidth)
                Color.clear.frame(width: ChatPickerLayout.columnSpacing).accessibilityHidden(true)
                modelColumn.frame(width: columnWidth)
                reasoningSlot(width: slotWidth)
            }
            .padding(ChatPickerLayout.padding)
            .onChange(of: slotWidth, initial: true) { _, width in
                visibleReasoningWidth = width
                if width == 0, currentReasoning == nil { retainedReasoning = nil }
            }
        }
    }

    private func reasoningSlot(width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: ChatPickerLayout.columnSpacing).accessibilityHidden(true)
            Group {
                if let snapshot = currentReasoning ?? retainedReasoning {
                    reasoningColumn(snapshot)
                } else {
                    Color.clear.accessibilityHidden(true)
                }
            }
            .frame(width: reasoningColumnWidth)
        }
        .frame(width: reasoningColumnWidth + ChatPickerLayout.columnSpacing, alignment: .leading)
        .frame(width: width, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        .disabled(!reasoningIsRevealed)
        .allowsHitTesting(reasoningIsRevealed)
        .accessibilityHidden(!reasoningIsRevealed)
    }

    private func restoreReasoningFocusIfNeeded(_ snapshot: ChatPickerReasoningSnapshot?) {
        guard let focus, focus.hasPrefix("reasoning:") else { return }
        let rowID = String(focus.dropFirst("reasoning:".count))
        guard snapshot?.rows.contains(where: { $0.id == rowID }) != true else { return }
        if let selectedModel, models.contains(where: { $0.id == selectedModel }) {
            self.focus = "model:\(selectedModel)"
        } else {
            self.focus = models.first.map { "model:\($0.id)" } ?? provider.map { "provider:\($0.id)" }
        }
    }

    private func reportSize() {
        let size = preferredSize
        DispatchQueue.main.async { onSizeChange(size) }
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(theme.font(size: CGFloat(theme.smallBodySize) + 2))
            .foregroundStyle(theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private var providerColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading(L("Provider"))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: ChatPickerLayout.rowSpacing) {
                        ForEach(providers) { item in
                            let key = "provider:\(item.id)"
                            ChatPickerRow(
                                title: item.title,
                                selected: item.id == provider?.id,
                                muted: !item.isActive,
                                explore: !item.isActive,
                                focused: keyboardNavigation && focus == key,
                                icon: { providerIcon(item) },
                                action: { chooseProvider(item) }
                            )
                            .focused($focus, equals: key)
                            .id(key)
                            .accessibilityLabel(item.isActive ? item.title : "\(L("Explore")) \(item.title)")
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .onChange(of: focus) { _, key in
                    if let key, key.hasPrefix("provider:") { proxy.scrollTo(key) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var modelColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading(L("Model"))
            if (provider?.models.count ?? 0) > 10 {
                TextField(L("Find a model"), text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L("Find a model"))
                    .focused($focus, equals: "search")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: ChatPickerLayout.rowSpacing) {
                        ForEach(models) { model in
                            let key = "model:\(model.id)"
                            HStack(spacing: 0) {
                                ChatPickerRow(title: model.displayName, selected: model.id == selectedModel,
                                              focused: keyboardNavigation && focus == key, icon: { EmptyView() }) {
                                    selectedModel = model.id
                                }
                                .focused($focus, equals: key)
                                if provider?.isOsaurusCloud == true {
                                    let saved = favorites.isFavorite(model.favoriteKey)
                                    Button {
                                        favorites.toggle(model.favoriteKey)
                                    } label: {
                                        Image(systemName: saved ? "star.fill" : "star")
                                            .font(.system(size: 13))
                                            .frame(width: 28, height: ChatPickerLayout.rowHeight)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .pointingHandCursor()
                                    .focusable()
                                    .focusEffectDisabled()
                                    .focused($focus, equals: "favorite:\(model.id)")
                                    .overlay {
                                        if keyboardNavigation && focus == "favorite:\(model.id)" {
                                            VStack {
                                                Spacer()
                                                Rectangle().fill(theme.secondaryText).frame(height: 1).padding(.horizontal, 6)
                                            }
                                        }
                                    }
                                    .onKeyPress(.return) { favorites.toggle(model.favoriteKey); return .handled }
                                    .accessibilityLabel("\(saved ? L("Remove from favorites") : L("Add to favorites")): \(model.displayName)")
                                    .help(saved ? L("Remove from favorites") : L("Add to favorites"))
                                }
                            }
                            .id(key)
                            .help(model.displayName)
                        }
                        if models.isEmpty {
                            Text(search.isEmpty ? L("Choose a provider to browse models.") : L("No matching models. Try another name."))
                                .foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 12)
                        }
                        if let provider, provider.isLocal || provider.isOsaurusCloud {
                            footerButton(L("More models"), key: "more", icon: "arrow.forward") {
                                provider.isLocal ? onExploreLocal() : onExploreCloud()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel(provider.isLocal ? L("More local models") : L("More Osaurus Cloud models"))
                            .id("more")
                        }
                    }
                }
                .onAppear {
                    if let selectedModel { proxy.scrollTo("model:\(selectedModel)", anchor: .center) }
                }
                .onChange(of: focus) { _, key in
                    if let key {
                        if key.hasPrefix("model:") || key == "more" { proxy.scrollTo(key) }
                        if key.hasPrefix("favorite:") { proxy.scrollTo("model:" + key.dropFirst(9)) }
                    }
                }
            }
            if hasAdditionalOptions {
                footerButton(L("Model options"), key: "options", icon: "slider.horizontal.3") { showingOptions = true }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func reasoningColumn(_ snapshot: ChatPickerReasoningSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading(L("Reasoning"))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: ChatPickerLayout.rowSpacing) {
                        ForEach(snapshot.rows) { row in
                            let key = "reasoning:\(row.id)"
                            ChatPickerRow(title: row.label,
                                          selected: snapshot.selectedID == row.id,
                                          focused: keyboardNavigation && focus == key, icon: { EmptyView() }) {
                                selectReasoning(row.id, displayedFor: snapshot)
                            }
                            .focused($focus, equals: key)
                            .id(key)
                            .help(row.help)
                        }
                    }
                }
                .onChange(of: focus) { _, key in
                    if let key, key.hasPrefix("reasoning:") { proxy.scrollTo(key) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func selectReasoning(_ rowID: String, displayedFor snapshot: ChatPickerReasoningSnapshot) {
        guard reasoningIsRevealed, let reasoning, let control,
            selectedModel == snapshot.modelID, reasoning.id == snapshot.optionID,
            case .segmented(let segments) = reasoning.kind,
            segments.contains(where: { $0.id == rowID })
        else { return }
        control.onChange(reasoning.id, .string(rowID))
    }

    private func footerButton(_ title: String, key: String, icon: String, action: @escaping () -> Void) -> some View {
        ChatPickerTextLink(title: title, icon: icon, focused: keyboardNavigation && focus == key, action: action)
            .focused($focus, equals: key)
    }

    private func chooseProvider(_ item: ChatModelPickerProvider) {
        guard item.isActive else {
            item.isLocal ? onExploreLocal() : onExploreCloud()
            return
        }
        browsedProviderID = item.id
        search = ""
    }

    @ViewBuilder private func providerIcon(_ provider: ChatModelPickerProvider) -> some View {
        if provider.isLocal {
            Image(systemName: "desktopcomputer").frame(width: 16)
        } else if provider.isOsaurusCloud {
            Image("osaurus-logo", bundle: .module).resizable().renderingMode(.template).scaledToFit().frame(width: 16, height: 16)
        } else {
            let name = provider.title.lowercased()
            if name.contains("openai") || name.contains("chatgpt") {
                Image("provider-logo-openai", bundle: .module).resizable().scaledToFit().frame(width: 16, height: 16)
            } else if name.contains("claude") || name.contains("anthropic") {
                Image("provider-logo-anthropic", bundle: .module).resizable().scaledToFit().frame(width: 16, height: 16)
            } else {
                Image(systemName: "network").frame(width: 16)
            }
        }
    }

    private var focusColumns: [[String]] {
        var modelKeys = models.flatMap { model in
            provider?.isOsaurusCloud == true
                ? ["model:\(model.id)", "favorite:\(model.id)"] : ["model:\(model.id)"]
        }
        if provider?.isLocal == true || provider?.isOsaurusCloud == true { modelKeys.append("more") }
        if hasAdditionalOptions { modelKeys.append("options") }
        var columns = [providers.map { "provider:\($0.id)" }, modelKeys]
        if reasoningIsRevealed, let reasoning, case .segmented(let segments) = reasoning.kind {
            columns.append(segments.map { "reasoning:\($0.id)" })
        }
        return columns
    }

    private func moveFocus(_ direction: MoveCommandDirection) {
        guard !showingOptions, focus != "search" else { return }
        let columns = focusColumns
        let column = columns.firstIndex { $0.contains(focus ?? "") } ?? 0
        let row = columns[column].firstIndex(of: focus ?? "") ?? 0
        let logicalDirection: MoveCommandDirection
        if layoutDirection == .rightToLeft && direction == .left { logicalDirection = .right }
        else if layoutDirection == .rightToLeft && direction == .right { logicalDirection = .left }
        else { logicalDirection = direction }
        switch logicalDirection {
        case .up: if !columns[column].isEmpty { focus = columns[column][max(0, row - 1)] }
        case .down: if !columns[column].isEmpty { focus = columns[column][min(columns[column].count - 1, row + 1)] }
        case .left: focus = columns[max(0, column - 1)].first
        case .right: focus = columns[min(columns.count - 1, column + 1)].first
        default: break
        }
    }
}

/// Quiet inline links follow the last model, with the arrow beside the text.
private struct ChatPickerTextLink: View {
    let title: String
    let icon: String
    let focused: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).underline(hovered)
                Image(systemName: icon).font(.system(size: 11)).accessibilityHidden(true)
            }
            .font(theme.font(size: CGFloat(theme.smallBodySize) - 1, weight: .regular))
            .foregroundStyle(hovered ? theme.primaryText : theme.tertiaryText)
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if focused { Rectangle().fill(theme.secondaryText).frame(height: 1) }
            }
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .focusable()
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .onKeyPress(.return) { action(); return .handled }
    }
}

/// A native button supplies activation and accessibility; focus and hover use
/// the same row shape, with a neutral keyboard underline distinct from selection.
private struct ChatPickerRow<Icon: View>: View {
    let title: String
    let selected: Bool
    var muted = false
    var explore = false
    var focused = false
    @ViewBuilder let icon: () -> Icon
    var trailingSymbol: String? = nil
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon().accessibilityHidden(true)
                Text(title)
                    .font(theme.font(size: CGFloat(theme.smallBodySize)))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if explore && (hovered || focused) {
                    Text("Explore", bundle: .module)
                        .font(theme.font(size: 11))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(theme.primaryBackground, in: Capsule())
                } else if selected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .medium))
                        .accessibilityHidden(true)
                } else if let trailingSymbol {
                    Image(systemName: trailingSymbol).font(.system(size: 11)).accessibilityHidden(true)
                }
            }
            .foregroundStyle(muted && !hovered && !focused ? theme.tertiaryText : theme.primaryText)
            .padding(.horizontal, 12)
            .frame(minHeight: ChatPickerLayout.rowHeight)
            .contentShape(Rectangle())
            .background(selected || hovered || focused ? theme.tertiaryBackground : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if focused {
                    VStack {
                        Spacer()
                        Rectangle().fill(theme.secondaryText).frame(height: 1).padding(.horizontal, 12)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .focusable()
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .onKeyPress(.return) { action(); return .handled }
        .accessibilityValue(selected ? L("Selected") : "")
        .help(title)
    }
}

/// Less common controls stay available without adding permanent columns.
private struct ChatModelOptionsPanel: View {
    let control: ModelPickerOptionsControl
    let onBack: () -> Void
    @Environment(\.theme) private var theme
    @FocusState private var backFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: onBack) { Label(L("Back to models"), systemImage: "chevron.backward") }
                .pointingHandCursor()
                .focused($backFocused)
            Text("Model options", bundle: .module).font(theme.font(size: 16, weight: .medium))
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let thinking = control.thinking {
                        Picker(L("Thinking"), selection: Binding(
                            get: { thinking.isExplicit ? (thinking.isEnabled ? "on" : "off") : "default" },
                            set: { thinking.onSetEnabled($0 == "default" ? nil : $0 == "on") }
                        )) {
                            Text("Default", bundle: .module).tag("default")
                            Text("On", bundle: .module).tag("on")
                            Text("Off", bundle: .module).tag("off")
                        }
                        .pointingHandCursor()
                    }
                    ForEach(control.options) { option in
                        VStack(alignment: .leading, spacing: 6) {
                            switch option.kind {
                            case .segmented(let segments):
                                Picker(option.label, selection: Binding(
                                    get: { control.values[option.id]?.stringValue ?? "__default" },
                                    set: { control.onChange(option.id, $0 == "__default" ? nil : .string($0)) }
                                )) {
                                    Text("Default", bundle: .module).tag("__default")
                                    ForEach(segments) { Text($0.label).tag($0.id) }
                                }
                                .pointingHandCursor()
                            case .toggle:
                                Toggle(option.label, isOn: Binding(
                                    get: { control.effectiveToggleValue(for: option) },
                                    set: { control.onChange(option.id, .bool($0)) }
                                ))
                                .pointingHandCursor()
                                if control.values[option.id] != nil {
                                    Button(L("Reset to default")) { control.onChange(option.id, nil) }
                                        .pointingHandCursor()
                                }
                            }
                            if let help = option.help {
                                Text(help).font(theme.font(size: 12)).foregroundStyle(theme.secondaryText)
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .onAppear { backFocused = true }
    }
}
