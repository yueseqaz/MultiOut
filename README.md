# MultiOut — 菜单栏多设备同播工具

把 Mac 正在播放的音频**同时**送到多个输出设备（有线耳机、蓝牙耳机、外接音箱、虚拟声卡……），并且每个设备可以**独立调节音量**，另有一个按比例联动的**总音量**。

纯命令行编译（`swiftc`），不依赖 Xcode，无第三方依赖。

## 构建与运行

```bash
./build.sh                      # 编译出 build/MultiOut.app
open build/MultiOut.app         # 启动，菜单栏出现 🔊 图标
```

命令行自检（不启动界面，验证 Core Audio 链路）：

```bash
build/MultiOut.app/Contents/MacOS/MultiOut --selftest
```

构建脚本支持环境变量：`ARCHES="arm64 x86_64" ./build.sh` 出通用二进制（Intel + Apple Silicon），`MACOSX_DEPLOYMENT_TARGET=13.0` 指定最低系统版本。

也可以直接从 [Releases](../../releases) 下载：推送 `v*` 标签后 GitHub Actions 会自动编译双架构 MultiOut.app 并发布为 Release 附件。

## 使用方法

1. 点击菜单栏的扬声器图标，弹出面板会列出所有输出设备。
2. 勾选要同时出声的设备（有线耳机 + 蓝牙耳机 + 音箱……随意组合）。
3. 点击 **开启同播**：系统默认输出会切换到聚合设备「MultiOut 同播设备」，勾选的设备同时出声。
4. 每台设备右侧滑块 = 该设备独立音量；底部 **总音量** = 按比例缩放所有已勾选设备（保留彼此相对音量）。
5. 点击 **关闭同播**：恢复开启前的默认输出，聚合设备自动销毁。

勾选 **排除虚拟输出** 可以隐藏 Audio Router、腾讯会议这类虚拟设备（偏好会记住）；若被隐藏的虚拟设备正在同播中，会被自动移出并重建聚合设备。

运行中改勾选会立即生效（自动重建聚合设备）；蓝牙耳机断连、插拔耳机等设备变化会自动监听并处理。

## 行为细节

- 面板不是系统弹窗（NSPopover），而是自绘面板，顶边固定在菜单栏图标正下方，任何情况下都不会遮挡菜单栏；点击面板外任意位置或按 Esc 关闭。
- **恢复保护**：只有 App 自己切换的默认输出会被恢复。同播期间你在系统设置里手动切换了输出，App 会自动退出同播状态，绝不抢回控制权。
- **异常退出自愈**：若 App 崩溃留下废弃的聚合设备，下次启动会自动清理，并把默认输出切到可用的物理设备。
- 聚合设备可在「音频 MIDI 设置」中看到，名字为 **MultiOut 同播设备**；正常情况下 App 退出时自动销毁，无需手动删。
- 不支持软件音量写入的设备（极少数），音量滑块会显示「需用设备自身音量键」。

## 已知限制

- 蓝牙耳机（A2DP）有约 100–200ms 固有延迟，与有线设备同播时可能听出轻微不同步。这是所有聚合方案的物理限制，聚合设备的时钟漂移补偿（drift compensation）只能对齐时钟、无法消除固有延迟。
- 系统音量键作用于聚合设备（其主子设备），各设备独立音量请用本面板的滑块调。
- 未签名分发（ad-hoc 签名）：本机使用没问题，拷给别人第一次打开需右键 → 打开。

## 项目结构

```
MultiOut/
├── build.sh                        # swiftc 编译 + 组装 .app + ad-hoc 签名
├── Info.plist                      # LSUIElement：菜单栏应用，不占 Dock
├── .github/workflows/release.yml   # 打 v* 标签自动编译双架构并发布 Release
└── Sources/
    ├── main.swift                  # 入口（含 --selftest 分支）
    ├── AppDelegate.swift           # NSStatusItem + 自绘弹出面板（NSPanel）
    ├── PanelView.swift             # SwiftUI 面板 + PanelModel（状态与交互）
    ├── AudioDeviceManager.swift    # 设备枚举 / 默认输出 / 插拔监听
    ├── AggregateController.swift   # 聚合设备创建/销毁/重建、默认输出切换与恢复
    ├── VolumeController.swift      # 每设备音量读写（主音量或逐通道）
    ├── SelfTest.swift              # 命令行自检
    └── CA.swift                    # Core Audio C API 薄封装
```

## 原理

开启同播时，App 通过 `AudioHardwareCreateAggregateDevice` 创建一个 **stacked 聚合设备**（即「音频 MIDI 设置」里的多输出设备，`kAudioAggregateDeviceIsStackedKey = true`），把勾选的设备作为子设备（全部开启时钟漂移补偿），并把系统默认输出切到它。此后所有 App 播放的音频由 macOS 核心音频服务（coreaudiod）**复制**分发到每个子设备，App 不接触音频数据流，延迟与同步由系统处理。

注意：如果不带 `stacked` 标志，创建出的就是普通「聚合设备」——它把子设备声道**拼接**（两台立体声 = 4 声道），立体声只会进第一台子设备，其余静音。这正是初版踩过的坑。

时钟主机（main sub-device）优先选非蓝牙设备，蓝牙设备作为被漂移补偿的一方。每台设备的音量通过 `kAudioDevicePropertyVolumeScalar` 写入（优先通道 0 主音量，否则逐通道写）。
