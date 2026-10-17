import Foundation
import QingzhouKit

let snapshot=try BackupService.decrypt(Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])),password:"fixture-password")
try snapshot.catalog.validate()
precondition(snapshot.catalog.active.nodes.count==1)
let node=snapshot.catalog.active.nodes[0]
precondition(node.kind == .trojan && snapshot.credentials[node.credentialRef]=="fixture-only")
precondition(snapshot.catalog.active.activePolicy == .node(node.id))
print("SWIFT_BACKUP_INTEROP_PASS")
