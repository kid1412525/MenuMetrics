import Foundation
import ServiceManagement

/// 「ログイン時に起動」の登録状態。
/// 署名されていないアプリでは登録に失敗することがあるので、
/// 失敗理由を UI に出せるように保持する。
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var isSupported: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
