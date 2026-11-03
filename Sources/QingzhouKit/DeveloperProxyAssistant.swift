import Foundation

public struct DeveloperProxyCommands:Sendable {
    public let enable:String
    public let disable:String
    public let gitOnce:String
    public let gitRepository:String
    public let maven:String
    public let bypass:String
    public init(port:Int,domains:[String]) throws {
        guard (1024...65535).contains(port) else {throw ProxyError("本地监听端口无效")}
        let normalized=try ProtectedDomainPolicy.normalize(domains)
        let hosts=["localhost","127.0.0.1","::1"]+normalized.flatMap{[$0,"."+$0]}
        bypass=hosts.joined(separator:",")
        let http="http://127.0.0.1:\(port)",socks="socks5h://127.0.0.1:\(port)"
        enable="export http_proxy='\(http)' https_proxy='\(http)' all_proxy='\(socks)' HTTP_PROXY='\(http)' HTTPS_PROXY='\(http)' ALL_PROXY='\(socks)' no_proxy='\(bypass)' NO_PROXY='\(bypass)'"
        disable="unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY"
        gitOnce="NO_PROXY='\(bypass)' no_proxy='\(bypass)' git -c http.proxy='\(http)' ls-remote '<仓库地址>'"
        gitRepository="git config --local http.proxy '\(http)'\n# 取消当前仓库代理\ngit config --local --unset-all http.proxy\n# 内网仓库建议使用上述单次命令或单独取消仓库代理；Git 配置不持久保存 NO_PROXY。"
        let mavenHosts=(["localhost","127.0.0.1","[::1]"]+normalized.flatMap{[$0,"*."+$0]}).joined(separator:"|")
        maven="""
        <!-- 合并到 settings.xml 已有的 proxies 中；不要覆盖其他设置。 -->
        <proxy>
          <id>qingzhou-local</id>
          <active>true</active>
          <protocol>http</protocol>
          <host>127.0.0.1</host>
          <port>\(port)</port>
          <nonProxyHosts>\(mavenHosts)</nonProxyHosts>
        </proxy>
        """
    }
}

public enum DeveloperToolInspector {
    // 只报告是否存在配置，不输出地址、账号、环境变量值或文件原文。
    public static func environment(_ values:[String:String])->[String] {
        let keys=["http_proxy","https_proxy","all_proxy","HTTP_PROXY","HTTPS_PROXY","ALL_PROXY","no_proxy","NO_PROXY"]
        let present=keys.filter{values[$0]?.isEmpty==false}
        return [present.isEmpty ? "应用进程未继承代理环境变量":"应用进程存在代理相关变量："+present.joined(separator:", "),"图形应用环境不能代表已打开终端的环境；请在目标终端核对。"]
    }
    public static func configuration(_ data:Data,kind:String)->[String] {
        guard data.count<=2*1024*1024,let text=String(data:data,encoding:.utf8) else {return ["配置过大或不是 UTF-8，未解析"]}
        if kind=="maven" {
            let hasProxy=text.range(of:"<proxy>",options:.caseInsensitive) != nil
            let hasBypass=text.range(of:"<nonProxyHosts>",options:.caseInsensitive) != nil
            return [hasProxy ? "检测到 Maven proxy 配置":"未检测到 Maven proxy 配置",hasBypass ? "检测到 Maven 绕过列表，请按工具语法核对":"未检测到 Maven 绕过列表","这是静态文本检查，未证明配置已被 Maven 加载。"]
        }
        var section="",hasProxy=false
        for line in text.components(separatedBy:.newlines) {
            let value=line.trimmingCharacters(in:.whitespaces).lowercased()
            if value.hasPrefix("[") {section=value}
            if section.hasPrefix("[http"),value.split(separator:"=",maxSplits:1).first?.trimmingCharacters(in:.whitespaces)=="proxy" {hasProxy=true}
        }
        return [hasProxy ? "检测到 Git HTTP 代理配置":"未检测到 Git HTTP 代理配置","仅检查所选文件，Git include、系统配置及命令行覆盖需另行核对。"]
    }
}
