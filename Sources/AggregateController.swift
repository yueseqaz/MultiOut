import Foundation
import CoreAudio

enum MultiOutConfig {
    static let aggregateName = "MultiOut 同播设备"
    static let aggregateUIDPrefix = "com.sakura.multiout.aggregate."
}

/// 聚合设备生命周期管理：
/// 开启同播 = 创建包含所选子设备的聚合设备 → 记住原默认输出 → 把系统默认输出切到聚合设备；
/// 关闭同播 = 恢复原默认输出（仅当默认输出仍是我们的聚合设备时）→ 销毁聚合设备。
final class AggregateController {
    private(set) var isRunning = false
    private(set) var aggregateID: AudioDeviceID = 0
    private(set) var aggregateUID = ""
    private(set) var subDeviceUIDs: [String] = []
    private var savedDefaultUID: String?

    /// 返回错误信息；nil 表示成功。
    func start(subDevices: [AudioDevice]) -> String? {
        guard !subDevices.isEmpty else { return "没有选择任何输出设备" }
        if isRunning { return rebuild(subDevices: subDevices) }
        savedDefaultUID = AudioDeviceManager.shared.defaultOutputDevice()?.uid
        return activate(subDevices: subDevices)
    }

    /// 子设备集合变化时重建（蓝牙断连重连、勾选增减）。重建期间原默认输出记忆保持不变。
    func rebuild(subDevices: [AudioDevice]) -> String? {
        guard isRunning else { return start(subDevices: subDevices) }
        deactivate()
        return activate(subDevices: subDevices)
    }

    /// 关闭同播并恢复开启前的默认输出。
    func stop() {
        guard isRunning else { return }
        if isDefaultOurs(), let uid = savedDefaultUID,
           let id = AudioDeviceManager.shared.deviceID(forUID: uid) {
            _ = AudioDeviceManager.shared.setDefaultOutput(id)
        }
        deactivate()
    }

    /// 不恢复默认输出，只销毁聚合设备（用于用户已在系统里手动切换输出的场景）。
    func stopWithoutRestore() {
        guard isRunning else { return }
        deactivate()
    }

    func isDefaultOurs() -> Bool {
        guard isRunning, aggregateID != 0 else { return false }
        return AudioDeviceManager.shared.defaultOutputDeviceID() == aggregateID
    }

    // MARK: - Private

    private func activate(subDevices: [AudioDevice]) -> String? {
        let subUIDs = subDevices.map { $0.uid }
        // 时钟主机优先选非蓝牙设备（蓝牙时钟抖动大，适合作为被补偿的一方）
        let mainIndex = subDevices.firstIndex {
            $0.transportType != kAudioDeviceTransportTypeBluetooth
                && $0.transportType != kAudioDeviceTransportTypeBluetoothLE
        } ?? 0

        let uid = MultiOutConfig.aggregateUIDPrefix + UUID().uuidString.lowercased()
        let subList: [[String: Any]] = subDevices.map { device in
            [kAudioSubDeviceUIDKey: device.uid,
             kAudioSubDeviceDriftCompensationKey: 1]
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: MultiOutConfig.aggregateName,
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: false,
            // 关键：stacked = Audio MIDI Setup 的「多输出设备」——同一份音频复制到每个子设备；
            // 不加这个标志就是普通聚合设备（声道拼接），立体声只会进第一台子设备
            kAudioAggregateDeviceIsStackedKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subList,
            kAudioAggregateDeviceMainSubDeviceKey: subUIDs[mainIndex],
        ]

        var newID = AudioDeviceID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newID)
        guard status == noErr else {
            return "创建聚合设备失败（Core Audio 错误码 \(status)）"
        }

        aggregateID = newID
        aggregateUID = uid
        subDeviceUIDs = subUIDs

        guard AudioDeviceManager.shared.setDefaultOutput(newID) else {
            AudioHardwareDestroyAggregateDevice(newID)
            aggregateID = 0
            aggregateUID = ""
            subDeviceUIDs = []
            return "聚合设备已创建，但设为系统默认输出失败"
        }
        isRunning = true
        return nil
    }

    private func deactivate() {
        guard isRunning else { return }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        aggregateID = 0
        aggregateUID = ""
        subDeviceUIDs = []
        isRunning = false
    }
}
