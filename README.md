# minimuxer

`minimuxer` is the lockdown muxer library used by [SideStore](https://github.com/SideStore/SideStore). It manages device communication, app installation/sideloading, Developer Disk Image (DDI) mounting, AFC file system operations, and pairing over local loopback VPN or remote endpoints.

![Alt](https://repobeats.axiom.co/api/embed/95df7af50adae86935e34bc1f59083f1db326c24.svg "Repobeats analytics image")

## Architecture

```
Domain/
├── HeartbeatTiming.swift             ← Heartbeat receive deadline policy
└── DeveloperDiskImageMountDescriptor.swift ← Legacy/personalized DDI detection
Sources/
├── MinimuxerApi.swift               ← Public API contracts (Minimuxer, NetworkObserver, WirelessPair)
├── MinimuxerImpl.swift              ← Core Minimuxer API implementation
├── IdeviceGateway.swift             ← Gateway layer communicating with IDevice C/FFI library
├── LockdownSessionRuntime.swift      ← Lockdown readiness, leases, and heartbeat lifecycle
├── MinimuxerConstants.swift         ← Constants & default configurations
├── MinimuxerError.swift             ← Public error definitions
├── Services/
│   ├── DeviceEndpoint.swift         ← Active target device IP state
│   ├── HeartbeatService.swift       ← Heartbeat keep-alive service
│   ├── Mounter.swift                ← Developer Disk Image (DDI) mounter
│   ├── MuxerService.swift           ← Usbmuxd fake server listener over TCP
│   ├── NetworkIfaceScanner.swift    ← Network interface scanning & route reachability detection
│   ├── NetworkObserverService.swift ← Network path monitoring (NWPathMonitor) & endpoint lifecycle
│   └── WirelessPairService.swift    ← Wireless pairing service & PIN verification
└── Types/
    ├── PairingProtocol.swift        ├── Protocol types (.lockdown, .rppairing)
    └── RawPacket.swift              └── Low-level packet parsing
```

## Dependencies

- **IDevice**: Pre-built `idevice-xcframework` binary target providing lower-level C/FFI bindings for iOS device communication.
- **ZIPFoundation**: Used for extracting DDI disk images and IPA application bundles.

## Key APIs & Connection Modes

### Public APIs (`Minimuxer`)

- `Minimuxer.shared`: Primary API for app installation, uninstallation, DDI mounting, profile management, and AFC file operations.
- `Minimuxer.network`: Handles network path monitoring, interface scanning, and endpoint attachment/detachment.
- `Minimuxer.wirelessPair`: Manages wireless pairing flow and PIN verification (iOS 27+).

### Connection Modes

- `.localVPN`: On-device loopback VPN connection. Uses user-configured override peer IP when present; auto-discovers `utun*` interface peer IP only when no override is configured.
- `.remoteServer`: Remote server endpoint configuration over LAN, Wi-Fi, or external VPN.

## Building

`minimuxer` is integrated as a standard Swift Package (`Package.swift`).

```bash
swift build
```
