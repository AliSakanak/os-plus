import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns an error message if it couldn't be changed.
    static func set(enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "Couldn't change the login item: \(error.localizedDescription)"
        }
    }
}
