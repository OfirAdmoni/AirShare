# AirShare

**Air it, Share it**

Serverless, peer-to-peer, cross-platform file sharing. No accounts, no sign-in,
no internet connection required. Two devices in the same room discover each
other over Bluetooth Low Energy, negotiate the best available local network path
between them, and transfer files directly over an encrypted local link. Nothing
is uploaded to a cloud service, and no traffic leaves the local network.

Repository: [github.com/OfirAdmoni/AirShare](https://github.com/OfirAdmoni/AirShare)

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Supported Platforms](#supported-platforms)
- [Tech Stack](#tech-stack)
- [Getting Started](#getting-started)
- [Runtime Requirements](#runtime-requirements)
- [Security Model](#security-model)
- [Repository Layout](#repository-layout)
- [Known Issues and Limitations](#known-issues-and-limitations)
- [Legacy Code](#legacy-code)
- [Project Status](#project-status)
- [License and Authors](#license-and-authors)

---

## Overview

Each AirShare session has two roles, chosen from the main menu:

- **Start Sharing (host / hub)** - the device starts a local HTTPS file hub and
  advertises itself over BLE.
- **Join a Session (guest)** - the device scans for AirShare peers over BLE and
  connects to the selected host.

Once connected, both devices see a shared room: a manifest-backed file list
where the guest can browse, download, upload and delete files, with per-file
owner metadata.

**Features**

| Feature | Description |
| --- | --- |
| BLE peer discovery | Devices are found by AirShare's GATT service UUID; results are filtered to that UUID only. |
| Host approval | The host explicitly approves each guest join and each incoming transfer, both with timeouts. |
| Shared room | A manifest tracks the shared files and their owners for the duration of the session. |
| Manual connection | A fallback screen accepts a raw IP address and port when discovery is unavailable. |
| Connection audit log | Every discovery, tier attempt and handshake step is logged and can be reviewed or exported in-app. |
| AP isolation guidance | Client/AP isolation is detected on both host and guest sides, with targeted help dialogs instead of raw errors. |
| Onboarding | A first-run flow, gated by a persisted `onboarding_done` preference. |
| Settings | Custom device name, save-path display, and a PIN toggle (see Known Issues). |

---

## Architecture

AirShare separates **discovery** (always BLE) from **transport** (a local IP
link chosen from three tiers).

```
   Guest                                            Host (hub)
     |                                                   |
     |  1. BLE scan, filtered by service UUID            |
     |<--------------------------------------------------|  BLE advertising
     |                                                   |  (GATT server)
     |  2. ClientHello over GATT write                   |
     |-------------------------------------------------->|
     |                                       host approval prompt
     |  3. Handshake JSON over GATT notify               |
     |<--------------------------------------------------|
     |     lan_ip, hotspot_ssid/pass, p2p_ip/mac,        |
     |     hub_port, friendly_name, tls_cert_sha256      |
     |                                                   |
     |  4. Connect over the best available tier:         |
     |       Tier 1  LAN            (preferred)          |
     |       Tier 2  LocalOnlyHotspot                    |
     |       Tier 3  Wi-Fi Direct   (last resort)        |
     |                                                   |
     |  5. HTTPS to hub, cert pinned by SHA-256          |
     |==================================================>|  Dart HttpServer
```

### 1. Discovery over BLE

The AirShare GATT service and its two characteristics:

| Purpose | UUID |
| --- | --- |
| Service | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` |
| Handshake characteristic | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` |
| Endpoint characteristic | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` |

The service UUID is defined once in `lib/air_share_constants.dart` and mirrored
in every native layer (`android/.../MainActivity.kt`,
`windows/runner/flutter_window.cpp`, `ios/Runner/BleTransportPlugin.swift`,
`macos/Runner/BleTransportPlugin.swift`).

Dart talks to the native BLE and WLAN layers over four platform channels:

| Channel | Type | Purpose |
| --- | --- | --- |
| `air_share/ble_transport` | Method | Scanning, advertising, handshake, approval |
| `air_share/ble_scan_events` | Event | Stream of discovered peers |
| `air_share/ble_ui` | Method | Native to Flutter connection-request prompts |
| `air_share/wlan_link` | Method | Hotspot, Wi-Fi Direct and WLAN join operations |

Scan results are filtered in `lib/ble_transport.dart` so that only peers
advertising the exact AirShare service UUID are surfaced. On Android the service
UUID is carried in the primary advertisement PDU and the device name in the scan
response, with both sized against the 31-byte legacy PDU limit before
advertising starts.

### 2. Handshake

The guest writes a `ClientHello` (peer id and display name) to the handshake
characteristic. The host's UI is blocked pending an explicit operator approval;
on approval, the host replies with the handshake JSON via GATT **notify** (no
read polling). The payload carries `lan_ip`, `p2p_ip`, `p2p_mac`,
`hotspot_ssid`, `hotspot_pass`, `hotspot_hub_ip`, `hub_port`, `friendly_name`
and `tls_cert_sha256`.

### 3. Multi-tier connection fallback

The guest-side strategy lives in a single method, `_connectViaTierStrategy` in
`lib/discovery_page.dart`, and is tried strictly in order:

**Tier 1 - LAN (preferred).** A subnet check is run against the advertised
`lan_ip`, then a direct TCP probe to `lan_ip:hub_port`. The BLE-delivered
`lan_ip` is trusted and probed even when the subnet check does not match, since
the address arrived over an authenticated side channel. Subnet helpers live in
`lib/connection_tier.dart`.

**Tier 2 - LocalOnlyHotspot.** Android joins the host's hotspot automatically
via `WifiNetworkSpecifier`. iOS and macOS instead get a manual "join this SSID
in Settings" dialog, followed by probing of a candidate IP list that includes
the common gateway addresses `192.168.43.1`, `192.168.49.1` and
`192.168.137.1`.

**Tier 3 - Wi-Fi Direct (last resort, Android only).** `WifiP2pManager.connect`
to the advertised `p2p_mac`, then a TCP probe to `p2p_ip` or the group owner's
address. If every tier fails, the strategy raises
`All connection tiers failed (LAN -> Hotspot -> P2P)`.

On the host side, `lib/host_network_tier.dart` scores the live IPv4 interfaces
(`wlan0` > `wlan` > `wifi` > `ap0`/`ap1` > ethernet), excludes cellular, VPN,
`tun`, `vbox`, `vmnet`, `p2p` and `rndis` interfaces, and advertises only a
genuine private IPv4. When a usable pre-connected address exists, the host sets
`useTier1Only` and skips Tiers 2 and 3 entirely. Otherwise, Android attempts
`LocalOnlyHotspot` and only falls through to a Wi-Fi Direct group if that fails.
Note that on Android 10 and above, `LocalOnlyHotspot` ignores any custom
SSID/password, so only the system-generated credentials are advertised to the
guest.

### 4. Transport: the local hub

`lib/local_hub_runtime.dart` owns the active server. `LocalHubRuntime` is a
singleton holding a Dart `HttpServer`, started by `ensureStarted()` through
`HttpServer.bindSecure` on `0.0.0.0`, port 8080, with up to ten sequential port
retries if the port is taken. **This Dart server is the one and only server in
the running application** (see [Legacy Code](#legacy-code)).

The transport is HTTPS, not plain HTTP. Endpoints:

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/health` | Liveness probe used by the tier TCP checks |
| `POST` | `/join` | Guest join request, gated by host approval |
| `GET` | `/files` | Shared room manifest |
| `GET` | `/download` | File download |
| `POST` | `/upload` | File upload |
| `DELETE` | `/files` | File deletion |
| `POST` | `/transfer-request` | Announce an incoming batch for approval |
| `GET` | `/pending-transfer` | Poll the pending approval state |
| `POST` | `/transfer-response` | Resolve a pending approval |

---

## Supported Platforms

| Platform | Status |
| --- | --- |
| **Android** | Full support: BLE central and peripheral, `LocalOnlyHotspot`, Wi-Fi Direct, and `WifiNetworkSpecifier` joins. All three connection tiers are available. |
| **Windows** | Desktop host and guest: BLE scanning and a GATT server via WinRT. Tier 1 (LAN) only - there is no hotspot implementation, and the sender path runs in explicit LAN/TCP mode. See Known Issues. |
| **iOS** | In progress: BLE discovery and manual hotspot join implemented; hosting offline not supported (LAN only). |
| **macOS** | Experimental (BLE plugin scaffolding, `fix/mac-host` branch). |

The `linux/` and `web/` directories are untouched Flutter scaffolding and are
not build targets for this project.

---

## Tech Stack

- **Flutter / Dart** for the cross-platform application layer. SDK constraint
  `^3.11.1`; the lockfile resolves against `dart >=3.11.1 <4.0.0` and
  `flutter >=3.38.4`. Verified working on Flutter 3.47.0 stable / Dart 3.13.0.
- **C++ / WinRT** for the native Windows layer
  (`windows/runner/flutter_window.cpp`, ~1,476 lines), linking `dwmapi.lib` and
  `windowsapp.lib`, built with CMake 3.14 or later.
- **Kotlin** for the native Android layer
  (`android/app/src/main/kotlin/com/example/air_share/MainActivity.kt`),
  compiled against Java 17 source and target compatibility.
- **Swift** for the iOS and macOS BLE and WLAN plugins.

**Dart dependencies** (from `pubspec.yaml`): `device_info_plus`, `geolocator`,
`http`, `mime`, `network_info_plus`, `basic_utils`, `crypto`, `pointycastle`,
`shared_preferences`, `path_provider`, `path`, `file_picker`,
`permission_handler`, `open_filex`, `nsd`, `multicast_dns`, `cupertino_icons`;
`flutter_lints` for development.

---

## Getting Started

### Prerequisites

- Flutter (stable channel) providing Dart 3.11.1 or newer. The lockfile was
  resolved against Flutter 3.38.4 or newer.
- **Android builds:** JDK 17 and the Android SDK.
- **Windows builds:** Visual Studio with the *Desktop development with C++*
  workload and the Windows 10 SDK, which supplies the WinRT Bluetooth headers
  the native layer includes.

### Build and run

```bash
git clone https://github.com/OfirAdmoni/AirShare.git
cd AirShare

flutter pub get
flutter devices

# Run in debug on a connected device
flutter run -d android
flutter run -d windows

# Release builds
flutter build apk --release
flutter build windows --release

# Static analysis
flutter analyze
```

---

## Runtime Requirements

- **Android** requires Bluetooth to be switched on *and* Location services to be
  enabled, which is an OS-level requirement for BLE scanning. The app prompts
  for both and will explain why if either is off.
- **Android permissions** requested: `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`,
  `BLUETOOTH_CONNECT`, `ACCESS_FINE_LOCATION`, `NEARBY_WIFI_DEVICES`,
  `CHANGE_WIFI_STATE`, plus storage permissions on API level 32 and below.
- **Windows** must allow inbound TCP on the hub port. The application logs the
  exact rule at startup:

  ```
  netsh advfirewall firewall add rule name="AirShare 8080" dir=in action=allow protocol=TCP localport=8080
  ```

- **Port:** the hub defaults to 8080 and auto-increments up to ten times if that
  port is unavailable.
- **Save locations:** Android writes to `<external>/AirShare/Received`; desktop
  platforms write to `<Downloads>/AirShare`. The desktop host's staging area is
  a separate temporary `AirShare_Session` directory, cleared on teardown, so it
  never collides with the guest download folder.

---

## Security Model

AirShare has no accounts and no server, so trust is established per session
between the two devices:

- **Per-session TLS.** The host generates a self-signed RSA-2048 certificate in
  memory at session start, with SANs covering every live IPv4 address. The
  server runs via `HttpServer.bindSecure`, so all file traffic is HTTPS.
- **Certificate pinning over BLE.** The SHA-256 hash of the certificate DER is
  delivered to the guest inside the BLE handshake payload (`tls_cert_sha256`)
  and pinned by the guest's HTTP client. Because the pin arrives on a separate,
  physically local channel before any IP traffic, a network attacker cannot
  substitute their own certificate.
- **Explicit host approval.** Both the initial join and every incoming transfer
  require the host operator to approve, and both approvals time out.
- **Session-scoped bearer tokens.** After an approved `POST /join`, the hub
  issues a 256-bit random token, required thereafter in the
  `x-airshare-auth-token` header. Tokens are bound to a session epoch and
  revoked on teardown, so a token from a previous session is worthless.
- **Path traversal defence.** Uploaded filenames are sanitised to a single path
  segment; mixed separators are normalised and `.`/`..` are rejected.

---

## Repository Layout

```
lib/            33 Dart files (~9,440 lines) - UI, session, tier and hub logic
  local_hub_runtime.dart    the active Dart HttpServer (HTTPS hub)
  discovery_page.dart       guest-side BLE scan + tier fallback strategy
  sender_staging_page.dart  host-side tier planning and advertising
  host_network_tier.dart    interface scoring and Tier 1 selection
  connection_tier.dart      subnet and LAN-reachability helpers
  ble_transport.dart        platform-channel BLE bridge and handshake payload
  hub_tls.dart              per-session self-signed certificate generation
  hub_auth.dart             session-epoch bearer tokens
android/        Kotlin native layer (single MainActivity.kt, ~2,200 lines)
windows/        C++ / WinRT native layer (flutter_window.cpp/.h)
ios/            Swift BLE and WLAN plugins (in progress)
macos/          Swift BLE and WLAN plugins (experimental)
linux/, web/    untouched Flutter scaffolding, not build targets
engine/         legacy Go prototype - see below
```

---

## Known Issues and Limitations

These are documented openly; each has been confirmed in the source.

1. **Windows as host: BLE advertising is unreliable.** WinRT's
   `GattServiceProviderAdvertisingParameters` exposes no API for setting the
   advertised local name, and the service UUID is not reliably placed in the
   advertisement packet. As a result, a Windows host is **discovered
   unreliably** by guests - handshakes do succeed intermittently, but discovery
   cannot be depended upon - and when it is discovered, the OS computer name may
   appear instead of the chosen friendly name. The code works around the naming
   half of the problem by injecting the real friendly name into the GATT
   handshake payload, and the Windows scanner tolerates advertisements that
   arrive without a service UUID by retaining already-known peers.
   **Workaround:** use Android as the host, or use the Manual Connection screen
   to enter the host's IP address and port directly.

2. **Windows hotspot is not implemented.** The `startTemporaryHotspot` handler
   returns placeholder credentials without creating an access point, so Windows
   hosts are effectively Tier 1 (LAN) only.

3. **AP / client isolation.** Many public networks, and some home routers,
   silently drop the guest's TCP SYN to the host. The app detects this condition
   on both sides and shows targeted guidance rather than a raw connection error,
   but the network itself cannot be worked around except by moving to a hotspot
   tier.

4. **Wi-Fi Direct can report busy.** On Android, a lingering P2P group from a
   previous session can cause `connect` to fail with `reason=2`. Explicit
   teardown handling exists, but as the last-resort tier it can still fail.

5. **PIN protection is not yet enforced.** Settings exposes a *Require PIN for
   incoming connections* toggle, and the value is persisted, but no connection
   path currently reads it.

6. **Self-signed certificates.** Guests see no CA trust chain; the security of
   the channel rests entirely on the BLE-delivered SHA-256 pin described above.

7. **Unused dependencies.** `nsd` and `multicast_dns` are declared in
   `pubspec.yaml` but are not imported anywhere in `lib/`. mDNS is not part of
   the live discovery path - BLE is. Both are candidates for cleanup.

8. **Template application ID.** The Android `applicationId` is still the
   scaffold default `com.example.air_share` and should be changed before any
   distribution.

---

## Legacy Code

The `engine/` directory contains a **superseded Go prototype** of the file hub
(`main.go`, `auth.go`, `tls_cert.go`, a `go.mod`/`go.sum` pair, a committed
binary and a folder of leftover test documents). It is **not part of the running
application**:

- Nothing builds it - no reference to `engine/` exists in `lib/`, `android/`,
  `windows/` or `pubspec.yaml`.
- Nothing launches it - the application never spawns the Go process.
- The only remaining vestige is `lib/hub_go_pre_approval_sync.dart`, which makes
  a best-effort POST to `https://127.0.0.1:<port>/host/pre-approve` and swallows
  every error precisely because the Go engine is normally absent; the Dart hub
  handles pre-approval in process.

The Go prototype is retained in version history only and is slated for removal.
All server functionality described in this document is provided by the Dart
`HttpServer` in `lib/local_hub_runtime.dart`.

---

## Project Status

Active development branch: `final-version`.

Recent work on this branch:

```
b137b0f  Add security upgrade changes
f4a348c  Implement hybrid AP Isolation detection and platform-aware hotspot guidance
f33f38d  Redesign file cards to a compact horizontal layout and implement responsive grid
83afb6e  Fix syntax errors in dialog theme and button styles
d3f3aa4  Fix Windows download path collision and upgrade multi-selection UI
d01c2ac  Fix iOS host BLE approval and harden cross-platform hub sharing
e393863  feat: complete cross-platform connection architecture and fix multi-nic bug
64cc54f  Redesign onboarding screens to match new UI and session logic
bcac14a  Finalize shared room UI, fix downloads, and add Hebrew support
```

Feature and fix work is tracked on side branches, including
`feature/security-upgrade`, `feature/security-approval-merge`,
`feature/fix-p2p-busy`, `fix/mac-host` and `rotem-ios`.

---

## License and Authors

License and authors: TBD.
