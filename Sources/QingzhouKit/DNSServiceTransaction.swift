import Foundation

public struct DNSServiceRecord:Codable,Equatable,Sendable {
    public var key:String
    public var expected:Data
    public var original:Data?
    public init(key:String,expected:Data,original:Data?) {self.key=key;self.expected=expected;self.original=original}
}

// 写入意图必须先持久化；恢复仅凭记录中的完整值认领服务。
public enum DNSServiceTransaction {
    public static func encode(_ value:NSDictionary) throws -> Data {try PropertyListSerialization.data(fromPropertyList:value,format:.binary,options:0)}
    public static func decode(_ data:Data) throws -> NSDictionary {
        guard let value=try PropertyListSerialization.propertyList(from:data,format:nil) as? NSDictionary else {throw ProxyError("DNS 服务记录无效")}
        return value
    }
    public static func apply(_ records:[DNSServiceRecord],persist:() throws -> Void,read:(String) throws -> NSDictionary?,write:(String,NSDictionary?) throws -> Void) throws {
        try persist()
        for record in records {
            let original=try record.original.map(decode)
            guard try read(record.key)==original else {throw ProxyError("DNS 服务在写入前发生外部修改："+record.key)}
            let expected=try decode(record.expected)
            try write(record.key,expected)
            guard try read(record.key)==expected else {throw ProxyError("DNS 服务写后核验失败："+record.key)}
        }
    }
    public static func restore(_ records:[DNSServiceRecord],read:(String) throws -> NSDictionary?,write:(String,NSDictionary?) throws -> Void)->[String] {
        var issues:[String]=[]
        for record in records.reversed() {
            do {
                let current=try read(record.key),original=try record.original.map(decode)
                if current==original {continue}
                guard current == (try decode(record.expected)) else {
                    issues.append("DNS 服务已有外部修改，保留当前值："+record.key);continue
                }
                try write(record.key,original)
                guard try read(record.key)==original else {throw ProxyError("恢复写后核验失败")}
            } catch {issues.append("DNS 服务恢复失败："+record.key+"；"+error.localizedDescription)}
        }
        return issues
    }
    public static func issues(_ records:[DNSServiceRecord],read:(String) throws -> NSDictionary?)->[String] {
        records.compactMap {record in
            do {return try read(record.key)==decode(record.expected) ? nil:"DNS 服务与事务预期不一致："+record.key}
            catch {return "DNS 服务读取失败："+record.key}
        }
    }
}
