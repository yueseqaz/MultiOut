import Foundation
import CoreAudio

/// 每个输出设备的音量读写。优先使用通道 0（主音量），没有主音量的设备
/// （逐通道音量，如部分聚合子设备/USB 声卡）则同时写所有可写通道。
final class VolumeController {
    /// 返回该设备可写音量的通道列表；空数组表示不支持软件音量写入。
    func settableChannels(for deviceID: AudioDeviceID) -> [UInt32] {
        var masterAddr = CA.address(kAudioDevicePropertyVolumeScalar,
                                    scope: kAudioObjectPropertyScopeOutput, element: 0)
        var masterSettable = DarwinBoolean(false)
        if AudioObjectIsPropertySettable(deviceID, &masterAddr, &masterSettable) == noErr, masterSettable.boolValue {
            return [0]
        }
        var result: [UInt32] = []
        for element in UInt32(1)...UInt32(16) {
            var addr = CA.address(kAudioDevicePropertyVolumeScalar,
                                  scope: kAudioObjectPropertyScopeOutput, element: element)
            var settable = DarwinBoolean(false)
            if AudioObjectIsPropertySettable(deviceID, &addr, &settable) == noErr, settable.boolValue {
                result.append(element)
            }
        }
        return result
    }

    func volume(for deviceID: AudioDeviceID, channels: [UInt32]) -> Double? {
        guard let first = channels.first,
              let value = CA.float32Property(deviceID, kAudioDevicePropertyVolumeScalar,
                                             scope: kAudioObjectPropertyScopeOutput, element: first) else { return nil }
        return Double(value)
    }

    @discardableResult
    func setVolume(_ value: Double, deviceID: AudioDeviceID, channels: [UInt32]) -> Bool {
        guard !channels.isEmpty else { return false }
        let clamped = Float32(min(max(value, 0), 1))
        var allOK = true
        for element in channels {
            var v = clamped
            var addr = CA.address(kAudioDevicePropertyVolumeScalar,
                                  scope: kAudioObjectPropertyScopeOutput, element: element)
            if AudioObjectSetPropertyData(deviceID, &addr, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &v) != noErr {
                allOK = false
            }
        }
        return allOK
    }
}
