import Foundation

public enum ChargeCapIDs {
    public static let appBundleID = "dev.abenbjohn.chargecap"
    public static let helperLabel = "dev.abenbjohn.chargecap.helper"
    public static let machService = "dev.abenbjohn.chargecap.helper"
    public static let teamID = "ZPJ7XARQ4A"
    public static let helperPath = "/Library/PrivilegedHelperTools/\(helperLabel)"
    public static let launchDaemonPath = "/Library/LaunchDaemons/\(helperLabel).plist"
    public static let configPath = "/Library/Application Support/ChargeCap/config.plist"
    public static let helperVersion = "1"

    /// The helper only accepts XPC connections from ChargeCap signed by this team
    /// (shipping AlDente does the same check with SecCodeCheckValidity on the audit token).
    public static let clientRequirement =
        "anchor apple generic and identifier \"\(appBundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
}

/// What the user asked for. Stored by the helper, so it keeps working when the app is closed.
public struct HelperConfig: Codable, Equatable, Sendable {
    /// Target charge in percent (20...100). 100 = no limit.
    public var limit: Int = 80
    /// Allow targets under 80 %. macOS's native limit stops at 80, so below that
    /// ChargeCap cycles the power adapter (AlDente's "sailing") — see ChargeEngine.
    public var allowBelow80 = false
    /// Sailing range for below-80 limits: resume charging at limit - band.
    public var sailingBand = 5
    /// Run on battery (adapter off) when the charge is above the limit, until it reaches it.
    public var dischargeAboveLimit = false

    public init() {}

    public var effectiveLimit: Int {
        let clamped = min(max(limit, 20), 100)
        return allowBelow80 ? clamped : max(clamped, 80)
    }
}

public struct HelperStatus: Codable, Sendable {
    public var config: HelperConfig
    public var nativeLimitEnabled: Bool?
    public var nativeLimitValue: Int?
    /// SMC CHLT byte 0 — the limit the firmware is actually enforcing.
    public var firmwareLimit: Int?
    public var adapterEnabled: Bool?
    public var adapterKey: String?
    public var inhibitKey: String?
    public var lastAction: String
    public var lastError: String?
    public var version: String

    public init(config: HelperConfig, nativeLimitEnabled: Bool?, nativeLimitValue: Int?, firmwareLimit: Int?,
                adapterEnabled: Bool?, adapterKey: String?, inhibitKey: String?,
                lastAction: String, lastError: String?, version: String) {
        self.config = config
        self.nativeLimitEnabled = nativeLimitEnabled
        self.nativeLimitValue = nativeLimitValue
        self.firmwareLimit = firmwareLimit
        self.adapterEnabled = adapterEnabled
        self.adapterKey = adapterKey
        self.inhibitKey = inhibitKey
        self.lastAction = lastAction
        self.lastError = lastError
        self.version = version
    }
}

/// XPC interface. Narrow on purpose: no generic "write any SMC key" call
/// (the open-source AlDente helper exposed setSMCByte(key:value:) to any caller).
@objc(ChargeHelperProtocol)
public protocol ChargeHelperProtocol {
    func status(reply: @escaping (Data) -> Void)
    /// JSON-encoded HelperConfig. Replies with an error message or nil.
    func apply(config: Data, reply: @escaping (String?) -> Void)
}
