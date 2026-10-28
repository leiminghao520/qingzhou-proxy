import SwiftUI
import QingzhouKit

// 页面只维护展示、查询和选择，不接管代理连接的生命周期。
@MainActor final class NodeListViewModel:ObservableObject {
    @Published var query=""
    @Published var sort="HTTPS 延迟"
    @Published var selectedKind:ProxyKind?
    @Published var favoriteOnly=false
    @Published var selection=Set<UUID>()
    struct Key:Equatable {
        let profile:UUID?
        let nodes:[Node]
        let favorites:Set<UUID>
        let notes:[String:String]
        let recent:[String:Date]
        let delays:[String:Int]
        let invalidatedAt:Date
        let query:String
        let sort:String
        let kind:ProxyKind?
        let favoriteOnly:Bool
        let simple:Bool
    }
    let projection=ListProjection<Key,[Node]>()
    private var expiryTask:Task<Void,Never>?
    private var nextExpiry:Date?
    func nodes(state:AppState,invalidatedAt:Date,now:Date,profile:UUID?=nil,simple:Bool=false)->[Node] {
        let delays=state.latency.mapValues{LatencyPresentation.sortValue($0,invalidatedAt:invalidatedAt,now:now)}
        let key=Key(profile:profile,nodes:state.nodes,favorites:state.favorites,notes:state.notes,recent:state.recentUse,delays:delays,invalidatedAt:invalidatedAt,query:query,sort:sort,kind:selectedKind,favoriteOnly:favoriteOnly,simple:simple)
        scheduleExpiry(state:state,invalidatedAt:invalidatedAt,now:now)
        return projection.resolve(key) {
            state.nodes.filter {node in
                let fields=simple ? [node.name,state.notes[node.id.uuidString] ?? ""]:[node.name,node.server,node.kind.rawValue,state.notes[node.id.uuidString] ?? ""]
                return (!favoriteOnly || state.favorites.contains(node.id)) &&
                    (selectedKind==nil || node.kind==selectedKind) &&
                    (query.isEmpty || fields.contains{$0.localizedCaseInsensitiveContains(query)})
            }.sorted {a,b in
                let fa=state.favorites.contains(a.id),fb=state.favorites.contains(b.id)
                if fa != fb {return fa}
                if sort=="HTTPS 延迟" {
                    let av=delays[a.id.uuidString] ?? Int.max,bv=delays[b.id.uuidString] ?? Int.max
                    if av != bv {return av<bv}
                }
                if sort=="最近使用" {
                    let av=state.recentUse[a.id.uuidString] ?? .distantPast,bv=state.recentUse[b.id.uuidString] ?? .distantPast
                    if av != bv {return av>bv}
                }
                if sort=="协议",a.kind != b.kind {return a.kind.rawValue<b.kind.rawValue}
                if a.name != b.name {return a.name.localizedStandardCompare(b.name) == .orderedAscending}
                return a.id.uuidString<b.id.uuidString
            }
        }
    }
    private func scheduleExpiry(state:AppState,invalidatedAt:Date,now:Date) {
        let next=state.latency.values.filter{LatencyPresentation.current($0,invalidatedAt:invalidatedAt,now:now)}.map{$0.testedAt.addingTimeInterval(300.001)}.min()
        guard next != nextExpiry else{return}
        expiryTask?.cancel();nextExpiry=next
        guard let next else{return}
        expiryTask=Task {[weak self] in
            do {try await Task.sleep(nanoseconds:UInt64(max(0.001,next.timeIntervalSinceNow)*1_000_000_000))}catch{return}
            guard let self else{return};self.nextExpiry=nil;self.objectWillChange.send()
        }
    }
    func clearFilters() {query="";selectedKind=nil;favoriteOnly=false}
    deinit {expiryTask?.cancel()}
}
