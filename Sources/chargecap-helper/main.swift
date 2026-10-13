import ChargeKit
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

// Privileged LaunchDaemon. Talks to the SMC and the native charge-limit prefs on
// behalf of ChargeCap.app, the way AlDente's com.apphousekitchen.aldente-pro.helper does.

let engine = ChargeEngine()

final class Service: NSObject, ChargeHelperProtocol {
    func status(reply: @escaping (Data) -> Void) {
        reply((try? JSONEncoder().encode(engine.status())) ?? Data())
    }

    func apply(config: Data, reply: @escaping (String?) -> Void) {
        guard var config = try? JSONDecoder().decode(HelperConfig.self, from: config) else {
            return reply("Invalid config")
        }
        config.limit = min(max(config.limit, 20), 100)
        config.sailingBand = min(max(config.sailingBand, 1), 15)
        engine.apply(config)
        reply(nil)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service = Service()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Reject anything that isn't ChargeCap.app signed by our team. Unlike the old open-source
        // AlDente helper, which accepted every caller, this enforces the check on each message.
        connection.setCodeSigningRequirement(ChargeCapIDs.clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: ChargeHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

// Re-evaluate whenever the battery or power source changes.
let psSource = IOPSNotificationCreateRunLoopSource({ _ in engine.evaluate() }, nil).takeRetainedValue()
CFRunLoopAddSource(CFRunLoopGetMain(), psSource, .defaultMode)

// Fallback timer, like AlDente's 5 s loop (slower: power-source notifications do the real work).
let timer = Timer(timeInterval: 30, repeats: true) { _ in engine.evaluate() }
RunLoop.main.add(timer, forMode: .common)

// Sleep/wake: never sleep with the adapter cut; re-evaluate on wake.
// iokit_common_msg() values; the macros aren't imported into Swift.
let kIOMessageCanSystemSleep: UInt32 = 0xE000_0270
let kIOMessageSystemWillSleep: UInt32 = 0xE000_0280
let kIOMessageSystemHasPoweredOn: UInt32 = 0xE000_0300
var rootPort: io_connect_t = 0
var notifier: io_object_t = 0
var notifyPort: IONotificationPortRef?
rootPort = IORegisterForSystemPower(nil, &notifyPort, { _, _, messageType, argument in
    switch messageType {
    case kIOMessageSystemWillSleep:
        engine.willSleep()
        IOAllowPowerChange(rootPort, Int(bitPattern: argument))
    case kIOMessageCanSystemSleep:
        IOAllowPowerChange(rootPort, Int(bitPattern: argument))
    case kIOMessageSystemHasPoweredOn:
        engine.evaluate()
    default:
        break
    }
}, &notifier)
if let notifyPort {
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .defaultMode)
}

// On launchctl bootout / shutdown: leave the Mac charging normally.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        engine.restoreHardware()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: ChargeCapIDs.machService)
listener.delegate = delegate
listener.resume()

engine.evaluate()
RunLoop.main.run()
