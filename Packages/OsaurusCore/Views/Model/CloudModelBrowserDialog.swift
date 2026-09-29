//
//  CloudModelBrowserDialog.swift
//  osaurus
//
//  The live Osaurus Cloud catalog. Favorites use the same store as the
//  compact chat picker; choosing a model does not dismiss this dialog.
//

import SwiftUI

struct CloudModelBrowserDialog: View {
    let options: [ModelPickerItem]
    @Binding var selectedModel: String?
    let onDismiss: () -> Void
    let onManageCloud: () -> Void

    @Environment(\.theme) private var theme
    @ObservedObject private var providerManager = RemoteProviderManager.shared
    @ObservedObject private var favoritesStore = FavoriteModelsStore.shared
    @State private var searchText = ""
    @State private var sortOrder: ModelPickerSortOrder = .default
    @State private var contextFilter: ModelPickerContextFilter = .any
    @State private var visionFilter: ModelPickerVisionFilter = .any
    @State private var isRefreshing = false
    @State private var refreshFailed = false
    @FocusState private var isSearchFocused: Bool

    private var providerState: RemoteProviderState? {
        providerManager.providerStates[RemoteProviderManager.osaurusRouterProviderId]
    }

    private var catalog: [ModelPickerItem] {
        options.filter { item in
            guard case .remote(_, let providerID) = item.source else { return false }
            return providerID == RemoteProviderManager.osaurusRouterProviderId && item.isMLXFormat
        }
        .sorted { $0.displayName < $1.displayName }
    }

    private var results: [ModelPickerItem] {
        catalog
            .filter { $0.matches(searchQuery: searchText) }
            .filteredByContext(contextFilter)
            .filteredByVision(visionFilter)
            .sortedByPrice(sortOrder)
    }

    private var canBrowse: Bool {
        providerManager.isOsaurusRouterEnabled && !providerManager.isOffline && !catalog.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if canBrowse {
                searchAndFilters
                if refreshFailed {
                    Text("Couldn't refresh. Showing the last available catalog.", bundle: .module)
                        .font(theme.font(size: CGFloat(theme.captionSize)))
                        .foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }
                Divider()
                if results.isEmpty {
                    searchEmptyState
                } else {
                    modelList
                }
            } else {
                catalogStatus
            }
            Divider()
            footer
        }
        .frame(minWidth: 540, idealWidth: 640, maxWidth: 760, minHeight: 440, idealHeight: 600, maxHeight: 720)
        .background(theme.primaryBackground)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onExitCommand(perform: onDismiss)
        .task {
            isSearchFocused = canBrowse
            await refreshCatalog()
        }
        .onChange(of: canBrowse) { _, ready in
            if ready { isSearchFocused = true }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Osaurus Cloud", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.headingSize), weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text("Select a model to use it now. Star it to keep it in your list.", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.captionSize)))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Text("Close", bundle: .module)
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    private var searchAndFilters: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Search", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                TextField(L("Model name or provider"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .font(theme.font(size: CGFloat(theme.bodySize)))
                    .accessibilityLabel(Text("Search Cloud models", bundle: .module))
                    .focused($isSearchFocused)
            }
            HStack(spacing: 16) {
                Picker(selection: $sortOrder) {
                    Text("Default", bundle: .module).tag(ModelPickerSortOrder.default)
                    Text("Cheapest first", bundle: .module).tag(ModelPickerSortOrder.priceLowToHigh)
                    Text("Highest price first", bundle: .module).tag(ModelPickerSortOrder.priceHighToLow)
                } label: {
                    Text("Price", bundle: .module)
                }
                Picker(selection: $contextFilter) {
                    ForEach(ModelPickerContextFilter.allCases) { filter in
                        Text(LocalizedStringKey(filter.label), bundle: .module).tag(filter)
                    }
                } label: {
                    Text("Context", bundle: .module)
                }
                Picker(selection: $visionFilter) {
                    ForEach(ModelPickerVisionFilter.allCases) { filter in
                        Text(LocalizedStringKey(filter.label), bundle: .module).tag(filter)
                    }
                } label: {
                    Text("Vision", bundle: .module)
                }
            }
            .pickerStyle(.menu)
            .font(theme.font(size: CGFloat(theme.captionSize)))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var modelList: some View {
        List(selection: $selectedModel) {
            ForEach(results) { model in
                modelRow(model)
                    .tag(model.id)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .accessibilityLabel(Text("Cloud models", bundle: .module))
    }

    private func modelRow(_ model: ModelPickerItem) -> some View {
        let isFavorite = favoritesStore.isFavorite(model.favoriteKey)
        let favoriteActionLabel =
            isFavorite
            ? Text("Remove \(model.displayName) from favorites", bundle: .module)
            : Text("Add \(model.displayName) to favorites", bundle: .module)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "checkmark")
                .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
                .frame(width: 16)
                .opacity(selectedModel == model.id ? 1 : 0)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(model.displayName)
                        .font(theme.font(size: CGFloat(theme.bodySize), weight: .medium))
                        .lineLimit(1)
                    if let media = model.mediaModel {
                        mediaKindLabel(media.kind)
                            .font(theme.font(size: CGFloat(theme.captionSize)))
                    } else if model.isVLM {
                        Label {
                            Text("Vision", bundle: .module)
                        } icon: {
                            Image(systemName: "eye")
                        }
                        .font(theme.font(size: CGFloat(theme.captionSize)))
                    }
                }
                if let description = modelDetails(model), !description.isEmpty {
                    Text(description)
                        .font(theme.font(size: CGFloat(theme.captionSize)))
                        .lineLimit(2)
                }
                if let metadata = modelMetadata(model) {
                    Text(metadata)
                        .font(theme.font(size: CGFloat(theme.captionSize)))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Let native List selection supply its contrasting label colors.
            .help([model.displayName, modelDetails(model), modelMetadata(model), model.id].compactMap { $0 }.joined(separator: "\n"))
            Button {
                favoritesStore.toggle(model.favoriteKey)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .focusable()
            .accessibilityLabel(favoriteActionLabel)
            .accessibilityValue(isFavorite ? L("Saved") : L("Not saved"))
            .help(isFavorite ? L("Remove from favorites") : L("Add to favorites"))
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.displayName)
        .accessibilityAction(named: favoriteActionLabel) {
            favoritesStore.toggle(model.favoriteKey)
        }
    }

    @ViewBuilder
    private func mediaKindLabel(_ kind: MediaGenerationKind) -> some View {
        switch kind {
        case .image:
            Label { Text("Image", bundle: .module) } icon: { Image(systemName: "photo") }
        case .textToVideo:
            Label { Text("Text → Video", bundle: .module) } icon: { Image(systemName: "film") }
        case .imageToVideo:
            Label { Text("Image → Video", bundle: .module) } icon: { Image(systemName: "photo.on.rectangle") }
        }
    }

    private func modelDetails(_ model: ModelPickerItem) -> String? {
        if let media = model.mediaModel {
            return ModelPickerView.mediaDetails(media)
        }
        // Router descriptions already include provider, input/output pricing,
        // and context. Preserve those server-provided values verbatim.
        if let description = model.description, !description.isEmpty { return description }
        return model.contextLength.flatMap(OsaurusRouterModel.formatContextLength).map { "\($0) ctx" }
    }

    private func modelMetadata(_ model: ModelPickerItem) -> String? {
        var parts = [model.parameterCount, model.quantization].compactMap { $0 }
        if let media = model.mediaModel {
            if let privacy = media.privacy, !privacy.isEmpty {
                parts.append(ModelPickerView.mediaPrivacyLabel(privacy))
            }
            if let minimum = media.pricing?.minimumUSD {
                let price = OsaurusRouter.formatUSDAsCredits(minimum)
                parts.append(String(localized: "From \(price)", bundle: .module))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var searchEmptyState: some View {
        VStack(spacing: 12) {
            Text("No models match", bundle: .module)
                .font(theme.font(size: CGFloat(theme.bodySize), weight: .semibold))
            Text("Try another search or clear your filters.", bundle: .module)
                .font(theme.font(size: CGFloat(theme.captionSize)))
                .foregroundStyle(theme.secondaryText)
            Button {
                searchText = ""
                contextFilter = .any
                visionFilter = .any
                isSearchFocused = true
            } label: {
                Text("Clear search and filters", bundle: .module)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var catalogStatus: some View {
        VStack(spacing: 12) {
            if !providerManager.isOsaurusRouterEnabled {
                statusText("Osaurus Cloud is off", detail: "Open Credits to enable Osaurus Cloud.")
            } else if providerManager.isOffline {
                statusText("You're offline", detail: "Connect to the internet to browse Cloud models.")
            } else if isRefreshing || providerState?.isConnecting == true {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Loading Cloud models", bundle: .module))
                statusText("Loading Cloud models…", detail: "The catalog will appear when the connection is ready.")
            } else if refreshFailed || providerState?.lastError != nil {
                statusText("Couldn't load Cloud models", detail: "Try again, or open Credits to review your Cloud settings.")
                retryButton
            } else if !OsaurusIdentity.existsCached() {
                statusText("Set up Osaurus Cloud", detail: "Open Credits to set up your Cloud account.")
            } else {
                statusText("No Cloud models available", detail: "Refresh the catalog, or open Credits to review your Cloud settings.")
                retryButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func statusText(_ title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            Text(title, bundle: .module)
                .font(theme.font(size: CGFloat(theme.bodySize), weight: .semibold))
                .foregroundStyle(theme.primaryText)
            Text(detail, bundle: .module)
                .font(theme.font(size: CGFloat(theme.captionSize)))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var retryButton: some View {
        Button {
            Task { await refreshCatalog() }
        } label: {
            Text("Try again", bundle: .module)
        }
        .buttonStyle(.bordered)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button(action: onManageCloud) {
                Text("Manage Cloud in Credits", bundle: .module)
            }
            .buttonStyle(.bordered)
            Spacer()
            if canBrowse {
                Group {
                    if results.count == 1 {
                        Text("1 model", bundle: .module)
                    } else {
                        Text("\(results.count) models", bundle: .module)
                    }
                }
                .font(theme.font(size: CGFloat(theme.captionSize)))
                .foregroundStyle(theme.secondaryText)
                .monospacedDigit()
                Button {
                    Task { await refreshCatalog() }
                } label: {
                    Label {
                        Text("Refresh", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshing)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func refreshCatalog() async {
        guard !isRefreshing, providerManager.isOsaurusRouterEnabled,
            !providerManager.isOffline, OsaurusIdentity.existsCached()
        else { return }
        isRefreshing = true
        refreshFailed = false
        defer { isRefreshing = false }
        if providerState?.isConnected == true {
            let refreshed = await providerManager.refetchModels(
                providerId: RemoteProviderManager.osaurusRouterProviderId
            )
            refreshFailed = !refreshed
        } else {
            await providerManager.connectOsaurusRouterIfPossible()
            refreshFailed = providerState?.isConnected != true
        }
        await ModelPickerItemCache.shared.buildModelPickerItems()
    }
}
