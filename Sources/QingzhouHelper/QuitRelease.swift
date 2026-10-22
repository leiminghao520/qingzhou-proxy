import Foundation
import SystemConfiguration
import QingzhouKit

extension Service {
    func verifyReleasedForQuit()->Bool {
        guard process?.isRunning != true,activeRequest==nil,networkResumeSession==nil,networkResumeWork==nil else{return false}
        guard let record=journal else{return true}
        guard record.firewall==nil else{return false}
        do {
            try verifyNoOwnedProxyEndpoint(record.proxies ?? [])
            guard let expected=try PropertyListSerialization.propertyList(from:record.expectedDNS,format:nil) as? NSDictionary else{return false}
            let current:NSDictionary?
            if let read=quitDNSRead {current=read(record.dnsKey)}
            else if let value=SCDynamicStoreCopyValue(dynamic,record.dnsKey as CFString) {
                guard let dictionary=value as? NSDictionary else{return false}
                current=dictionary
            } else {
                guard SCError()==kSCStatusNoKey else{return false}
                current=nil
            }
            if let current,current==expected {return false}
            let actual=try quitRoutesRead?() ?? routeSample().ownershipRoutes
            return record.routes.allSatisfy {route in
                let state=CaptureOwnership.recoveryState(expected:ProtectedRoute(destination:route.destination,gateway:route.gateway,interface:route.interface,scope:route.scope),actual:actual)
                return state == .absent || state == .replaced
            }
        } catch {return false}
    }
}
