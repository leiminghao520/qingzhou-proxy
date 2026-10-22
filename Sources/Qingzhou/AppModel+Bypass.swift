import Foundation
import QingzhouKit

extension AppModel {
    func bypassRevision() throws -> Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        var result=try encoder.encode(state.effectiveBypasses)
        result.append(try encoder.encode(state.rules));result.append(Data((currentProfileID?.uuidString ?? "").utf8))
        return result
    }
    func applyBypassDraft(_ items:[NetworkBypass],converted:Set<UUID>,revision:Data) async -> Bool {
        guard !locked,let store else{return false}
        busy=true;defer{busy=false}
        do {
            guard try bypassRevision()==revision else {throw ProxyError("绕过配置、普通规则或当前配置已变化，请重新载入草稿")}
            var next=state;try next.setBypasses(items)
            for id in converted {
                guard let rule=next.rules.first(where:{$0.id==id}) else {throw ProxyError("待转换规则已变化")}
                let item=try NetworkBypassPolicy.convert(rule)
                guard next.effectiveBypasses.contains(where:{$0.kind==item.kind && $0.value==item.value && $0.enabled}) else {throw ProxyError("转换后的绕过项已被移除，请撤销该转换")}
            }
            next.rules.removeAll{converted.contains($0.id)}
            try await apply(store.prepareChange(next))
            bypassApplyFailure=nil
            return true
        }catch {bypassApplyFailure=error.localizedDescription;report(error);return false}
    }
}
