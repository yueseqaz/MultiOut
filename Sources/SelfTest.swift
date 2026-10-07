import Foundation
import CoreAudio

/// 命令行自检：验证设备枚举、聚合设备创建/切换默认输出/恢复/销毁、音量读写。
/// 不启动任何界面，直接在终端输出结果并以退出码表达成败（0 = 通过）。
enum SelfTest {
    static func run() {
        print("== MultiOut 自检 ==")
        let manager = AudioDeviceManager.shared
        let volumeController = VolumeController()
        let aggregate = AggregateController()
        var passed = true

        // [1] 设备枚举
        let devices = manager.allOutputDevices()
        print("[1] 发现输出设备 \(devices.count) 台：")
        for device in devices {
            print("      - \(device.name)（\(device.transportDescription)）")
        }
        if devices.isEmpty {
            print("      ✗ 未发现任何输出设备，无法继续")
            exit(1)
        }

        // [2] 记录当前默认输出
        guard let original = manager.defaultOutputDevice() else {
            print("[2] ✗ 读取当前默认输出失败")
            exit(1)
        }
        print("[2] 当前默认输出：\(original.name)")

        // [3] 创建聚合设备（优先用内置扬声器做子设备）
        let sub = devices.first { $0.transportType == kAudioDeviceTransportTypeBuiltIn } ?? devices[0]
        print("[3] 创建聚合设备（子设备：\(sub.name)）...")
        if let error = aggregate.start(subDevices: [sub]) {
            print("      ✗ \(error)")
            exit(1)
        }
        print("      ✓ id=\(aggregate.aggregateID)  uid=\(aggregate.aggregateUID)")

        // [4] 默认输出是否切到聚合设备
        let nowDefault = manager.defaultOutputDevice()
        if nowDefault?.uid == aggregate.aggregateUID {
            print("[4] 系统默认输出已切换到聚合设备 ✓")
        } else {
            print("[4] ✗ 默认输出切换失败（当前：\(nowDefault?.name ?? "无")）")
            passed = false
        }

        // [5] 子设备音量写入/读回
        let channels = volumeController.settableChannels(for: sub.id)
        if channels.isEmpty {
            print("[5] 子设备不支持软件音量写入，跳过音量测试")
        } else {
            let before = volumeController.volume(for: sub.id, channels: channels) ?? 0.75
            let setOK = volumeController.setVolume(0.5, deviceID: sub.id, channels: channels)
            let after = volumeController.volume(for: sub.id, channels: channels)
            if setOK, let after, abs(after - 0.5) < 0.02 {
                print("[5] 音量写入/读回：\(before) → 0.5 → \(after) ✓")
            } else {
                print("[5] ✗ 音量写入或读回失败（set=\(setOK), read=\(String(describing: after))）")
                passed = false
            }
            _ = volumeController.setVolume(before, deviceID: sub.id, channels: channels)
            print("      已恢复子设备原音量 \(before)")
        }

        // [6] 关闭同播：恢复默认输出并销毁聚合设备
        aggregate.stop()
        let restored = manager.defaultOutputDevice()
        if restored?.uid == original.uid {
            print("[6] 默认输出已恢复：\(restored!.name) ✓")
        } else {
            print("[6] ✗ 默认输出恢复失败（当前：\(restored?.name ?? "无")）")
            passed = false
        }

        // [7] 验证「多输出堆叠」生效：两台立体声子设备 → 聚合设备应只暴露 2 个输出声道
        //     （若暴露 4 声道，说明创建成了声道拼接的普通聚合设备，音频只会进第一台）
        if let other = devices.first(where: { $0.id != sub.id }) {
            let subList: [[String: Any]] = [sub, other].map {
                [kAudioSubDeviceUIDKey: $0.uid, kAudioSubDeviceDriftCompensationKey: 1]
            }
            let desc: [String: Any] = [
                kAudioAggregateDeviceNameKey: "MultiOut 自检临时",
                kAudioAggregateDeviceUIDKey: MultiOutConfig.aggregateUIDPrefix
                    + "selftest-" + UUID().uuidString.lowercased(),
                kAudioAggregateDeviceIsPrivateKey: false,
                kAudioAggregateDeviceIsStackedKey: true,
                kAudioAggregateDeviceSubDeviceListKey: subList,
                kAudioAggregateDeviceMainSubDeviceKey: sub.uid,
            ]
            var tempID = AudioDeviceID(0)
            if AudioHardwareCreateAggregateDevice(desc as CFDictionary, &tempID) == noErr {
                let channelCount = CA.outputChannelCount(tempID)
                AudioHardwareDestroyAggregateDevice(tempID)
                if channelCount == 2 {
                    print("[7] 多输出堆叠验证：两台立体声子设备 → 聚合设备仅 2 声道（音频复制到每台）✓")
                } else {
                    print("[7] ✗ 聚合设备暴露了 \(channelCount) 声道，预期 2（stacked 未生效）")
                    passed = false
                }
            } else {
                print("[7] ⚠️ 临时双设备聚合创建失败，跳过堆叠验证")
            }
        } else {
            print("[7] 只有一台输出设备，跳过堆叠验证")
        }

        print(passed ? "== 自检通过 ✓ ==" : "== 自检未完全通过 ✗ ==")
        exit(passed ? 0 : 1)
    }
}
