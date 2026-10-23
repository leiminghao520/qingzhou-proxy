import Foundation
import QingzhouKit
import Darwin

final class FaultCredentials:CredentialStore {
    let base=MemoryCredentials()
    var failAfter:Int?
    var writes=0
    var created=Set<String>()
    func get(_ ref:String)throws->String {try base.get(ref)}
    func set(_ value:String,for ref:String)throws {writes+=1;if let failAfter,writes>=failAfter {throw ProxyError("注入凭据写入失败")};try base.set(value,for:ref);created.insert(ref)}
    func remove(_ ref:String)throws {try base.remove(ref);created.remove(ref)}
}
@main struct FeatureChecks {
    @MainActor static var count=0
    @MainActor static func check(_ value:Bool,_ message:String)throws {guard value else{throw ProxyError(message)};count+=1;print("PASS "+message)}
    @MainActor static func rejects(_ message:String,_ action:()throws->Void)throws {do{try action()}catch{try check(true,message);return};throw ProxyError("未拒绝："+message)}
    @MainActor static func main() async {
        do {try await run();print("FEATURE_CHECKS_OK assertions=\(count)")}catch{print("FEATURE_CHECKS_FAILED \(error)");exit(1)}
    }
    @MainActor static func run() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("qingzhou-features-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        try await diagnostics()
        try await history(root)
        try events(root)
    }
    @MainActor static func diagnostics() async throws {
        let portFD=socket(AF_INET,SOCK_STREAM,0)
        defer{close(portFD)}
        var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_addr.s_addr=inet_addr("127.0.0.1")
        guard withUnsafePointer(to:&address,{$0.withMemoryRebound(to:sockaddr.self,capacity:1){bind(portFD,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}})==0 else{throw ProxyError("端口夹具绑定失败")}
        var length=socklen_t(MemoryLayout<sockaddr_in>.size)
        _=withUnsafeMutablePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){getsockname(portFD,$0,&length)}}
        var state=AppState();state.listenPort=Int(UInt16(bigEndian:address.sin_port))
        let port=DiagnosticService.local(state:state,corePath:"/missing-fixture",connected:true).first{$0.stage=="监听端口"}
        try check(port?.code=="ownerUnverified" && port?.outcome == .unverified,"其他进程占用端口时已连接状态不证明归属")
        let executor=DiagnosticExecutor(),session=DiagnosticSession(profileID:UUID(),connectionID:UUID(),nodeID:nil)
        let rows=await executor.run(session,jobs:[DiagnosticJob("第一项"){[DiagnosticResult("一","通过","secret.example",code:"ok")]},DiagnosticJob("第二项"){[DiagnosticResult("二","失败","密码",code:"fixtureFailed")]}])
        try check(rows.id==session.id && rows.results.map(\.stage)==["一","二"] && rows.finishedAt != nil,"诊断身份固定且结果按阶段排序")
        let json=String(decoding:try rows.export(json:true),as:UTF8.self)
        try check(!json.contains("secret.example") && !json.contains("密码") && json.contains("fixtureFailed"),"结构化导出只包含脱敏白名单")
        try check(!String(decoding:try rows.export(json:false),as:UTF8.self).contains("secret.example"),"文本导出不包含目标")
        let empty=await executor.run(session,jobs:[])
        try check(empty.results.isEmpty && empty.finishedAt != nil,"空诊断及时结束")
        let timeout=await executor.run(session,jobs:[DiagnosticJob("慢阶段"){try? await Task.sleep(nanoseconds:2_000_000_000);return [DiagnosticResult("迟到","通过","不应发布")]}],timeout:0.02)
        try check(timeout.results.first?.code=="timeout","总超时返回结构化未完成结果")
        let task=Task {await executor.run(session,jobs:[DiagnosticJob("等待取消"){try? await Task.sleep(nanoseconds:2_000_000_000);return []}])}
        task.cancel();let cancelled=await task.value
        try check(cancelled.results.first?.code=="cancelled","启动前取消不会遗漏完成信号")
        let pool=DiagnosticWorkPool(limit:2),gate=DispatchSemaphore(value:0)
        let a=Task {await pool.run(stage:"阻塞一",timeout:0.03){gate.wait();return []}}
        let b=Task {await pool.run(stage:"阻塞二",timeout:0.03){gate.wait();return []}}
        let first=await a.value,second=await b.value
        try check(first.first?.code=="timeout" && second.first?.code=="timeout" && pool.activeCount==2,"两个 DNS 超时后底层调用继续占用槽位")
        let denied=await pool.run(stage:"第三次"){throw ProxyError("不应执行")}
        try check(denied.first?.code=="overloaded" && pool.activeCount==2,"重复诊断不能堆积 DNS 线程")
        gate.signal();gate.signal()
        for _ in 0..<100 where pool.activeCount>0 {try await Task.sleep(nanoseconds:1_000_000)}
        try check(pool.activeCount==0,"底层 DNS 返回后释放槽位")
        let error=await pool.run(stage:"错误"){throw ProxyError("含密钥的错误")}
        try check(error.first?.code=="systemQueryFailed" && !error[0].detail.contains("密钥"),"系统错误结构化并隐藏原始错误")
        let gate2=DispatchSemaphore(value:0)
        let c=Task {await pool.run(stage:"取消同步调用"){gate2.wait();return []}}
        while pool.activeCount==0 {await Task.yield()}
        c.cancel();let result=await c.value
        try check(result.first?.code=="cancelled" && pool.activeCount==1,"取消只终止等待，不提前释放底层槽位")
        gate2.signal()
        for (code,outcome,category) in [("cancelled",DiagnosticOutcome.cancelled,DiagnosticErrorCategory.cancellation),("timeout",.timeout,.timeout),("overloaded",.unverified,.capacity),("configurationInvalid",.failed,.configuration),("httpsFailed",.failed,.network),("ownerUnverified",.unverified,.unverified),("notApplicable",.notApplicable,.none)] {
            let row=DiagnosticResult("阶段",outcome.rawValue,"不应出现在导出中的凭据",code:code)
            try check(!row.exportExplanation.isEmpty && row.errorCategory==category && !row.exportExplanation.contains("凭据"),"诊断类别和说明由结构化状态生成")
        }
        let localDNS=await DiagnosticService.dns("127.0.0.1")
        try check(localDNS.outcome == .passed,"DNS 执行器处理回环字面量，不访问外部网络")
        let token=DiagnosticCancellation();try check(!token.cancelled,"路径取消令牌初始正常");token.cancel();try check(token.cancelled,"路径取消令牌可跨线程读取")
    }
    @MainActor static func history(_ root:URL) async throws {
        let credentials=FaultCredentials(),store=try NodeStore(file:root.appendingPathComponent("state.json"),credentials:credentials)
        let candidate=try NodeParser.parse("trojan://original-secret@fixture.example:443#原节点")
        try store.commit(store.prepareImport([candidate]))
        let originalRef=store.state.nodes[0].credentialRef
        var clock=Date(timeIntervalSince1970:1_800_000_000)
        let history=ProfileHistoryStore(directory:root.appendingPathComponent("history"),credentials:credentials,now:{clock})
        store.history=history;try history.initialize(store.catalog)
        let baseline=try history.versions()[0]
        try check(try history.versions().count==1,"首次加载创建独立基线")
        let files=try FileManager.default.contentsOfDirectory(at:history.directory,includingPropertiesForKeys:nil)
        for url in files {
            let data=try Data(contentsOf:url)
            try check(!String(decoding:data,as:UTF8.self).contains("original-secret"),"历史文件不含明文凭据")
            let mode=(try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as! NSNumber).intValue
            try check(mode==0o600,"历史文件权限为 0600")
        }
        try check((try FileManager.default.attributesOfItem(atPath:history.directory.path)[.posixPermissions] as! NSNumber).intValue==0o700,"历史目录权限为 0700")
        var runtime=store.state;runtime.recentUse[originalRef]=clock
        try store.commit(runtime);try check(try history.versions().count==1,"测速与使用时间不生成历史")
        var newer=candidate;newer.secret="replacement-secret"
        try store.commit(store.prepareImport([newer],replacingID:store.state.nodes[0].id))
        try check((try? credentials.get(originalRef))==nil,"订阅或节点替换后旧凭据可以清理")
        let snapshot=try history.snapshot(baseline)
        try check(snapshot.credentials[originalRef]=="original-secret","旧凭据清理后快照仍可独立恢复")
        let before=try history.versions().count
        let unchanged=store.state.nodes[0]
        var same=candidate;same.node=unchanged;same.secret="replacement-secret"
        try store.commit(store.prepareImport([same],replacingID:unchanged.id))
        try check(try history.versions().count==before,"仅凭据引用重建不重复保存逻辑版本")
        var withSources=snapshot
        var sub=Subscription(name:"订阅历史");var remote=RemoteRuleSource(name:"远程规则历史")
        sub.retryCount=3;remote.retryCount=2
        withSources.profile.configuration.subscriptions=[sub];withSources.profile.configuration.remoteRules=[remote]
        withSources.credentials[sub.sourceRef]="https://subscription.example/private-token"
        withSources.credentials[remote.sourceRef]="https://rules.example/private-token"
        let sourceTX=try store.prepareProfileRestore(withSources)
        try check(!sourceTX.next.subscriptions[0].autoUpdate && !sourceTX.next.remoteRules[0].autoUpdate && sourceTX.next.subscriptions[0].retryCount==0,"恢复暂停订阅及远程规则更新并清除重试")
        try check(try credentials.get(sourceTX.next.subscriptions[0].sourceRef)=="https://subscription.example/private-token","订阅凭据从独立历史内容重新建立")
        store.abort(sourceTX)
        let rollback=try store.prepareProfileRestore(snapshot);var stops=0,restarts=0
        do {try await RuntimeTransaction.apply(rollback,connected:true,validate:{try store.prepareHistory(rollback)},stop:{stops+=1},start:{_ in throw ProxyError("候选启动失败")},commit:{try store.commit(rollback)},abort:{store.abort(rollback)},restartPrevious:{_ in restarts+=1})}catch{}
        try check(stops==2 && restarts==1 && (try credentials.get(store.state.nodes[0].credentialRef))=="replacement-secret","恢复启动失败后沿用事务恢复原运行配置")
        let diff=ProfileHistoryDiff.rows(current:store.catalog.profiles[0],snapshot:snapshot,credentials:credentials)
        try check(diff.contains{$0.contains("凭据：已变化")} && !diff.joined().contains("original-secret"),"差异预览只提示凭据变化而不泄露内容")
        let removed=ProfileHistoryDiff.rows(current:nil,snapshot:snapshot,credentials:credentials)
        try check(removed.contains{$0.contains("恢复为新配置")} && removed.contains{$0.contains("暂停")},"删除配置的恢复预览明确新建与暂停自动更新")
        var changed=snapshot;changed.profile.name="历史名称";changed.profile.configuration.nodes[0].name="不同名称";changed.profile.configuration.listenPort+=1
        changed.profile.configuration.rules.append(RoutingRule(kind:.suffix,value:"example.test",action:.direct))
        changed.profile.configuration.mode = .direct
        let changes=ProfileHistoryDiff.rows(current:store.catalog.profiles[0],snapshot:changed,credentials:credentials)
        try check(changes.contains{$0.contains("规则：")} && changes.contains{$0.contains("网络绕过设置")} && changes.contains{$0.contains("策略")} && changes.contains{$0.contains("节点参数或名称")},"差异预览覆盖节点、规则、策略及网络设置")
        let tx=try store.prepareProfileRestore(snapshot);try store.commit(tx)
        try check(try credentials.get(store.state.nodes[0].credentialRef)=="original-secret","单份历史恢复重新创建必要凭据")
        var catalog=try ProfileStore.create(in:store.catalog,name:"保留配置")
        try store.commit(store.prepareCatalog(catalog))
        let active=store.catalog.currentProfileID,other=store.catalog.profiles.last!
        var otherSnapshot=snapshot;otherSnapshot.profile.id=other.id
        try store.commit(store.prepareProfileRestore(otherSnapshot))
        try check(store.catalog.currentProfileID==active && store.catalog.profiles.count==2 && store.state.nodes[0].id==snapshot.profile.configuration.nodes[0].id,"恢复非当前配置保留当前选择及其他配置")
        var deleted=snapshot;deleted.profile.id=UUID()
        try store.commit(store.prepareProfileRestore(deleted))
        try check(store.catalog.profiles.count==3 && store.catalog.currentProfileID==active && store.catalog.profiles.last!.id != deleted.profile.id,"已删除配置恢复为新配置")
        let createdBefore=credentials.created
        credentials.failAfter=credentials.writes+1
        try rejects("新凭据写入失败不修改配置") {_ = try store.prepareProfileRestore(snapshot)}
        credentials.failAfter=nil
        try check(createdBefore==credentials.created,"恢复凭据失败后临时引用已清理")
        let orphanDirectory=root.appendingPathComponent("orphan-history")
        let orphan=ProfileHistoryStore(directory:orphanDirectory,credentials:credentials)
        orphan.write={data,url in if url.lastPathComponent=="index.qzh" {throw ProxyError("索引失败")};try SecureFile.write(data,to:url,durable:true)}
        for _ in 0..<3 {try rejects("历史基线索引失败不保留孤立快照") {try orphan.initialize(store.catalog)}}
        try check((try FileManager.default.contentsOfDirectory(atPath:orphanDirectory.path)).filter{$0.hasSuffix(".qzh")}.isEmpty,"历史写入重试不会积累孤立快照")
        let failedCandidate=ProfileHistoryStore(directory:root.appendingPathComponent("candidate-history"),credentials:credentials)
        var changedCatalog=store.catalog;changedCatalog.profiles[0].configuration.listenPort+=1
        failedCandidate.write={data,url in if url.lastPathComponent=="index.qzh" {throw ProxyError("索引失败")};try SecureFile.write(data,to:url,durable:true)}
        try rejects("历史准备索引失败清理变更前及候选临时快照") {_ = try failedCandidate.prepare(previous:store.catalog,next:changedCatalog,source:"注入失败")}
        try check((try FileManager.default.contentsOfDirectory(atPath:failedCandidate.directory.path)).filter{$0.hasSuffix(".qzh")}.isEmpty,"失败准备不留下未索引历史")
        history.write={_,_ in throw ProxyError("磁盘失败")}
        var next=store.state;next.listenPort+=1
        let failing=store.prepareChange(next);var stopped=false
        do {try await RuntimeTransaction.apply(failing,connected:true,validate:{try store.prepareHistory(failing)},stop:{stopped=true},start:{_ in},commit:{try store.commit(failing)},abort:{store.abort(failing)})}catch{}
        try check(!stopped && store.state.listenPort != next.listenPort,"历史磁盘失败发生在停止旧连接之前")
        history.write={try SecureFile.write($0,to:$1,durable:true)}
        let beforePending=try history.versions().count
        let pending=store.prepareChange(next);try store.prepareHistory(pending)
        history.write={data,url in if url.lastPathComponent=="index.qzh" {throw ProxyError("收尾失败")};try SecureFile.write(data,to:url,durable:true)}
        try store.commit(pending)
        try check(store.state.listenPort==next.listenPort && history.lastError != nil,"主配置已提交时历史收尾失败不误报回滚")
        history.write={try SecureFile.write($0,to:$1,durable:true)}
        let reloaded=try NodeStore(file:store.file,credentials:credentials)
        try history.reconcile(reloaded.catalog)
        try check(try history.versions().count==beforePending+1,"主配置事务标识确保收尾候选不会被误删")
        try check(!FileManager.default.fileExists(atPath:history.directory.appendingPathComponent("pending.qzh").path),"重启通过主配置事务标识完成收尾对账")
        next.listenPort+=1;let uncommitted=store.prepareChange(next);try store.prepareHistory(uncommitted)
        try history.reconcile(store.catalog)
        try check(!FileManager.default.fileExists(atPath:history.directory.appendingPathComponent("pending.qzh").path),"主配置未提交的候选在重启时撤销")
        store.abort(uncommitted)
        for i in 0..<24 {clock=clock.addingTimeInterval(1);var state=store.state;state.listenPort=30000+i;try store.commit(state)}
        try check(try history.versions().filter{$0.profileID==active}.count<=20,"每份配置最多二十个版本")
        let abandoned=store.prepareChange({var state=store.state;state.listenPort+=1;return state}())
        try store.prepareHistory(abandoned)
        let pendingURL=history.directory.appendingPathComponent("pending.qzh"),pendingData=try Data(contentsOf:pendingURL)
        try store.commit(abandoned);let finalized=try history.versions().count
        try SecureFile.write(pendingData,to:pendingURL)
        try history.reconcile(store.catalog)
        try check(try history.versions().count==finalized,"历史索引已提交但未删除事务文件时对账不重复提交")
        clock=clock.addingTimeInterval(31*86400)
        try history.maintain(store.catalog)
        try check(try history.versions().isEmpty,"超过三十天历史在维护时淘汰")
        var fresh=store.state;fresh.listenPort+=1;try store.commit(fresh)
        let corruptBefore=try history.versions()[0]
        let oldBytes=try Data(contentsOf:history.directory.appendingPathComponent(corruptBefore.id.uuidString+".qzh"))
        try SecureFile.write(Data("corrupt-before".utf8),to:history.directory.appendingPathComponent(corruptBefore.id.uuidString+".qzh"))
        // 损坏历史单独验证；是否作为变更前快照取决于所选版本。
        try rejects("已损坏的历史不能解密") {_ = try history.snapshot(corruptBefore)}
        try SecureFile.write(oldBytes,to:history.directory.appendingPathComponent(corruptBefore.id.uuidString+".qzh"))
        let lost=ProfileHistoryStore(directory:history.directory,credentials:MemoryCredentials())
        try rejects("密钥缺失时拒绝覆盖已有历史") {_ = try lost.versions()}
        let latest=try history.versions()[0],url=history.directory.appendingPathComponent(latest.id.uuidString+".qzh")
        try SecureFile.write(Data("corrupt".utf8),to:url)
        try rejects("快照损坏时拒绝恢复") {_ = try history.snapshot(latest)}
        try history.setEnabled(false);next.listenPort=32100;try store.commit(next)
        try check(store.state.listenPort==32100,"主动关闭历史后允许修复配置")
        try history.clear();try check(try history.versions().isEmpty,"清空历史不修改当前配置")
        try check(try credentials.get(store.state.nodes[0].credentialRef)=="original-secret","清空历史保留当前节点凭据")
        catalog=store.catalog;catalog.lastHistoryTransactionID=nil
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(catalog)) as! [String:Any];object.removeValue(forKey:"lastHistoryTransactionID")
        let legacy=try JSONDecoder().decode(ProfileCatalog.self,from:JSONSerialization.data(withJSONObject:object))
        try check(legacy.lastHistoryTransactionID==nil,"旧配置集合无需历史事务字段")
        let bounded=ProfileHistoryStore(directory:root.appendingPathComponent("bounded"),credentials:credentials,now:{clock},maximumBytes:3000)
        try rejects("预算不足时拒绝关键变更") {try bounded.initialize(store.catalog);var newer=store.catalog;newer.profiles[0].name="新名称";_ = try bounded.prepare(previous:store.catalog,next:newer,source:"容量测试")}
    }
    @MainActor static func events(_ root:URL)throws {
        var clock=Date(timeIntervalSince1970:1_800_000_000)
        let url=root.appendingPathComponent("events.jsonl"),session=UUID()
        let store=try NetworkEventStore(url:url,now:{clock},maximumBytes:4096)
        func event(_ uptime:Double=1,_ sessionID:UUID?=nil)->NetworkEvent {NetworkEvent(sessionID:sessionID ?? session,profileID:nil,category:.network,outcome:.changed,reason:.environmentChanged,time:clock,uptime:uptime)}
        try store.append([event(),event(2)])
        try check(store.records.count==1 && store.records[0].count==2,"同会话连续相同事件合并")
        try store.append([event(32),event(33,UUID())])
        try check(store.records.count==3,"超出三十秒或跨会话不合并")
        try store.append([event(0)])
        try check(store.records.count==4,"重启后单调时钟回退不误合并")
        let reread=try NetworkEventStore(url:url,now:{clock},maximumBytes:4096)
        try check(reread.records.count==4,"事件可重启读取")
        store.write={_,_ in throw ProxyError("注入写入失败")}
        try rejects("事件磁盘失败可见且不污染内存") {try store.append([event(100)])}
        try check(store.records.count==4,"写入失败保留此前事件")
        store.write={try SecureFile.write($0,to:$1)}
        for i in 0..<100 {try store.append([event(Double(i+200),UUID())])}
        try check(try Data(contentsOf:url).count<=4096,"事件磁盘严格限制总容量")
        clock=clock.addingTimeInterval(8*86400);try store.append([event(400)])
        try check(store.records.count==1,"过期七天事件淘汰")
        try check(!String(decoding:try NetworkEventStore.export(store.records,json:true),as:UTF8.self).contains("http"),"事件导出不接受订阅地址或业务目标")
        try check(String(decoding:try NetworkEventStore.export(store.records,json:false),as:UTF8.self).contains("网络"),"事件文本使用中文类别")
        try store.clear();try check(store.records.isEmpty && Data(contentsOf:url).isEmpty,"清空事件同步清空磁盘")
    }
}
