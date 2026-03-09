import Foundation

@MainActor
enum TimeoutResolver {
    static var shared: AutomationSettings {
        if let data = UserDefaults.standard.data(forKey: "automation_settings_v1"),
           let loaded = try? JSONDecoder().decode(AutomationSettings.self, from: data) {
            return loaded
        }
        return AutomationSettings()
    }

    static var userTestTimeout: TimeInterval {
        if let data = UserDefaults.standard.data(forKey: "login_settings_v2"),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let t = dict["testTimeout"] as? TimeInterval {
            return t
        }
        return 90
    }

    static func resolveRequestTimeout(_ hardcoded: TimeInterval) -> TimeInterval {
        let userTimeout = userTestTimeout
        let pageLoad = shared.pageLoadTimeout
        let effective = max(hardcoded, userTimeout, pageLoad)
        return effective
    }

    static func resolveResourceTimeout(_ hardcoded: TimeInterval) -> TimeInterval {
        let userTimeout = userTestTimeout
        let pageLoad = shared.pageLoadTimeout
        let effective = max(hardcoded, userTimeout, pageLoad) + 30
        return effective
    }

    static func resolvePageLoadTimeout(_ hardcoded: TimeInterval) -> TimeInterval {
        let userTimeout = userTestTimeout
        let pageLoad = shared.pageLoadTimeout
        return max(hardcoded, userTimeout, pageLoad)
    }

    static func resolveHeartbeatTimeout(_ hardcoded: TimeInterval) -> TimeInterval {
        let userTimeout = userTestTimeout
        let pageLoad = shared.pageLoadTimeout
        let highestTest = max(userTimeout, pageLoad)
        return max(hardcoded, highestTest + 30)
    }

    static func resolveTestTimeout(_ hardcoded: TimeInterval, userSetting: TimeInterval) -> TimeInterval {
        let pageLoad = shared.pageLoadTimeout
        return max(hardcoded, userSetting, pageLoad)
    }

    static func resolveAutoHealCap(_ currentTimeout: TimeInterval) -> TimeInterval {
        let userTimeout = userTestTimeout
        let pageLoad = shared.pageLoadTimeout
        return max(currentTimeout, userTimeout, pageLoad)
    }
}
