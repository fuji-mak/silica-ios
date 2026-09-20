import CoreLocation
import CoreMotion

enum PermissionStatusText {
    static func motionIsReady(_ status: CMAuthorizationStatus, isAvailable: Bool) -> Bool {
        #if DEBUG
        if DebugLaunchConfiguration.forcesMissingMotionPermission {
            return false
        }
        if DebugLaunchConfiguration.forcesPermissionsReady {
            return true
        }
        #endif
        return isAvailable == false || status == .authorized
    }

    static func location(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: AppLanguage.localized("未設定")
        case .restricted: AppLanguage.localized("制限中")
        case .denied: AppLanguage.localized("許可なし")
        case .authorizedAlways: AppLanguage.localized("常に許可")
        case .authorizedWhenInUse: AppLanguage.localized("使用中のみ")
        @unknown default: AppLanguage.localized("不明")
        }
    }

    static func motion(_ status: CMAuthorizationStatus, isAvailable: Bool) -> String {
        guard isAvailable else {
            return AppLanguage.localized("利用不可")
        }
        return switch status {
        case .notDetermined: AppLanguage.localized("未設定")
        case .restricted: AppLanguage.localized("制限中")
        case .denied: AppLanguage.localized("許可なし")
        case .authorized: AppLanguage.localized("許可済み")
        @unknown default: AppLanguage.localized("不明")
        }
    }
}
