import Foundation
import Darwin

// 独立监护进程在应用被强制结束后停止核心，避免遗留进程占用监听端口。
let arguments = CommandLine.arguments
if arguments.count < 3 {exit(64)}
let parent = getppid()
let child = Process()
child.executableURL = URL(fileURLWithPath:arguments[1])
child.arguments = Array(arguments.dropFirst(2))
child.standardInput = FileHandle.nullDevice
child.standardOutput = FileHandle.standardOutput
child.standardError = FileHandle.standardError
let queue = DispatchQueue(label:"cn.qingzhou.supervisor")
var stopping = false
func stopChild() {
    if stopping {return};stopping = true
    if child.isRunning {
        child.terminate()
        queue.asyncAfter(deadline:.now()+2) {if child.isRunning {kill(child.processIdentifier,SIGKILL)}}
    } else {exit(0)}
}
signal(SIGTERM,SIG_IGN);signal(SIGINT,SIG_IGN);signal(SIGHUP,SIG_IGN)
let term = DispatchSource.makeSignalSource(signal:SIGTERM,queue:queue)
let interrupt = DispatchSource.makeSignalSource(signal:SIGINT,queue:queue)
let hup = DispatchSource.makeSignalSource(signal:SIGHUP,queue:queue)
let parentExit = DispatchSource.makeProcessSource(identifier:parent,eventMask:.exit,queue:queue)
for source in [term,interrupt,hup] {source.setEventHandler {stopChild()};source.resume()}
parentExit.setEventHandler {stopChild()};parentExit.resume()
child.terminationHandler = {p in queue.async {exit(p.terminationStatus)}}
do {try child.run()} catch {fputs("代理核心启动失败\n",stderr);exit(70)}
if getppid() != parent {queue.async {stopChild()}}
dispatchMain()
