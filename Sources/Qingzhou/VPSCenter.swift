import Foundation
import SwiftUI
import AppKit
import CryptoKit
import Security
import QingzhouKit

@MainActor final class VPSCenter: ObservableObject {
    struct Binding: Codable {var endpoint:String;var subscription:UUID;var tokenRef:String;var recoveryRef:String?;var recoveryExported:Bool?}
    @Published var binding:Binding?
    @Published var endpoint:URL?
    @Published var owner=false
    @Published var busy=false
    @Published var error:String?
    @Published var notices:[String]=[]
    @Published var me:VPSValue = .null
    @Published var status:VPSValue = .null
    @Published var usage:VPSValue = .null
    @Published var devices:VPSValue = .null
    @Published var billing:VPSValue = .null
    @Published var backup:VPSValue = .null
    @Published var backupMessage="未同步"
    @Published var speedMessage="手动测试，每方向最多 8 MiB、五秒；测试计入流量"
    @Published var speedRunning=false
    var speedTask:Task<Void,Never>?
    private var background:Task<Void,Never>?
    private var syncing=false
    private let credentials=UnifiedCredentialStore.native
    private let directory:URL
    private let refreshEnabled:Bool
    init(directory:URL?=nil,refreshEnabled:Bool=true) {
        self.directory=directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Qingzhou/VPS")
        self.refreshEnabled=refreshEnabled
        binding=(try? Data(contentsOf:self.directory.appendingPathComponent("binding.json"))).flatMap{try? JSONDecoder().decode(Binding.self,from:$0)}
        guard refreshEnabled else{return}
        background=Task{[weak self] in
            while !Task.isCancelled {
                if let self,self.binding?.recoveryExported==true {await CredentialAuthorization.$allowsInteraction.withValue(false) {await self.syncBackup()}}
                try? await Task.sleep(for:.seconds(300))
            }
        }
    }
    private func save() throws {if let binding {try SecureFile.write(JSONEncoder().encode(binding),to:directory.appendingPathComponent("binding.json"))}}
    private func client() throws -> VPSClient {
        guard let b=binding,let url=URL(string:b.endpoint) else{throw ProxyError("请先配对 VPS")}
        return try VPSClient(base:url,token:credentials.get(b.tokenRef))
    }
    func discover(_ sub:Subscription, model:AppModel) async {
        guard !busy else{return};busy=true;error=nil;defer{busy=false}
        do {
            guard let source=URL(string:try model.credentials.get(sub.sourceRef)) else{throw ProxyError("订阅地址无效")}
            let response=try await ExternalDownloadClient.shared.fetchResponse(source,limit:2*1024*1024)
            endpoint=try VPSClient.endpoint(subscription:source,advertised:response.clientAPI)
        }catch{self.error="无法发现联动能力，请确认订阅来自已升级的 VPS"}
    }
    func pair(code:String,subscription:UUID) async {
        guard !busy,let endpoint else{return};busy=true;error=nil;defer{busy=false}
        do {
            let result=try await VPSClient(base:endpoint).pair(code:code)
            guard let token=result["token"].string else{throw ProxyError("配对响应无效")}
            let ref="vps-access-"+UUID().uuidString
            try credentials.set(token,for:ref)
            let old=binding;binding=Binding(endpoint:endpoint.absoluteString,subscription:subscription,tokenRef:ref)
            do{try save()}catch{binding=old;try? credentials.remove(ref);throw error}
            // 配对替换只删除旧的访问令牌，恢复密钥保留在钥匙串中供人工恢复。
            if let old {try? credentials.remove(old.tokenRef)}
        }catch{self.error=error.localizedDescription}
        busy=false
        if binding != nil {await refresh()}
    }
    func unlink() {
        speedTask?.cancel()
        if let b=binding {try? credentials.remove(b.tokenRef)}
        binding=nil;endpoint=nil;owner=false;error=nil;notices=[];status = .null;usage = .null;devices = .null;billing = .null;backup = .null
        try? FileManager.default.removeItem(at:directory.appendingPathComponent("binding.json"))
    }
    func refresh() async {
        guard refreshEnabled,!busy,binding != nil else{return};busy=true;error=nil;notices=[];defer{busy=false}
        let original=binding?.tokenRef
        do {
            let c=try client(),identity=try await c.json("me")
            let isOwner=identity["owner"].bool==true
            let newUsage=try await c.json("usage"),newDevices=try await c.json("devices")
            var newStatus:VPSValue = .null,newBilling:VPSValue = .null,newBackup:VPSValue = .null
            var failures:[String]=[]
            if isOwner {
                do{newStatus=try await c.json("status")}catch{failures.append("服务器状态暂不可用")}
                do{newBilling=try await c.json("billing")}catch{failures.append("云账单暂不可用")}
                do{newBackup=try await c.json("backup")}catch{failures.append("备份索引暂不可用")}
            }
            try Task.checkCancellation()
            guard binding?.tokenRef==original else{return}
            me=identity;owner=isOwner;usage=newUsage;devices=newDevices
            status=newStatus;billing=newBilling;backup=newBackup;notices=failures;updateAlerts()
        }catch is CancellationError {}catch{if binding?.tokenRef==original {self.error=error.localizedDescription;owner=false;me = .null;status = .null;billing = .null;usage = .null;devices = .null;backup = .null}}
    }
    func adminURL() -> URL? {
        guard let text=me["admin_url"].string,let url=URL(string:text),url.scheme=="https",url.user==nil,url.password==nil else{return nil};return url
    }
    private func updateAlerts() {
        guard billing["state"].string=="fresh" else{return}
        for p in billing["data"]["packages"].array {
            guard let total=p["total_gb"].number,total>0,let remaining=p["remaining_gb"].number,remaining>=0,remaining<=total,
                  let id=p["id"].string,let cycle=p["cycle"].string else{continue}
            let percent=(total-remaining)/total*100
            for threshold in [80,90,100] where percent>=Double(threshold) {
                let key="vps-quota-\(id)-\(cycle)-\(threshold)"
                if !UserDefaults.standard.bool(forKey:key) {notices.append("共享流量包已达到 \(threshold)%（云厂商口径）");UserDefaults.standard.set(true,forKey:key)}
            }
        }
    }
    func startSpeed(model:AppModel) {
        guard !speedRunning,!model.locked,!model.networkRechecking,!model.networkReconnecting,model.connection == .connected,
              let b=binding,let actual=CoreAPIClient.actualTag(model.proxyInfo),
              let node=model.state.nodes.first(where:{PolicyReference.node($0.id).tag==actual}),node.subscriptionID==b.subscription else {
            speedMessage="请先连接此 VPS 的订阅节点，网络重配置期间不能测速";return
        }
        speedRunning=true;speedMessage="正在测试，可随时取消"
        let epoch=model.epoch,port=model.state.listenPort,baseline=model.latencyInvalidatedAt
        speedTask=Task{[weak self,weak model] in
            guard let self,let model else{return};defer{self.speedRunning=false}
            do {
                let c=try self.client()
                // 在现有核心连接表中确认本次测试经过绑定节点；无法确认时不输出误导性的带宽。
                guard let api=model.api,let host=c.base.host else{throw ProxyError("核心连接证据不可用")}
                let begun=Date();let observed=Task { () -> Bool in
                    while !Task.isCancelled {
                        if let snapshot=try? await api.connections(),VPSDiagnostics.confirmsPath(snapshot.connections,host:host,nodeTag:actual,since:begun) {return true}
                        do{try await Task.sleep(for:.milliseconds(100))}catch{return false}
                    }
                    return false
                }
                defer{observed.cancel()}
                let start=ContinuousClock.now
                let (down,_)=try await c.request("speed/download",limit:8*1024*1024,proxyPort:port,timeout:5)
                let downSeconds=max(0.001,Double(start.duration(to:.now).components.seconds)+Double(start.duration(to:.now).components.attoseconds)/1e18)
                try Task.checkCancellation()
                guard model.epoch==epoch,model.connection == .connected,!model.networkRechecking,model.latencyInvalidatedAt==baseline else{throw CancellationError()}
                var up=Data(count:8*1024*1024)
                let randomStatus=up.withUnsafeMutableBytes{SecRandomCopyBytes(kSecRandomDefault,$0.count,$0.baseAddress!)}
                guard randomStatus==errSecSuccess else{throw ProxyError("测速数据生成失败")}
                let second=ContinuousClock.now
                let (reply,_)=try await c.request("speed/upload",method:"POST",body:up,limit:1024,proxyPort:port,timeout:5)
                let response=try JSONDecoder().decode(VPSValue.self,from:reply)
                guard response["bytes"].number==Double(up.count) else{throw ProxyError("上传结果不完整")}
                let upSeconds=max(0.001,Double(second.duration(to:.now).components.seconds)+Double(second.duration(to:.now).components.attoseconds)/1e18)
                guard model.epoch==epoch,model.connection == .connected,model.latencyInvalidatedAt==baseline else{throw CancellationError()}
                observed.cancel()
                guard await observed.value else{throw ProxyError("未能确认测试经过绑定节点，已传输流量计入用量，本次不显示带宽")}
                self.speedMessage=String(format:"下载 %.2f Mbps · 上传 %.2f Mbps · 实际传输 %.1f MiB",Double(down.count)*8/downSeconds/1e6,Double(up.count)*8/upSeconds/1e6,Double(down.count+up.count)/1048576)
            }catch is CancellationError {self.speedMessage="测试已取消，已传输部分仍计入流量"}
            catch {self.speedMessage=error.localizedDescription+"；未完成测试的传输也可能计入流量"}
        }
    }
    func cancelSpeed(){speedTask?.cancel()}
    func generateRecovery() throws -> String {
        guard var b=binding else{throw ProxyError("请先配对")}
        if let ref=b.recoveryRef {return try credentials.get(ref)}
        guard let tool=Bundle.main.url(forResource:"age-keygen",withExtension:nil) else{throw ProxyError("当前应用未包含备份密钥工具")}
        let p=Process();p.executableURL=tool;p.arguments=[];let output=Pipe();p.standardOutput=output;p.standardError=FileHandle.nullDevice
        try p.run();let data=output.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
        let secret=String(decoding:data,as:UTF8.self)
        guard p.terminationStatus==0,secret.contains("AGE-SECRET-KEY-") else{throw ProxyError("恢复密钥生成失败")}
        let ref="vps-recovery-"+UUID().uuidString;try credentials.set(secret,for:ref);b.recoveryRef=ref;binding=b;try save();return secret
    }
    func exportRecovery(password:String) throws {
        guard password.count>=12 else{throw ProxyError("恢复口令至少十二个字符")}
        let secret=try generateRecovery();let panel=NSSavePanel();panel.nameFieldStringValue="汐航VPS恢复密钥.qzvpskey"
        guard panel.runModal() == .OK,let url=panel.url else{throw CancellationError()}
        try SecureFile.write(BackupService.encryptRecoveryKey(secret,password:password),to:url)
        binding?.recoveryExported=true;try save()
    }
    func importRecovery(password:String) throws {
        guard var b=binding else{throw ProxyError("请先配对")}
        let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else{throw CancellationError()}
        let input=try FileHandle(forReadingFrom:url);defer{try? input.close()}
        let secret=try BackupService.decryptRecoveryKey(try input.read(upToCount:16384) ?? Data(),password:password)
        let ref="vps-recovery-"+UUID().uuidString;try credentials.set(secret,for:ref)
        b.recoveryRef=ref;b.recoveryExported=true;binding=b;try save()
    }
    func verifyBackup() async {
        do {
            guard let ref=binding?.recoveryRef,let tool=Bundle.main.url(forResource:"age",withExtension:nil) else{throw ProxyError("缺少备份恢复密钥或验证工具")}
            let files=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).filter{Self.isBackupName($0.lastPathComponent)}.sorted{$0.lastPathComponent>$1.lastPathComponent}
            guard let input=files.first else{throw ProxyError("请先同步备份")}
            let secret=try credentials.get(ref)
            backupMessage="正在隔离验证备份，不恢复服务器配置"
            let message=try await Task.detached(priority:.utility) {
                let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                defer{try? FileManager.default.removeItem(at:folder)}
                let raw=folder.appendingPathComponent("backup.tar")
                let process=Process();process.executableURL=tool;process.arguments=["-d","-i","/dev/stdin","-o",raw.path,input.path]
                let pipe=Pipe();process.standardInput=pipe;process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
                try process.run();try pipe.fileHandleForWriting.write(contentsOf:Data(secret.utf8));try pipe.fileHandleForWriting.close();process.waitUntilExit()
                guard process.terminationStatus==0 else{throw ProxyError("备份解密验证失败")}
                let tar=Process();tar.executableURL=URL(fileURLWithPath:"/usr/bin/tar");tar.arguments=["-tf",raw.path]
                let list=Pipe();tar.standardOutput=list;tar.standardError=FileHandle.nullDevice;try tar.run()
                let data=list.fileHandleForReading.readDataToEndOfFile();tar.waitUntilExit()
                let entries=String(decoding:data,as:UTF8.self).split(separator:"\n")
                guard tar.terminationStatus==0,entries.contains("database.sqlite3"),entries.allSatisfy({!$0.hasPrefix("/") && !$0.split(separator:"/").contains("..")}) else{throw ProxyError("备份归档验证失败")}
                return "备份解密及归档验证通过；未恢复或修改服务器"
            }.value
            backupMessage=message
        }catch{backupMessage=error.localizedDescription}
    }
    func enableBackup() async {
        do {
            guard binding?.recoveryExported==true else{throw ProxyError("请先导出口令保护的恢复密钥")}
            let secret=try generateRecovery()
            guard let recipient=secret.split(separator:"\n").first(where:{$0.hasPrefix("# public key: ")}).map({String($0.dropFirst(14))}) else{throw ProxyError("恢复公钥无效")}
            _=try await client().json("backup/recipient",method:"POST",value:["recipient":recipient])
            backupMessage="自动备份已启用，等待每日任务生成首份备份";await refresh()
        }catch{self.error=error.localizedDescription}
    }
    func syncBackup() async {
        guard binding?.recoveryExported==true,!syncing else{return}
        syncing=true;defer{syncing=false};let original=binding?.tokenRef
        do {
            let c=try client(),index=try await c.json("backup")
            guard binding?.tokenRef==original else{return};backup=index
            let m=index["latest"]
            guard let name=m["name"].string,let sha=m["sha256"].string,let size=m["size"].number,
                  name.range(of:"^backup-[0-9]{8}T[0-9]{6}Z\\.tar\\.age$",options:.regularExpression) != nil,
                  size>0,size<=512*1024*1024,size.rounded(.towardZero)==size else {backupMessage="尚无可同步备份";return}
            let target=directory.appendingPathComponent(name)
            if (try? Self.fileHash(target))==sha {backupMessage="已同步："+name;return}
            // 临时下载校验后原子写入；不会导入或恢复服务器配置。
            try await c.downloadBackup(to:target,size:Int(size),sha256:sha)
            guard binding?.tokenRef==original else{return}
            backupMessage="已同步："+name
            let files=(try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)).filter{Self.isBackupName($0.lastPathComponent)}.sorted{$0.lastPathComponent>$1.lastPathComponent}
            var keep=Set(files.prefix(7));var weeks=Set<String>()
            let parser=DateFormatter();parser.dateFormat="yyyyMMdd";parser.locale=Locale(identifier:"en_US_POSIX");parser.timeZone=TimeZone(secondsFromGMT:0)
            var calendar=Calendar(identifier:.iso8601);calendar.timeZone=TimeZone(secondsFromGMT:0)!
            for file in files {
                guard let d=parser.date(from:String(file.lastPathComponent.dropFirst(7).prefix(8))) else{continue}
                let parts=calendar.dateComponents([.yearForWeekOfYear,.weekOfYear],from:d),week="\(parts.yearForWeekOfYear ?? 0)-\(parts.weekOfYear ?? 0)"
                if !weeks.contains(week),weeks.count<4 {keep.insert(file);weeks.insert(week)}
            }
            for old in files where !keep.contains(old){try? FileManager.default.removeItem(at:old)}
        }catch{backupMessage="备份待同步；连接恢复后自动重试"}
    }
    static func isBackupName(_ name:String)->Bool {name.range(of:"^backup-[0-9]{8}T[0-9]{6}Z\\.tar\\.age$",options:.regularExpression) != nil}
    private static func fileHash(_ file:URL) throws -> String {
        let handle=try FileHandle(forReadingFrom:file);defer{try? handle.close()};var hasher=SHA256()
        while let chunk=try handle.read(upToCount:65536),!chunk.isEmpty {hasher.update(data:chunk)}
        return hasher.finalize().map{String(format:"%02x",$0)}.joined()
    }
    static func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    func openBackups(){NSWorkspace.shared.open(directory)}
}
