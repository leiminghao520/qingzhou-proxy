import Foundation

// 此测试程序不依赖完整 Xcode，在 Command Line Tools 环境下执行同一组行为断言。
class CheckCase {
    func setUpWithError() throws {}
    func tearDownWithError() throws {}
}
enum CheckHarness {
    static var assertions = 0
    static var failures = 0
    static func failure(_ message: String, file: StaticString, line: UInt) {failures += 1; print("FAIL \(file):\(line) \(message)")}
}
func expectEqual<T:Equatable>(_ a:@autoclosure () throws -> T,_ b:@autoclosure () throws -> T,_ message:String = "",file:StaticString = #filePath,line:UInt = #line) {
    CheckHarness.assertions += 1
    do {if try a() != b() {CheckHarness.failure("值不相等 " + message,file:file,line:line)}} catch {CheckHarness.failure("断言抛出错误",file:file,line:line)}
}
func expectTrue(_ value:@autoclosure () throws -> Bool,_ message:String = "",file:StaticString = #filePath,line:UInt = #line) {
    CheckHarness.assertions += 1; do {if try !value() {CheckHarness.failure("条件不成立 " + message,file:file,line:line)}} catch {CheckHarness.failure("断言抛出错误",file:file,line:line)}
}
func expectFalse(_ value:@autoclosure () throws -> Bool,_ message:String = "",file:StaticString = #filePath,line:UInt = #line) {expectTrue(try !value(),message,file:file,line:line)}
func expectNil<T>(_ value:@autoclosure () throws -> T?,file:StaticString = #filePath,line:UInt = #line) {expectTrue(try value() == nil,file:file,line:line)}
func expectThrows<T>(_ value:@autoclosure () throws -> T,_ message:String = "",file:StaticString = #filePath,line:UInt = #line,_ inspect:((Error) -> Void)? = nil) {
    CheckHarness.assertions += 1; do {_ = try value();CheckHarness.failure("预期错误未发生 " + message,file:file,line:line)} catch {inspect?(error)}
}
func expectAtMost<T:Comparable>(_ a:@autoclosure () throws -> T,_ b:@autoclosure () throws -> T,file:StaticString = #filePath,line:UInt = #line) {expectTrue(try a() <= b(),file:file,line:line)}
