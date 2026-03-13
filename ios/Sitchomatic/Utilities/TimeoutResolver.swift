import Foundation

@MainActor
enum TimeoutResolver {
    static var shared: AutomationSettings {
        if let data = UserDefaults.standard.data(forKey: "automation_settings_v1"),
           let loaded = try? JSONDecoder().decode(AutomationSettings.self, from: data) {
            return loaded.normalizedTimeouts()
        }
        return AutomationSettings().normalizedTimeouts()
    }

    static var userTestTimeout: TimeInterval {
        if let data = UserDefaults.standard.data(forKey: "login_settings_v2"),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let t = dict["testTimeout"] as? TimeInterval {
            return max(t, AutomationSettings.minimumTimeoutSeconds)
        }
        return AutomationSettings.minimumTimeoutSeconds
    }

    static func resolveRequestTimeout(_ hardcoded: TimeInterval) -> TimeInterval {
        let pageLoad = shared.pageLoadTimeout
        if pageLoad > 0 {
            return max(pageLoad, AutomationSettings.minimumTimeoutSeconds)
        }
        return max(hardcoded, AutomationSettings.minimumTimeoutSeconds)
    }

    static func resolveResourceTimeout(_ hardcoded: TimeInterval) -> TimeInterval {
        let pageLoad = shared.pageLoadTimeout
        if pageLoad > 0 {
            return max(pageLoad, AutomationSettings.minimumTimeoutSeconds) + 30
        }
        return max(hardcoded, AutomationSettings.minimumTimeoutSeconds) + 30
    }

    static func resolvePageLoadTimeout(_ hardcoded: TimeInterval) -> TimeInterval {
        let pageLoad = shared.pageLoadTimeout
        if pageLoad > 0 {
            return max(pageLoad, AutomationSettings.minimumTimeoutSeconds)
        }
        return max(hardcoded, AutomationSettings.minimumTimeoutSeconds)
    }

    static func resolveHeartbeatTimeout(_ hardcoded: TimeInterval) -> TimeInterval {
        let pageLoad = shared.pageLoadTimeout
        let effective = pageLoad > 0 ? pageLoad : hardcoded
        return max(effective, AutomationSettings.minimumTimeoutSeconds) + 30
    }

    static func resolveTestTimeout(_ hardcoded: TimeInterval, userSetting: TimeInterval) -> TimeInterval {
        let pageLoad = shared.pageLoadTimeout
        if userSetting > 0 {
            return max(userSetting, AutomationSettings.minimumTimeoutSeconds)
        }
        if pageLoad > 0 {
            return max(max(hardcoded, pageLoad), AutomationSettings.minimumTimeoutSeconds)
        }
        return max(hardcoded, AutomationSettings.minimumTimeoutSeconds)
    }

    static func resolveAutoHealCap(_ currentTimeout: TimeInterval) -> TimeInterval {
        let pageLoad = shared.pageLoadTimeout
        if pageLoad > 0 {
            return max(max(currentTimeout, pageLoad), AutomationSettings.minimumTimeoutSeconds)
        }
        return max(currentTimeout, AutomationSettings.minimumTimeoutSeconds)
    }

    static func resolveAutomationTimeout(_ hardcoded: TimeInterval) -> TimeInterval {
        max(hardcoded, AutomationSettings.minimumTimeoutSeconds)
    }

    static func resolveAutomationMilliseconds(_ hardcoded: Int) -> Int {
        max(hardcoded, AutomationSettings.minimumTimeoutMilliseconds)
    }
}
