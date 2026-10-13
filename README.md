# ChargeCap

Menu bar battery charge limiter for macOS, modeled on how AlDente works.

## How it works

`ChargeCap.app` (UI) ↔ XPC ↔ `dev.abenbjohn.chargecap.helper` (root LaunchDaemon). The helper
owns the control loop, so the limit keeps working when the app is closed.

| Limit | Mechanism |
|---|---|
| 80–100 % | macOS native Manual Charge Limit: `mclLimitValue` + `MCLFeatureState` in root's `com.apple.smartcharging.topoffprotection`, then Darwin notification `com.apple.smartcharging.defaultschanged`. Firmware reflects it in SMC `CHLT`. Holds during sleep. |
| < 80 % (opt-in) | SMC charge inhibit (`CHTE` or `CH0B`/`CH0C`) where the firmware has it. Otherwise "sailing": SMC `CHIE` = 0x08 turns the adapter off at the limit, 0x00 turns it back on at limit − band. Adapter is re-enabled before sleep. |
| Discharge above limit | `CHIE` adapter off until the charge reaches the limit. |

Safety: the helper re-enables the adapter and clears any inhibit on SIGTERM (uninstall/shutdown)
and before sleep. It accepts XPC only from ChargeCap signed by team `ZPJ7XARQ4A`, and the app
only talks to a helper signed by the same team. The XPC API is limited to "apply config" and
"status"; there is no raw SMC write call.

## Power flow

The menu shows a live, animated diagram of where power goes, sampled every second from the
SMC (no root needed):

| Flow | Source |
|---|---|
| Charger → Mac / Charger → battery / battery → Mac | `PDTR` (DC in), `PSTR` (system), `B0AV` × `B0AC` (battery, + charging / − discharging) |
| Mac → wired devices | Per USB-C port `D{n}JV` × `D{n}JI`; devices from `IOUSBHostDevice`, mapped to a port via their `usb-drd{n-1}` controller |
| Wireless accessories | `system_profiler SPBluetoothDataType` battery levels (no power flow — they don't draw from the Mac) |

Particle speed, count and size scale with watts. Reduce Motion stops the particles.

## Build & install

```sh
./scripts/bundle.sh                 # build/ChargeCap.app, signed with the Apple Development identity
open build/ChargeCap.app            # "Install helper" asks for your password once
```

CLI (run the binary inside the signed app):

```sh
build/ChargeCap.app/Contents/MacOS/ChargeCap --status
build/ChargeCap.app/Contents/MacOS/ChargeCap --set-limit 85 [--below80] [--discharge]
build/ChargeCap.app/Contents/MacOS/ChargeCap --smc     # read-only SMC dump, no helper needed
build/ChargeCap.app/Contents/MacOS/ChargeCap --power   # live power flow numbers
build/ChargeCap.app/Contents/MacOS/ChargeCap --devices # USB-C ports, wired devices, Bluetooth batteries
```

Uninstall: "Uninstall helper" in the menu, or run `Resources/uninstall-helper.sh` as root.
The native macOS charge limit stays at whatever was last set (System Settings → Battery).
