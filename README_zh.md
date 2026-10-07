# MacPinginfo

[English](README.md) | [中文](README_zh.md)

受 Windows 平台 PingInfoView 启发的 macOS 原生并发多主机 ICMP ping 监控工具，专为 Mac 网络工程师打造。

<img width="900" alt="MacPinginfo" src="docs/screenshot.png" />


## 功能特点

- 每个目标 host 独立持久的 ping 进程，支持同时监控多个主机
- 实时延迟监控和丢包率统计
- CSV 格式导出
- 可调节 ping 间隔（1s / 2s / 5s / 10s）
- 自动 DNS 解析
- 支持 IPv6：IPv4/IPv6 字面量自动识别；「域名使用 IPv6 解析」开关让域名优先按 AAAA 解析，IPv6 不通时自动回退 IPv4
- macOS 原生 SwiftUI 界面

## 系统要求

- macOS 13.0+
- Xcode 15.0+

## 编译构建

```bash
xcodebuild -scheme MacPinginfo -configuration Release build
```

构建产物位于 `build/Release/MacPinginfo.app`。

## License

MIT License
