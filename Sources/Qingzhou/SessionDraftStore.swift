import SwiftUI
import AppKit
import QingzhouKit

@MainActor protocol SessionDraft:AnyObject {
    var dirty:Bool {get}
    func discard()
}

struct NetworkSettingsDraft:Equatable {
    var capture:CaptureMode
    var dns:DNSPreference
    var family:AddressFamilyPolicy
    var http:Bool
    init(_ state:AppState) {capture=state.captureMode;dns=state.dnsPreference;family=state.effectiveAddressFamilyPolicy;http=state.httpCompatibilityEnabled}
}
struct ShortcutSettingsDraft:Equatable {
    var key:UInt32
    var modifiers:UInt32
    init(_ state:AppState) {key=state.shortcutKey;modifiers=state.shortcutModifiers}
}
@MainActor final class SettingsDraft:ObservableObject,SessionDraft {
    @Published var network:NetworkSettingsDraft
    @Published var port:String
    @Published var shortcut:ShortcutSettingsDraft
    private(set) var baseNetwork:NetworkSettingsDraft
    private(set) var basePort:String
    private(set) var baseShortcut:ShortcutSettingsDraft
    private var latest:AppState
    init(_ state:AppState) {
        latest=state;network=NetworkSettingsDraft(state);baseNetwork=NetworkSettingsDraft(state)
        port=String(state.listenPort);basePort=String(state.listenPort);shortcut=ShortcutSettingsDraft(state);baseShortcut=ShortcutSettingsDraft(state)
    }
    var dirty:Bool {network != baseNetwork || port != basePort || shortcut != baseShortcut}
    var networkConflict:Bool {network != baseNetwork && baseNetwork != NetworkSettingsDraft(latest)}
    var portConflict:Bool {port != basePort && basePort != String(latest.listenPort)}
    var shortcutConflict:Bool {shortcut != baseShortcut && baseShortcut != ShortcutSettingsDraft(latest)}
    func sync(_ state:AppState) {
        latest=state
        if network==baseNetwork {acceptNetwork(state)}
        if port==basePort {acceptPort(state)}
        if shortcut==baseShortcut {acceptShortcut(state)}
        objectWillChange.send()
    }
    func acceptNetwork(_ state:AppState) {baseNetwork=NetworkSettingsDraft(state);network=baseNetwork}
    func acceptPort(_ state:AppState) {basePort=String(state.listenPort);port=basePort}
    func acceptShortcut(_ state:AppState) {baseShortcut=ShortcutSettingsDraft(state);shortcut=baseShortcut}
    func discard() {acceptNetwork(latest);acceptPort(latest);acceptShortcut(latest)}
}

@MainActor final class RulesDraft:ObservableObject,SessionDraft {
    @Published var rules:[RoutingRule]?
    @Published var final:PolicyReference?
    @Published var text:String?
    @Published var input=""
    @Published var kind=RuleKind.domain
    @Published var target=PolicyReference.selected
    var revision:Data?
    var textBaseline:String?
    var dirty:Bool {rules != nil || text != textBaseline || !input.isEmpty}
    func begin(state:AppState,revision:Data?) {
        guard rules==nil else{return}
        rules=state.rules;final=state.ruleFinal ?? .selected;self.revision=self.revision ?? revision
    }
    func discardText() {text=nil;textBaseline=nil;if rules==nil {revision=nil}}
    func discard() {rules=nil;final=nil;revision=nil;discardText();input=""}
}

@MainActor final class BypassDraft:ObservableObject,SessionDraft {
    @Published var items:[NetworkBypass]
    @Published var converted=Set<UUID>()
    private(set) var original:[NetworkBypass]
    var revision:Data?
    private var latest:[NetworkBypass]
    private var latestRevision:Data?
    init(items:[NetworkBypass],revision:Data?) {self.items=items;original=items;latest=items;self.revision=revision;latestRevision=revision}
    var dirty:Bool {items != original || !converted.isEmpty}
    func sync(items:[NetworkBypass],revision:Data?) {
        latest=items;latestRevision=revision
        if !dirty {discard()}
    }
    func discard() {
        if dirty || items != latest {objectWillChange.send()}
        original=latest;revision=latestRevision
        if items != latest {items=latest}
        if !converted.isEmpty {converted=[]}
    }
    func accept(items:[NetworkBypass],revision:Data?) {latest=items;latestRevision=revision;discard()}
}

@MainActor final class EditorValueDraft<Value:Equatable>:ObservableObject,SessionDraft {
    @Published var value:Value
    private let original:Value
    init(_ value:Value) {self.value=value;original=value}
    var dirty:Bool {value != original}
    func discard() {value=original}
}

@MainActor final class SavedTargetsDraft:ObservableObject,SessionDraft {
    @Published var values:[SavedDiagnosticTarget]
    let profileID:UUID?
    private var original:[SavedDiagnosticTarget]
    var revision:Data?
    init(_ values:[SavedDiagnosticTarget],profileID:UUID?=nil) {self.profileID=profileID;self.values=values;original=values;revision=try? SavedDiagnosticTarget.revision(values)}
    var dirty:Bool {values != original}
    func accept(_ values:[SavedDiagnosticTarget]) {if self.values != values {self.values=values};original=values;revision=try? SavedDiagnosticTarget.revision(values)}
    func discard() {values=original}
}

// 仅驻留内存；页面销毁不会丢草稿，也不会触发配置保存或网络操作。
@MainActor final class SessionDraftStore {
    private enum Key:Hashable {case unconfigured,profile(UUID)}
    private func key(_ profile:UUID?)->Key {profile.map(Key.profile) ?? .unconfigured}
    private var targetEntries:[Key:SavedTargetsDraft]=[:]
    func targets(profile:UUID?,state:AppState)->SavedTargetsDraft {
        let key=key(profile),values=state.savedDiagnosticTargets ?? []
        if let draft=targetEntries[key] {if !draft.dirty {draft.accept(values)};return draft}
        let draft=SavedTargetsDraft(values,profileID:profile);targetEntries[key]=draft;return draft
    }
    private var settingsEntries:[Key:SettingsDraft]=[:]
    private var ruleEntries:[Key:RulesDraft]=[:]
    private var bypassEntries:[Key:BypassDraft]=[:]
    private var editors:[UUID:(UUID?,any SessionDraft)]=[:]
    func registerEditor(_ id:UUID,profile:UUID?,draft:any SessionDraft) {editors[id]=(profile,draft)}
    func unregisterEditor(_ id:UUID) {editors.removeValue(forKey:id)}
    var confirmDiscard:((String)->Bool)?
    func settings(profile:UUID?,state:AppState)->SettingsDraft {
        let key=key(profile)
        if let value=settingsEntries[key] {return value}
        let value=SettingsDraft(state);settingsEntries[key]=value;return value
    }
    func rules(profile:UUID?)->RulesDraft {
        let key=key(profile)
        if let value=ruleEntries[key] {return value}
        let value=RulesDraft();ruleEntries[key]=value;return value
    }
    func bypass(profile:UUID?,items:[NetworkBypass],revision:Data?)->BypassDraft {
        let key=key(profile)
        if let value=bypassEntries[key] {return value}
        let value=BypassDraft(items:items,revision:revision);bypassEntries[key]=value;return value
    }
    private func entries(profile:UUID?,all:Bool)->[any SessionDraft] {
        if all {return targetEntries.values.map{$0 as any SessionDraft}+editors.values.map{$0.1}+settingsEntries.values.map{$0 as any SessionDraft}+ruleEntries.values.map{$0 as any SessionDraft}+bypassEntries.values.map{$0 as any SessionDraft}}
        let key=key(profile)
        return editors.values.filter{$0.0==profile}.map{$0.1}+[targetEntries[key] as (any SessionDraft)?,settingsEntries[key] as (any SessionDraft)?,ruleEntries[key] as (any SessionDraft)?,bypassEntries[key] as (any SessionDraft)?].compactMap{$0}
    }
    func hasDirty(profile:UUID?=nil,all:Bool=false)->Bool {entries(profile:profile,all:all).contains{$0.dirty}}
    func allowLeaving(_ action:String,profile:UUID?=nil,all:Bool=false)->Bool {
        let pending=entries(profile:profile,all:all).filter{$0.dirty}
        guard !pending.isEmpty else{return true}
        guard confirm(action) else{return false}
        pending.forEach{$0.discard()};return true
    }
    func confirm(_ action:String)->Bool {
        if let confirmDiscard {return confirmDiscard(action)}
        let alert=NSAlert();alert.messageText="尚有未应用的草稿"
        alert.informativeText="\(action)将放弃相关更改。草稿不会自动应用，当前连接不会因取消而改变。"
        alert.addButton(withTitle:"继续编辑");alert.addButton(withTitle:"放弃更改并继续")
        return alert.runModal() == .alertSecondButtonReturn
    }
}
