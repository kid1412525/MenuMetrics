import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Dock にも Cmd+Tab にも出さず、メニューバーだけに常駐させる
application.setActivationPolicy(.accessory)
application.run()
