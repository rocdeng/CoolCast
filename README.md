# CoolCast

CoolCast 是一个面向 Android TV 的清爽投屏接收端。它以 TV 待命屏为核心，展示当前网络、设备名称和支持的投屏方式；收到 HTTP/DLNA 媒体地址后自动进入播放界面。

## 当前功能

- Android TV / Leanback 启动入口
- tvOS 风格 Home 待命界面
- 设备投屏名称修改弹窗
- 投屏名称本地持久化
- 局域网 HTTP 投送入口：`http://TV-IP:7788/`
- URL 快速投送接口：`http://TV-IP:7788/cast?url=视频地址`
- 局域网远程安装 APK 入口：待命页左下角“远程安装”弹窗二维码 / `http://TV-IP:7788/install`
- DLNA/UPnP MediaRenderer 基础发现
- DLNA `SetAVTransportURI` / `Play` / `Pause` / `Stop` 基础控制
- 收到媒体 URL 后自动播放
- 播放页遥控器控制层
- Android Wi-Fi multicast lock，提升 SSDP 发现稳定性

## 构建

需要本机具备 Android SDK platform 36、build-tools 34，以及 JDK 17+。

```bash
flutter pub get
scripts/build_debug_apk.sh
```

产物路径：

```text
build/app/outputs/flutter-apk/app-debug.apk
```

## 当前限制

- DLNA 先实现第一版媒体 URL 投送主链路，还不是完整商业级协议栈。
- Miracast、完整 AirPlay 和 Google Cast 暂未实现。
