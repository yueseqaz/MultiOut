# MultiOut — 菜单栏多设备同播工具

MultiOut 是一款常驻 macOS 菜单栏的音频工具：把系统正在播放的音频**同时**送到多个输出设备——有线耳机、蓝牙耳机、外接音箱可以一起出声，每台设备拥有独立的音量滑块，另有一个按比例联动的总音量。

- 纯 Swift + 系统框架，`swiftc` 命令行编译，不依赖 Xcode 与第三方库
- 菜单栏小面板，不占 Dock，随用随点
- 通用二进制，同时支持 Apple Silicon 与 Intel

## 功能

- **多设备同播**：勾选任意输出设备组合，系统音频实时分发到每台设备
- **独立音量**：每台设备单独调节，互不影响
- **总音量**：按比例缩放所有同播设备，保留彼此的相对音量
- **排除虚拟输出**：一键隐藏 Audio Router、腾讯会议这类虚拟设备，偏好自动记住
- **设备变化自动跟随**：蓝牙断连重连、插拔耳机即时感知，同播组合修改立即生效
- **默认输出保护**：开启前记住默认输出，关闭时原样恢复；同播期间手动切换系统输出时，MultiOut 会主动退出而不抢回控制权；启动时自动清理异常退出遗留的聚合设备

## 下载安装

从 [Releases](../../releases) 下载 `MultiOut.zip`，解压后将 **MultiOut.app** 拖入「应用程序」文件夹，双击打开即可，菜单栏会出现扬声器图标。

> App 为 ad-hoc 签名，若首次打开被 Gatekeeper 拦截，请右键点击图标选择「打开」。

Release 由 GitHub Actions 自动构建：推送 `v*` 标签即触发编译、自检并发布。

## 从源码构建

```bash
./build.sh                      # 编译出 build/MultiOut.app
open build/MultiOut.app         # 启动，菜单栏出现扬声器图标
```

构建脚本支持环境变量：

- `ARCHES`：目标架构，默认 `arm64`，设为 `arm64 x86_64` 可出通用二进制
- `MACOSX_DEPLOYMENT_TARGET`：最低系统版本，默认 `13.0`

命令行自检（不启动界面，验证 Core Audio 链路）：

```bash
build/MultiOut.app/Contents/MacOS/MultiOut --selftest
```

## 使用方法

1. 点击菜单栏的扬声器图标，面板中列出所有输出设备
2. 勾选要同时出声的设备，点击「开启同播」
3. 拖动每台设备右侧的滑块独立调音量，底部「总音量」按比例联动
4. 「关闭同播」恢复原来的默认输出

面板顶边固定在菜单栏图标正下方，不遮挡菜单栏；点击面板外任意位置或按 Esc 关闭。

## 工作原理

开启同播时，MultiOut 通过 `AudioHardwareCreateAggregateDevice` 创建一个 stacked 聚合设备（即「音频 MIDI 设置」中的多输出设备），将勾选的设备作为子设备并开启时钟漂移补偿，再把系统默认输出切换到该设备。此后所有 App 播放的音频由 macOS 核心音频服务（coreaudiod）复制分发到每个子设备，MultiOut 不接触音频数据流，同步由系统处理。

时钟主机优先选择非蓝牙设备，蓝牙设备作为被补偿的一方；各设备音量通过 `kAudioDevicePropertyVolumeScalar` 写入，优先通道 0 主音量，否则逐通道写入。

## 说明与限制

- 蓝牙耳机（A2DP）存在约 100–200ms 的固有延迟，与有线设备同播时可能听出轻微不同步；这是所有多输出方案的物理限制，时钟漂移补偿只对齐时钟，无法消除固有延迟
- 系统音量键作用于聚合设备本身，各设备的独立音量请使用面板中的滑块调节
- 极少数设备不提供可写的软件音量，对应设备的滑块会显示「需用设备自身音量键」
- 同播聚合设备可在「音频 MIDI 设置」中看到，名为「MultiOut 同播设备」，关闭同播时自动销毁

## 项目结构

```
MultiOut/
├── build.sh                        # swiftc 编译 + 组装 .app + ad-hoc 签名
├── Info.plist                      # LSUIElement：菜单栏应用，不占 Dock
├── .github/workflows/release.yml   # 打 v* 标签自动编译双架构并发布 Release
└── Sources/
    ├── main.swift                  # 入口（含 --selftest 分支）
    ├── AppDelegate.swift           # NSStatusItem + 弹出面板（NSPanel）
    ├── PanelView.swift             # SwiftUI 面板 + PanelModel（状态与交互）
    ├── AudioDeviceManager.swift    # 设备枚举 / 默认输出 / 插拔监听
    ├── AggregateController.swift   # 聚合设备创建/销毁/重建、默认输出切换与恢复
    ├── VolumeController.swift      # 每设备音量读写（主音量或逐通道）
    ├── SelfTest.swift              # 命令行自检
    └── CA.swift                    # Core Audio C API 薄封装
```
