import ChargeKit
import Foundation

/// XPC client for the privileged helper. Also verifies the *helper's* signature,
/// so a look-alike daemon registered under our Mach name can't receive commands.
final class HelperClient: @unchecked Sendable {
    static let helperRequirement =
        "anchor apple generic and identifier \"\(ChargeCapIDs.helperLabel)\" and certificate leaf[subject.OU] = \"\(ChargeCapIDs.teamID)\""

    private var connection: NSXPCConnection?
    private let lock = NSLock()

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: ChargeCapIDs.launchDaemonPath)
    }

    private func proxy(_ onError: @escaping (Error) -> Void) -> ChargeHelperProtocol? {
        lock.withLock {
            if connection == nil {
                let c = NSXPCConnection(machServiceName: ChargeCapIDs.machService, options: .privileged)
                c.remoteObjectInterface = NSXPCInterface(with: ChargeHelperProtocol.self)
                c.setCodeSigningRequirement(Self.helperRequirement)
                c.invalidationHandler = { [weak self] in self?.lock.withLock { self?.connection = nil } }
                c.resume()
                connection = c
            }
            return connection?.remoteObjectProxyWithErrorHandler(onError) as? ChargeHelperProtocol
        }
    }

    func status(_ completion: @escaping (Result<HelperStatus, Error>) -> Void) {
        let once = Once(completion)
        proxy { once.call(.failure($0)) }?.status { data in
            do { once.call(.success(try JSONDecoder().decode(HelperStatus.self, from: data))) }
            catch { once.call(.failure(error)) }
        }
    }

    func apply(_ config: HelperConfig, _ completion: @escaping (String?) -> Void) {
        let once = Once(completion)
        guard let data = try? JSONEncoder().encode(config) else { return completion("Encoding failed") }
        proxy { once.call("Helper unreachable: \($0.localizedDescription)") }?.apply(config: data) { once.call($0) }
    }

    func reset() {
        lock.withLock {
            connection?.invalidate()
            connection = nil
        }
    }

    // MARK: Install / uninstall (admin password prompt)

    /// Runs a bundled script as root through the standard macOS authorization dialog.
    static func runPrivileged(script: String) -> String? {
        guard let resources = Bundle.main.resourcePath else { return "Not running from ChargeCap.app" }
        let path = "\(resources)/\(script)"
        guard FileManager.default.fileExists(atPath: path) else { return "\(script) missing from app bundle" }
        let shell = "/bin/sh \(quoted(path)) \(quoted(resources))"
        let source = "do shell script \(appleScriptString(shell)) with administrator privileges with prompt \"ChargeCap needs to install its battery helper.\""
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error.map { $0[NSAppleScript.errorMessage] as? String ?? "Failed" }
    }

    private static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// XPC can call both the error handler and the reply; deliver only the first.
private final class Once<T>: @unchecked Sendable {
    private var fn: ((T) -> Void)?
    private let lock = NSLock()
    init(_ fn: @escaping (T) -> Void) { self.fn = fn }
    func call(_ v: T) {
        let f = lock.withLock { () -> ((T) -> Void)? in defer { fn = nil }; return fn }
        f?(v)
    }
}
