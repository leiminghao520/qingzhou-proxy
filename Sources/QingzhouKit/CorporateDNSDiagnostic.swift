import Foundation

public enum CorporateDNSOutcome:String,Codable,Sendable {
    case answered,noRecords,nxdomain,servfail,refused,timeout,resolverUnavailable,resolverAmbiguous,answerProtectionFailed,staleResponse,invalidResponse
    public var label:String {
        switch self {
        case .answered:return "解析成功"
        case .noRecords:return "无此类型记录（不影响另一地址族）"
        case .nxdomain:return "NXDOMAIN：域名不存在"
        case .servfail:return "SERVFAIL：解析器处理失败"
        case .refused:return "解析器拒绝查询"
        case .timeout:return "解析超时"
        case .resolverUnavailable:return "企业解析器或接口不可用"
        case .resolverAmbiguous:return "企业解析器歧义"
        case .answerProtectionFailed:return "答案保护失败"
        case .staleResponse:return "旧代次响应已撤销"
        case .invalidResponse:return "DNS 响应无效"
        }
    }
}
public struct CorporateDNSDiagnostic:Codable,Sendable {
    public var name:String
    public var queryType:UInt16
    public var outcome:CorporateDNSOutcome
    public var server:String?
    public var interface:String?
    public var addresses:[String]
    public var stage:String
    public var summary:String {name+" "+(queryType==1 ? "A":queryType==28 ? "AAAA":String(queryType))+"："+outcome.label+"；阶段 "+stage+"；解析器 "+(server ?? "未选择")+" / "+(interface ?? "未确认")+(addresses.isEmpty ? "":"；答案 "+addresses.joined(separator:","))}
    public var result:DiagnosticResult {
        DiagnosticResult("企业 DNS",[CorporateDNSOutcome.answered,.noRecords].contains(outcome) ? "通过":"失败",summary,code:"corporateDNS."+outcome.rawValue)
    }
}
