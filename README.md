# ChargeCap

Menu bar battery charge limiter for macOS, modeled on how AlDente works.

[![Download ChargeCap](https://img.shields.io/badge/Download-ChargeCap.dmg-2ea44f?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/abenbjohn10/chargecap/releases/latest/download/ChargeCap.dmg)

**[⬇ Download the latest DMG](https://github.com/abenbjohn10/chargecap/releases/latest/download/ChargeCap.dmg)** · [All releases](https://github.com/abenbjohn10/chargecap/releases)

Open the DMG, drag ChargeCap to Applications, launch it and click **Install helper**.
Requires macOS 14+ on Apple Silicon (native charge limit: macOS 26.4+). The build isn't notarized:
if macOS blocks it, right-click the app → **Open**, or allow it in System Settings → Privacy & Security.

## The app

- **Window** (sidebar): Overview (battery gauge, stats, live power flow), Charging (limit slider, presets),
  Devices (USB-C ports with W/V/A, Bluetooth batteries), Battery Health, Helper.
- **Welcome** on first launch: animated liquid battery, feature tour, one-click helper setup
  (replay: ChargeCap → Show Welcome).
- **Menu bar panel**: live power-flow animation on top, Limit ▾ / Options ▾ dropdowns, ⋯ menu
  (Open, Settings, Launch at Login, Show %, Quit), Bluetooth battery rings.
- **Settings** (⌘,): General, Charging, Helper.

Power-flow particles are Core Animation layers (`FlowParticles.swift`), so they keep moving while a
menu is open and cost almost no CPU.

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
| Wireless accessories | Battery levels only (they don't draw from the Mac) — see below |

Particle speed, count and size scale with watts. Reduce Motion stops the particles.

## How readings work

| Reading | Source | Root? |
|---|---|---|
| Battery % / charging state | IOPowerSources (`IOPSCopyPowerSourcesInfo`) — same as the system menu bar | no |
| Health, capacity, cycles | IORegistry `AppleSmartBattery`: `CycleCount`, `BatteryData.NominalChargeCapacity / DesignCapacity` | no |
| Battery temperature | SMC `TB0T` (float, °C) | no |
| Charger in / Mac draw / battery flow | SMC `PDTR`, `PSTR`, `B0AV` × `B0AC` (mV × signed mA) | no |
| USB-C device power | SMC `D{n}JV` × `D{n}JI` per port; device names from `IOUSBHostDevice`, mapped to port n via the `usb-drd{n-1}` controller | no |
| Charge limit state | root prefs `com.apple.smartcharging.topoffprotection` (`MCLFeatureState`, `mclLimitValue`); firmware echo in SMC `CHLT` | read via helper |
| Adapter on/off | SMC `CHIE` (0x00 on, 0x08 off) | write needs helper |
| Bluetooth batteries | 1. `system_profiler SPBluetoothDataType` (AirPods L/R/Case, Beats) 2. IORegistry `AppleDeviceManagementHIDEventService.BatteryPercent` (Magic accessories) 3. CoreBluetooth GATT Battery Service `0x180F`/`0x2A19` (BLE mice/keyboards) | no (Bluetooth permission for 3) |

SMC values are read through `IOConnectCallStructMethod` on the `AppleSMC` user client (selector 2,
80-byte `SMCParamStruct`). Apple Watch and iPhone don't expose their battery to macOS apps.

## Build & install

```sh
./scripts/bundle.sh                 # build/ChargeCap.app, signed with the Apple Development identity
open build/ChargeCap.app            # "Install helper" asks for your password once
./scripts/make-dmg.sh               # build/ChargeCap-<version>.dmg (drag to Applications)
```

The DMG is signed with an Apple Development certificate, so Gatekeeper only accepts it on Macs
that trust that certificate. For wider distribution, set `IDENTITY` to a Developer ID Application
certificate and `NOTARY_PROFILE` to a `notarytool` keychain profile; the script then notarizes and
staples the DMG.

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
