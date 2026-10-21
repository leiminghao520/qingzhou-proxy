import SwiftUI
import QingzhouKit

// 页面只维护查询和选择，不接管代理连接的生命周期。
@MainActor final class NodeListViewModel:ObservableObject {
    @Published var query=""
    @Published var sort="HTTPS 延迟"
    @Published var selectedKind:ProxyKind?
    @Published var favoriteOnly=false
    @Published var selection=Set<UUID>()
    func nodes(state:AppState,invalidatedAt:Date,now:Date)->[Node] {
        state.nodes.filter { node in
            (!favoriteOnly || state.favorites.contains(node.id)) &&
            (selectedKind == nil || node.kind == selectedKind) &&
            (query.isEmpty || [node.name, node.server, node.kind.rawValue, state.notes[node.id.uuidString] ?? ""].contains { $0.localizedCaseInsensitiveContains(query) })
        }
        .sorted { a, b in
            let fa = state.favorites.contains(a.id), fb = state.favorites.contains(b.id)
            if fa != fb { return fa }
            if sort == "HTTPS 延迟" {
                let av = LatencyPresentation.sortValue(state.latency[a.id.uuidString],invalidatedAt:invalidatedAt,now:now)
                let bv = LatencyPresentation.sortValue(state.latency[b.id.uuidString],invalidatedAt:invalidatedAt,now:now)
                if av != bv { return av < bv }
            }
            if sort == "最近使用" {
                let av = state.recentUse[a.id.uuidString] ?? .distantPast
                let bv = state.recentUse[b.id.uuidString] ?? .distantPast
                if av != bv { return av > bv }
            }
            if sort == "协议", a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            if a.name != b.name { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return a.id.uuidString < b.id.uuidString
        }
    }

}
