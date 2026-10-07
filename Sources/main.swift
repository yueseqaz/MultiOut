import AppKit

// 命令行自检模式：./MultiOut --selftest
if CommandLine.arguments.contains("--selftest") {
    SelfTest.run() // 内部必定 exit
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
