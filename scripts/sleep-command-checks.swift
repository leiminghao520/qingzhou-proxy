import Foundation
import QingzhouKit

@main struct SleepCommandChecks {
    static var assertions = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError(message) }
    }
    static func main() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let ordinary = NetworkCommandBudget(deadline: nil, uptime: 100)
        check(ordinary.remaining(wallTime: start, uptime: 100) == 10, "命令初始预算十秒")
        check(ordinary.remaining(wallTime: start.addingTimeInterval(2), uptime: 102) == 8, "运行时间消耗预算")
        // 模拟命令执行期间睡眠五分钟，唤醒时仅实际运行两秒。
        check(ordinary.remaining(wallTime: start.addingTimeInterval(302), uptime: 102) == 8, "睡眠不能把成功命令变成超时")
        check(ordinary.remaining(wallTime: start.addingTimeInterval(-300), uptime: 102) == 8, "日期回拨不能延长命令预算")
        check(ordinary.remaining(wallTime: start, uptime: 110) == 0, "真实运行十秒必须超时")
        check(ordinary.remaining(wallTime: start, uptime: 111) == 0, "耗尽预算不得为负数")
        let explicit = NetworkCommandBudget(deadline: start.addingTimeInterval(3), uptime: 100)
        check(explicit.remaining(wallTime: start, uptime: 100) == 3, "显式截止时间保持三秒")
        check(explicit.remaining(wallTime: start.addingTimeInterval(2), uptime: 100) == 1, "总预算仍按调用方截止时间")
        check(explicit.remaining(wallTime: start.addingTimeInterval(302), uptime: 102) == 0, "DNS 总预算不能因睡眠自动延长")
        let output = try NetworkInspection.command("/usr/bin/printf", ["awake"])
        check(output == "awake", "普通命令输出正常")
        do {
            _ = try NetworkInspection.command("/usr/bin/false", [])
            check(false, "非零退出必须失败")
        } catch { check(error.localizedDescription.contains("退出码 1"), "保留真实退出码") }
        do {
            _ = try NetworkInspection.command("/usr/bin/true", [], deadline: Date().addingTimeInterval(-1))
            check(false, "过期请求不得执行")
        } catch { check(error.localizedDescription.contains("true 超过总截止时间"), "过期诊断包含命令和预算类型") }
        let before = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try NetworkInspection.command("/bin/sleep", ["5"], deadline: Date().addingTimeInterval(0.2))
            check(false, "实际阻塞命令必须被终止")
        } catch { check(error.localizedDescription.contains("sleep 超过总截止时间"), "真实超时保留诊断") }
        check(DispatchTime.now().uptimeNanoseconds - before < 3_000_000_000, "超时后不等待睡眠进程自然结束")
        print("RESULT sleep_command_assertions=\(assertions) failures=0")
    }
}
