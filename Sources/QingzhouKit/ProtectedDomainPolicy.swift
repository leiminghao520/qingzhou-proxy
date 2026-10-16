import Foundation

public enum ProtectedDomainPolicy {
    public static let tongdunDomains = ["tongdun.me", "tongdun.cn", "tongdun.net"]

    public static func missingTongdunDomains(in domains:[String]) throws -> [String] {
        let normalized=try normalize(domains)
        guard normalized.contains(where:{tongdunDomains.contains($0)}) else {return []}
        return tongdunDomains.filter{!normalized.contains($0)}
    }

    public static func completingTongdunDomains(_ domains:[String]) throws -> [String] {
        try normalize(domains+tongdunDomains)
    }

    public static func normalize(_ domains:[String]) throws -> [String] {
        var result:[String]=[]
        for raw in domains {
            var domain=raw.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
            if domain.hasSuffix(".") {domain.removeLast()}
            guard !domain.isEmpty,domain.utf8.count<=253,domain.contains("."),domain.split(separator:".",omittingEmptySubsequences:false).allSatisfy({label in
                !label.isEmpty && label.utf8.count<=63 && label.first != "-" && label.last != "-" && label.utf8.allSatisfy{(97...122).contains($0) || (48...57).contains($0) || $0==45}
            }),domain.contains(where:{$0.isLetter}) else {throw ProxyError("企业保护项必须是域名，不能包含 URL、端口、路径或通配符："+raw)}
            if !result.contains(domain) {result.append(domain)}
        }
        guard result.count<=100 else {throw ProxyError("企业保护域名超过 100 个")}
        return result
    }
    public static func exceptions(_ domains:[String]) throws -> [String] {
        try normalize(domains).flatMap{[$0,"*."+$0]}
    }
}
