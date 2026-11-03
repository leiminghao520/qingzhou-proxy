import Foundation
import Darwin

public enum NetworkMonitorEvent: String {
    case routeMessage, queryIgnored, checkRequested, checkExecuted, routeQuery, receiveLimit, receiveFailure
}

// 报文读取与调度分离，离线夹具可注入查询响应和事件风暴，不打开系统路由套接字。
public enum RouteEventPump {
    public enum Read {
        case packet(Data), interrupted, wouldBlock, closed, failed
    }
    public static func receive(_ descriptor: Int32) -> Read {
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = recv(descriptor, &bytes, bytes.count, MSG_DONTWAIT | MSG_TRUNC)
        if count > 0 { return .packet(Data(bytes.prefix(count))) }
        if count == 0 { return .closed }
        if errno == EINTR { return .interrupted }
        if errno == EAGAIN || errno == EWOULDBLOCK { return .wouldBlock }
        return .failed
    }
    public static func requiresCheck(_ packet: Data) -> Bool {
        // 只有版本、长度和完整头部均有效的纯查询响应可以忽略；异常输入保守核验。
        guard packet.count >= 4 else { return true }
        let length = packet.withUnsafeBytes { Int($0.loadUnaligned(as: UInt16.self)) }
        guard length == packet.count, packet[packet.startIndex + 2] == UInt8(RTM_VERSION) else { return true }
        return packet[packet.startIndex + 3] != UInt8(RTM_GET) || packet.count < MemoryLayout<rt_msghdr>.size
    }
    @discardableResult public static func drain(
        read: () -> Read, cancelled: () -> Bool = { false },
        observe: (NetworkMonitorEvent) -> Void = { _ in }, request: () -> Void
    ) -> Bool {
        var changed = false
        defer { if changed && !cancelled() { observe(.checkRequested); request() } }
        // 每次最多接收 64 次，剩余报文由下一次可读通知处理，给定时器和控制请求让出队列。
        for _ in 0..<64 {
            guard !cancelled() else { return false }
            switch read() {
            case .packet(let packet):
                observe(.routeMessage)
                if requiresCheck(packet) { changed = true } else { observe(.queryIgnored) }
            case .interrupted: continue
            case .wouldBlock: return true
            case .closed, .failed:
                observe(.receiveFailure); changed = true
                return false
            }
        }
        observe(.receiveLimit)
        return true
    }
}
