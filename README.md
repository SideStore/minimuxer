# minimuxer

`minimuxer` is the lockdown muxer library used by [SideStore](https://github.com/SideStore/SideStore). It manages device communication, app installation/sideloading, Developer Disk Image (DDI) mounting, AFC file system operations, and pairing over local loopback VPN or remote endpoints.

![Alt](https://repobeats.axiom.co/api/embed/95df7af50adae86935e34bc1f59083f1db326c24.svg "Repobeats analytics image")

## Architecture

```
├── Common/                          ← MinimuxerCommon package
│   ├── FFIDispatcher.swift          ← Serial GCD dispatch queue utility for FFI calls
│   ├── MinimuxerConstants.swift     ← Constants & default configurations
│   └── NetworkUtils.swift           ← TCP socket probing & device reachability checks
├── DeviceGateway/                   ← DeviceGateway package (libimobiledevice / idevice)
│   ├── DeviceGatewayAPI.swift       ← Gateway protocol definitions
│   ├── idevice/                     ← Idevice backend implementation
│   └── libimobiledevice/            ← Libimobiledevice backend implementation
└── Sources/                         ← Main Minimuxer package
    ├── MinimuxerApi.swift           ← Public API contracts & Minimuxer composition root
    ├── MinimuxerImpl.swift          ← Core Minimuxer API implementation
    ├── EMProxyImpl.swift            ← EMProxy wrapper implementation
    ├── MinimuxerError.swift         ← Public error definitions
    ├── Services/
    │   ├── DeviceConnectionManager.swift ← Route discovery & connection reachability
    │   ├── DeviceEndpoint.swift     ← Active target device IP state
    │   ├── HeartbeatService.swift   ← Heartbeat keep-alive service
    │   ├── Mounter.swift            ← Developer Disk Image (DDI) mounter
    │   ├── NetworkIfaceScanner.swift← Network interface scanner
    │   ├── NetworkObserverService.swift ← Network path monitoring (NWPathMonitor) & endpoint lifecycle
    │   ├── UsbmuxdProxyServer.swift ← Usbmuxd proxy server listener over TCP
    │   └── WirelessPairService.swift← Wireless pairing service & PIN verification
    └── Types/
        └── RawPacket.swift          ← Low-level packet parsing
```

## Dependencies

- **DeviceGateway**: Pluggable device gateway backend (`libimobiledevice` and `idevice` C/FFI bindings).
- **EMProxy**: Pre-built `EMProxy.xcframework` for WireGuard loopback server and handshake handling.
- **ZIPFoundation**: Used for extracting DDI disk images and IPA application bundles.

## Key APIs & Connection Modes

### Public APIs (`Minimuxer`)

- `Minimuxer.shared(backend:)`: Memoized singleton factory returning an instance with:
  - `.core`: Primary API for app installation, uninstallation, DDI mounting, profile management, and AFC file operations.
  - `.network`: Handles network path monitoring, interface scanning, and endpoint attachment/detachment.
  - `.wirelessPair`: Manages wireless pairing flow and PIN verification (iOS 27+).
  - `.emproxy`: Controls EMProxy WireGuard loopback server and handshake client.
  - `.gateway`: Active device gateway backend (`libimobiledevice` or `idevice`).

### Connection Modes

- `.localVPN`: On-device loopback VPN connection. Uses user-configured override peer IP when present; auto-discovers `utun*` interface peer IP only when no override is configured.
- `.remoteServer`: Remote server endpoint configuration over LAN, Wi-Fi, or external VPN.

## Building

`minimuxer` is integrated as a standard Swift Package (`Package.swift`).

```bash
swift build
```

---

## Authors

- [@jkcoxson](https://github.com/jkcoxson)
- [@mahee96](https://github.com/mahee96)
- [@nythepegasus](https://github.com/nythepegasus)

---

## Credits and References

- Baseline Rust implementation from [minimuxer](https://github.com/jkcoxson/minimuxer) by [@jkcoxson](https://github.com/jkcoxson)
- RPPairing initial Rust implementation end-to-end support added in minimuxer by [@hugeblack](https://github.com/hugeblack) backed by Remote Pairing(RPPairing) implementation in `idevice`
- Swift complete rewrite by [@mahee96](https://github.com/mahee96)
- VPN auto-discovery initial research by [@nythepegasus](https://github.com/nythepegasus)
- Enhanced research for end-to-end VPN auto-discovery and probing implementation by [@mahee96](https://github.com/mahee96)
- Port from `rustylibimobiledevice` bridge to `idevice` bridge by [@mahee96](https://github.com/mahee96)
- Alternative device-gateway (`libimobiledevicegateway`) bridge implementation backed by `libimobiledevice` by [@mahee96](https://github.com/mahee96)
- Alternative RPPairing ground-up implementation in C++ (based on spec from [jkcoxson's rppairing-spec](https://jkcoxson.com/blog/rppairing-spec)) called [RemotePairingKit](https://github.com/mahee96/RemotePairingKit) by [@mahee96](https://github.com/mahee96)

---

## License

This project is licensed under the terms of the **GNU Affero General Public License v3.0** (AGPL-3.0).
