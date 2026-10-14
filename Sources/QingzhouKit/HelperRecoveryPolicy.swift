import Foundation

public enum HelperRecoveryPolicy {
    public static func requiresRecovery(activeTunnel:Bool,running:Bool,journalPresent:Bool,inspectionAvailable:Bool)->Bool {
        activeTunnel || running || journalPresent || !inspectionAvailable
    }
    public static func inspect()->(journalPresent:Bool,available:Bool) {
        let root=URL(fileURLWithPath:HelperPaths.directory)
        var isDirectory:ObjCBool=false
        guard FileManager.default.fileExists(atPath:root.path,isDirectory:&isDirectory) else{return (false,true)}
        guard isDirectory.boolValue,let items=try? FileManager.default.contentsOfDirectory(atPath:root.path) else{return (false,false)}
        return (items.contains("recovery.json"),true)
    }
}
