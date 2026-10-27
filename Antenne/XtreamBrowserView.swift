import AntenneCore
import SwiftUI

/// Un compte Xtream : Direct, Films et Séries, chaque catégorie chargée quand on l'ouvre.
struct XtreamBrowserView: View {
    @Environment(PlaylistStore.self) private var store
    let playlist: Playlist
    @Binding var selection: DetailItem?
    @State private var model: XtreamBrowserModel
    @State private var searchText = ""

    init(playlist: Playlist, client: XtreamClient, selection: Binding<DetailItem?>) {
        self.playlist = playlist
        _selection = selection
        _model = State(initialValue: XtreamBrowserModel(client: client))
    }

    var body: some View {
        List(selection: $selection) {
            if let account = model.account {
                Section { AccountSummary(account: account) }
            }

            switch model.categories[model.kind] ?? .idle {
            case .idle, .loading:
                LoadingRow(text: "Chargement des catégories…")
            case .failed(let message):
                FailureRow(message: message) { Task { await model.loadCategories(force: true) } }
            case .loaded(let categories):
                let visible = filtered(categories)
                ForEach(visible) { category in
                    DisclosureGroup(isExpanded: expansion(for: category)) {
                        items(in: category)
                    } label: {
                        Text(category.name)
                            #if os(macOS)
                            // Sur Mac, seul le triangle ouvre le groupe : le nom doit aussi le faire.
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { expansion(for: category).wrappedValue.toggle() }
                            #endif
                    }
                }
                if categories.isEmpty {
                    Text("Aucune catégorie dans cette rubrique.").foregroundStyle(.secondary)
                } else if visible.isEmpty {
                    Text("Aucune catégorie ni titre ouvert ne correspond.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(playlist.name)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Rubrique", selection: $model.kind) {
                    Text("Direct").tag(XtreamContentKind.live)
                    Text("Films").tag(XtreamContentKind.movies)
                    Text("Séries").tag(XtreamContentKind.series)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        .searchable(text: $searchText, prompt: "Catégorie ou titre ouvert")
        .refreshable { await model.reload() }
        .task(id: model.kind) { await model.loadCategories() }
        .task { await model.loadAccount() }
        .onChange(of: playlist.updatedAt) {
            // « Actualiser » depuis la barre latérale a vidé le cache du compte.
            Task { await model.reload() }
        }
    }

    @ViewBuilder
    private func items(in category: XtreamCategory) -> some View {
        switch model.items[model.key(category)] ?? .idle {
        case .idle, .loading:
            LoadingRow(text: "Chargement…")
        case .failed(let message):
            FailureRow(message: message) { Task { await model.loadItems(in: category, force: true) } }
        case .loaded(let items):
            let visible = query.isEmpty ? items : items.filter { $0.name.localizedStandardContains(query) }
            ForEach(visible) { item in
                switch item {
                case .channel(let channel):
                    NavigationLink(value: DetailItem.channel(channel)) {
                        ChannelRow(channel: channel, isFavorite: store.isFavorite(channel))
                    }
                    .contextMenu { FavoriteButton(channel: channel) }
                case .series(let series):
                    NavigationLink(value: DetailItem.series(series, playlistID: playlist.id)) {
                        SeriesRow(series: series)
                    }
                }
            }
            if items.isEmpty {
                Text("Catégorie vide.").foregroundStyle(.secondary)
            }
        }
    }

    private var query: String { searchText.trimmingCharacters(in: .whitespaces) }

    /// Une catégorie reste visible si son nom correspond, ou si elle est ouverte et contient un titre qui correspond.
    private func filtered(_ categories: [XtreamCategory]) -> [XtreamCategory] {
        guard !query.isEmpty else { return categories }
        return categories.filter { category in
            if category.name.localizedStandardContains(query) { return true }
            guard case .loaded(let items) = model.items[model.key(category)] else { return false }
            return items.contains { $0.name.localizedStandardContains(query) }
        }
    }

    private func expansion(for category: XtreamCategory) -> Binding<Bool> {
        Binding(
            get: { model.expanded.contains(model.key(category)) },
            set: { model.setExpanded($0, category: category) }
        )
    }
}

// MARK: Modèle

enum XtreamItem: Identifiable {
    case channel(Channel)
    case series(XtreamSeries)

    var id: String {
        switch self {
        case .channel(let channel): channel.id.uuidString
        case .series(let series): "series-\(series.id)"
        }
    }

    var name: String {
        switch self {
        case .channel(let channel): channel.name
        case .series(let series): series.name
        }
    }
}

/// SwiftUI annule la tâche d'une vue qui disparaît, même un instant (fermeture d'une feuille, navigation) :
/// une tâche à part laisse le chargement aller au bout et remplir le modèle.
func uncancellable<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await Task { try await work() }.value
}

enum LoadState<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)
}

@MainActor
@Observable
final class XtreamBrowserModel {
    let client: XtreamClient
    var kind: XtreamContentKind = .live
    private(set) var account: XtreamAccountInfo?
    private(set) var categories: [XtreamContentKind: LoadState<[XtreamCategory]>] = [:]
    private(set) var items: [String: LoadState<[XtreamItem]>] = [:]
    private(set) var expanded: Set<String> = []

    init(client: XtreamClient) {
        self.client = client
    }

    func key(_ category: XtreamCategory) -> String { "\(kind.rawValue)|\(category.id)" }

    func loadAccount() async {
        let client = client
        account = try? await uncancellable { try await client.accountInfo() }
    }

    func loadCategories(force: Bool = false) async {
        let kind = kind
        if !force, case .loaded = categories[kind] { return }
        categories[kind] = .loading
        do {
            let client = client
            categories[kind] = .loaded(try await uncancellable { try await client.categories(kind, forceRefresh: force) })
        } catch {
            categories[kind] = .failed(error.localizedDescription)
        }
    }

    func setExpanded(_ isExpanded: Bool, category: XtreamCategory) {
        let key = key(category)
        if isExpanded {
            expanded.insert(key)
            Task { await loadItems(in: category) }
        } else {
            expanded.remove(key)
        }
    }

    func loadItems(in category: XtreamCategory, force: Bool = false) async {
        let kind = kind
        let key = key(category)
        if !force {
            switch items[key] {
            case .loaded, .loading: return
            default: break
            }
        }
        items[key] = .loading
        do {
            let client = client
            let loaded: [XtreamItem] = try await uncancellable {
                kind == .series
                    ? try await client.series(in: category, forceRefresh: force).map(XtreamItem.series)
                    : try await client.channels(kind, in: category, forceRefresh: force).map(XtreamItem.channel)
            }
            items[key] = .loaded(loaded)
        } catch {
            items[key] = .failed(error.localizedDescription)
        }
    }

    /// Recharge la rubrique affichée et ses catégories ouvertes, sans passer par le cache.
    func reload() async {
        let kind = kind
        let open = expanded.filter { $0.hasPrefix("\(kind.rawValue)|") }
        items = items.filter { !$0.key.hasPrefix("\(kind.rawValue)|") }
        await loadCategories(force: true)
        let client = client
        account = try? await uncancellable { try await client.accountInfo(forceRefresh: true) }
        guard case .loaded(let categories) = categories[kind] else { return }
        for category in categories where open.contains(key(category)) {
            await loadItems(in: category, force: true)
        }
    }
}

// MARK: Lignes

private struct AccountSummary: View {
    let account: XtreamAccountInfo

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(account.isActive ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        var parts = [account.isActive ? (account.isTrial ? "Essai actif" : "Actif") : "Statut : \(account.status)"]
        if let expiresAt = account.expiresAt {
            parts.append("expire le \(expiresAt.formatted(.dateTime.day().month().hour().minute()))")
        }
        if let max = account.maxConnections {
            parts.append("\(max) connexion\(max > 1 ? "s" : "") à la fois")
        }
        return parts.joined(separator: " · ")
    }
}

private struct SeriesRow: View {
    let series: XtreamSeries

    var body: some View {
        HStack(spacing: 12) {
            ChannelLogo(url: series.coverURL, name: series.name)
                .frame(width: 36, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(series.name)
                    .lineLimit(2)
                if let details {
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var details: String? {
        let parts = [series.releaseDate.map { String($0.prefix(4)) }, series.genre].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct LoadingRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

private struct FailureRow: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            Button("Réessayer", action: retry)
                .buttonStyle(.borderless)
        }
    }
}
