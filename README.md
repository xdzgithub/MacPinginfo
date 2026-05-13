# MacPinginfo

A macOS native concurrent multi-host ICMP ping monitoring tool.

## Features

- Ping multiple hosts simultaneously with a persistent process per host
- Real-time latency monitoring with packet loss statistics
- CSV export support
- Adjustable ping interval (1s / 2s / 5s / 10s)
- Automatic DNS resolution
- macOS-native SwiftUI interface

## Requirements

- macOS 13.0+
- Xcode 15.0+

## Build

```bash
xcodebuild -scheme MacPinginfo -configuration Release build
```

## License

MIT License
