import Foundation

/// Every `UserDefaults` / `@AppStorage` key the app writes, in one place. The string values are
/// persisted on users' Macs: renaming one silently resets that setting, so treat them as frozen.
public enum DefaultsKey {
    public static let appTheme = "appTheme"
    public static let appFont = "appFont"
    public static let routingPolicy = "routingPolicy"
    public static let optimizerModelPin = "optimizerModelPin"
    public static let apiSharingEnabled = "apiSharingEnabled"
    public static let apiSharingPort = "apiSharingPort"
    public static let updateCheckDaily = "updateCheckDaily"
    public static let updateLastCheck = "updateLastCheck"
    public static let briefViewMode = "brief.viewMode"

    static let all = [appTheme, appFont, routingPolicy, optimizerModelPin, apiSharingEnabled,
                      apiSharingPort, updateCheckDaily, updateLastCheck, briefViewMode]
}
