import Foundation
import CoreData

public struct TrafficHistoryRow: Sendable, Identifiable {
    public var id: String {"\(day.timeIntervalSince1970)|\(profileID)|\(nodeID ?? "total")"}
    public let day: Date
    public let profileID: String
    public let nodeID: String?
    public var upload: Int64
    public var download: Int64
    public var incomplete: Bool
    public init(day: Date, profileID: String, nodeID: String? = nil, upload: Int64, download: Int64, incomplete: Bool = false) {
        self.day=day;self.profileID=profileID;self.nodeID=nodeID;self.upload=upload;self.download=download;self.incomplete=incomplete
    }
}

// 累计计数器独立于速率采样；节点统计仅表示轮询观测到的流量。
public struct TrafficHistoryAccumulator {
    private var previous: (Int64,Int64)?
    private var connections: [String:(Int64,Int64)] = [:]
    private var lastDate: Date?
    public init() {}
    public mutating func receive(_ snapshot: ConnectionSnapshot, profileID: UUID, now: Date, calendar: Calendar = .current) -> [TrafficHistoryRow] {
        let up=max(0,snapshot.uploadTotal),down=max(0,snapshot.downloadTotal)
        let reset=previous.map{up<$0.0 || down<$0.1} ?? false
        let gap=lastDate.map{now.timeIntervalSince($0)>10 || !calendar.isDate($0,inSameDayAs:now) || now<$0} ?? false
        let deltaUp=reset ? up:max(0,up-(previous?.0 ?? 0))
        let deltaDown=reset ? down:max(0,down-(previous?.1 ?? 0))
        if reset {connections=[:]}
        let day=calendar.startOfDay(for:now),profile=profileID.uuidString
        var rows=[TrafficHistoryRow(day:day,profileID:profile,upload:deltaUp,download:deltaDown,incomplete:gap || reset)]
        var nodes:[String:(Int64,Int64)]=[:]
        for row in snapshot.connections {
            let u=max(0,row.upload),d=max(0,row.download),old=connections[row.id]
            connections[row.id]=(u,d)
            guard let tag=row.chains.first(where:{$0.hasPrefix("node-")}),UUID(uuidString:String(tag.dropFirst(5))) != nil else {continue}
            let value=nodes[tag] ?? (0,0)
            nodes[tag]=(value.0+max(0,u-(old?.0 ?? 0)),value.1+max(0,d-(old?.1 ?? 0)))
        }
        let active=Set(snapshot.connections.map(\.id));connections=connections.filter{active.contains($0.key)}
        for (node,value) in nodes {rows.append(TrafficHistoryRow(day:day,profileID:profile,nodeID:node,upload:value.0,download:value.1,incomplete:true))}
        previous=(up,down);lastDate=now
        return rows
    }
}

// 模型和数据库独立于代理配置，只在私有队列中查询与提交。
public final class TrafficHistoryStore: @unchecked Sendable {
    private let context: NSManagedObjectContext
    private let coordinator: NSPersistentStoreCoordinator
    public init(url: URL) throws {
        let model=NSManagedObjectModel(),entity=NSEntityDescription()
        entity.name="DailyTraffic";entity.managedObjectClassName="NSManagedObject"
        func attribute(_ name:String,_ type:NSAttributeType,optional:Bool=false)->NSAttributeDescription {
            let value=NSAttributeDescription();value.name=name;value.attributeType=type;value.isOptional=optional;return value
        }
        entity.properties=[attribute("key",.stringAttributeType),attribute("day",.dateAttributeType),attribute("profile",.stringAttributeType),attribute("node",.stringAttributeType,optional:true),attribute("upload",.integer64AttributeType),attribute("download",.integer64AttributeType),attribute("incomplete",.booleanAttributeType)]
        entity.uniquenessConstraints=[["key"]];model.entities=[entity]
        coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        // DELETE 日志避免额外 WAL 文件扩大隐私文件的权限管理范围。
        _=try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:url,options:[NSSQLitePragmasOption:["journal_mode":"DELETE"],NSMigratePersistentStoresAutomaticallyOption:true,NSInferMappingModelAutomaticallyOption:true])
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        context=NSManagedObjectContext(concurrencyType:.privateQueueConcurrencyType)
        context.persistentStoreCoordinator=coordinator
        context.mergePolicy=NSMergeByPropertyObjectTrumpMergePolicy
    }
    public func append(_ rows:[TrafficHistoryRow], now:Date, calendar:Calendar = .current) throws {
        try context.performAndWait {
            do {
                for row in rows {
                    let request=NSFetchRequest<NSManagedObject>(entityName:"DailyTraffic");request.predicate=NSPredicate(format:"key == %@",row.id);request.fetchLimit=1
                    let object=try context.fetch(request).first ?? NSEntityDescription.insertNewObject(forEntityName:"DailyTraffic",into:context)
                    object.setValue(row.id,forKey:"key");object.setValue(row.day,forKey:"day");object.setValue(row.profileID,forKey:"profile");object.setValue(row.nodeID,forKey:"node")
                    object.setValue((object.value(forKey:"upload") as? Int64 ?? 0)+row.upload,forKey:"upload")
                    object.setValue((object.value(forKey:"download") as? Int64 ?? 0)+row.download,forKey:"download")
                    object.setValue((object.value(forKey:"incomplete") as? Bool ?? false) || row.incomplete,forKey:"incomplete")
                }
                let cutoff=calendar.date(byAdding:.day,value:-29,to:calendar.startOfDay(for:now))!
                let old=NSFetchRequest<NSManagedObject>(entityName:"DailyTraffic");old.predicate=NSPredicate(format:"day < %@",cutoff as NSDate)
                for object in try context.fetch(old){context.delete(object)}
                try context.save();context.reset()
            } catch {context.rollback();throw error}
        }
    }
    public func rows() throws -> [TrafficHistoryRow] {
        try context.performAndWait {
            let request=NSFetchRequest<NSManagedObject>(entityName:"DailyTraffic");request.sortDescriptors=[NSSortDescriptor(key:"day",ascending:false)]
            let result=try context.fetch(request).map{object in TrafficHistoryRow(day:object.value(forKey:"day") as! Date,profileID:object.value(forKey:"profile") as! String,nodeID:object.value(forKey:"node") as? String,upload:object.value(forKey:"upload") as? Int64 ?? 0,download:object.value(forKey:"download") as? Int64 ?? 0,incomplete:object.value(forKey:"incomplete") as? Bool ?? false)}
            context.reset();return result
        }
    }
    public func clear() throws {
        try context.performAndWait {
            do {for object in try context.fetch(NSFetchRequest<NSManagedObject>(entityName:"DailyTraffic")){context.delete(object)};try context.save();context.reset()}
            catch {context.rollback();throw error}
        }
    }
}
