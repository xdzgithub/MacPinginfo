# MacPinginfo

[English](README.md) | [中文](README_zh.md)

受 Windows 平台 PingInfoView 启发的 macOS 原生并发多主机 ICMP ping 监控工具，专为 Mac 网络工程师打造。
<img width="1800" height="1000" alt="image" src="https://github.com/user-attachments/assets/490dc0aa-bb7c-4eaf-86d9-0daffdb86981" />


## 功能特点

- 每个目标 host 独立持久的 ping 进程，支持同时监控多个主机
- 实时延迟监控和丢包率统计
- CSV 格式导出
- 可调节 ping 间隔（1s / 2s / 5s / 10s）
- 自动 DNS 解析
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
