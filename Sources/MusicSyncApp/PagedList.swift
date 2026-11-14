import Observation
import SwiftUI

/// A window over a long list. Pages load when a row of theirs is first shown; the least recently
/// shown pages are dropped, so memory stays flat however far the list scrolls.
@MainActor @Observable
final class PagedList<Item: Sendable> {
    typealias Loader = @Sendable (_ offset: Int, _ limit: Int) async throws -> [Item]

    /// Rows to show: the total when known, else the rows found so far plus one page while more may follow.
    private(set) var count: Int
    private(set) var error: String?
    private var pages: [Int: [Item]] = [:]
    @ObservationIgnored private var total: Int?
    @ObservationIgnored private var loading: Set<Int> = []
    /// Page numbers, least recently shown first.
    @ObservationIgnored private var recent: [Int] = []
    @ObservationIgnored private let load: Loader
    let pageSize: Int
    private let maxPages: Int

    init(total: Int?, pageSize: Int = 200, maxPages: Int = 8, load: @escaping Loader) {
        self.total = total
        count = total ?? pageSize
        self.pageSize = pageSize
        self.maxPages = maxPages
        self.load = load
    }

    /// Row `index`; nil while its page loads (the load starts here).
    func item(at index: Int) -> Item? {
        let page = index / pageSize
        guard let items = pages[page] else {
            if !loading.contains(page) { Task { await self.load(page: page) } }
            return nil
        }
        touch(page)
        let i = index % pageSize
        return i < items.count ? items[i] : nil
    }

    /// Rows read straight from the source (for a play queue); they do not enter the window.
    func items(offset: Int, limit: Int) async -> [Item] { (try? await load(offset, limit)) ?? [] }

    func load(page: Int) async {
        guard pages[page] == nil, loading.insert(page).inserted else { return }
        defer { loading.remove(page) }
        do {
            let items = try await load(page * pageSize, pageSize)
            pages[page] = items
            error = nil
            if total == nil {
                count = items.count == pageSize ? max(count, (page + 2) * pageSize) : page * pageSize + items.count
                if items.count < pageSize { total = count }
            }
            touch(page)
            while recent.count > maxPages { pages[recent.removeFirst()] = nil }
        } catch where !error.isCancellation {
            self.error = error.localizedDescription
            if total == nil, pages.isEmpty { count = 0 }
        } catch {}
    }

    private func touch(_ page: Int) {
        guard recent.last != page else { return }
        recent.removeAll { $0 == page }
        recent.append(page)
    }
}

/// Row `index` of `list`, or `placeholder` while its page loads. Each row tracks only its own data.
struct PagedRow<Item: Sendable, Content: View, Placeholder: View>: View {
    let list: PagedList<Item>
    let index: Int
    @ViewBuilder var content: (Item) -> Content
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View {
        if let item = list.item(at: index) { content(item) } else { placeholder() }
    }
}
