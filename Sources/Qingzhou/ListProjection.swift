import SwiftUI
import QingzhouKit

// 缓存只接收页面依赖的值，不把速率、日志等遥测纳入失效条件。
@MainActor final class ListProjection<Key:Equatable,Value> {
    private var key:Key?
    private var value:Value?
    private(set) var computations=0
    func resolve(_ key:Key,build:()->Value)->Value {
        if self.key==key,let value {return value}
        let result=build();self.key=key;value=result;computations+=1;return result
    }
}

@MainActor final class ConnectionListModel:ObservableObject {
    @Published var query="" {didSet{if oldValue != query {limit=1000}}}
    @Published var network="全部" {didSet{if oldValue != network {limit=1000}}}
    @Published var order="流量" {didSet{if oldValue != order {limit=1000}}}
    @Published private(set) var limit=1000
    struct Key:Equatable {
        let connections:[CoreConnection]
        let labels:[String:String]
        let query:String
        let network:String
        let order:String
    }
    let projection=ListProjection<Key,[CoreConnection]>()
    func rows(_ connections:[CoreConnection],labels:[String:String])->[CoreConnection] {
        projection.resolve(Key(connections:connections,labels:labels,query:query,network:network,order:order)) {
            connections.filter {row in
                (network=="全部" || row.metadata.network?.uppercased()==network) &&
                (query.isEmpty || row.target.localizedCaseInsensitiveContains(query) ||
                 (row.metadata.processPath ?? "").localizedCaseInsensitiveContains(query) ||
                 row.chains.contains{(labels[$0] ?? $0).localizedCaseInsensitiveContains(query)})
            }.sorted {a,b in
                if order=="目标" {return a.target.localizedStandardCompare(b.target) == .orderedAscending}
                if order=="持续时间" {return a.start<b.start}
                return a.upload+a.download>b.upload+b.download
            }
        }
    }
    func loadMore() {limit+=1000}
    func clearFilters() {query="";network="全部"}
}
