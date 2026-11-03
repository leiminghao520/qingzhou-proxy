import Foundation
import Carbon

final class ShortcutController {
    private var hotkey:EventHotKeyRef?
    private var handler:EventHandlerRef?
    var action:(()->Void)?
    init(){var event=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed));let pointer=Unmanaged.passUnretained(self).toOpaque();InstallEventHandler(GetApplicationEventTarget(),{_,_,context in guard let context else{return noErr};let controller=Unmanaged<ShortcutController>.fromOpaque(context).takeUnretainedValue();DispatchQueue.main.async{controller.action?()};return noErr},1,&event,pointer,&handler)}
    func configure(enabled:Bool,key:UInt32,modifiers:UInt32) throws {
        if let hotkey{UnregisterEventHotKey(hotkey);self.hotkey=nil};guard enabled else{return}
        let id=EventHotKeyID(signature:0x51495A48,id:1);let status=RegisterEventHotKey(key,modifiers,id,GetApplicationEventTarget(),0,&hotkey);guard status==noErr else{throw NSError(domain:"汐航快捷键",code:Int(status),userInfo:[NSLocalizedDescriptionKey:"快捷键已被占用或系统不允许，请换一个组合"])}
    }
    deinit{if let hotkey{UnregisterEventHotKey(hotkey)};if let handler{RemoveEventHandler(handler)}}
}
