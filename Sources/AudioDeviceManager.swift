import Foundation
import CoreAudio

struct AudioDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transportType: UInt32

    var transportDescription: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:     return "内置"
        case kAudioDeviceTransportTypeBluetooth:   return "蓝牙"
        case kAudioDeviceTransportTypeBluetoothLE: return "蓝牙 LE"
        case kAudioDeviceTransportTypeUSB:         return "USB"
        case kAudioDeviceTransportTypeThunderbolt: return "雷电"
        case kAudioDeviceTransportTypeDisplayPort: return "显示端口"
        case kAudioDeviceTransportTypePCI:         return "PCI"
        case kAudioDeviceTransportTypeFireWire:    return "火线"
        case kAudioDeviceTransportTypeAirPlay:     return "隔空播放"
        case kAudioDeviceTransportTypeVirtual:     return "虚拟"
        case kAudioDeviceTransportTypeAggregate:   return "聚合"
        default:                                   return Self.fourCCName(transportType)
        }
    }

    static func fourCCName(_ code: UInt32) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        guard let s = String(bytes: bytes, encoding: .ascii), !s.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "未知"
        }
        return s
    }
}

/// 枚举输出设备、读写系统默认输出、监听设备插拔。
final class AudioDeviceManager {
    static let shared = AudioDeviceManager()
    private init() {}

    var onDevicesChanged: (() -> Void)?
    var onDefaultOutputChanged: (() -> Void)?
    private var listenersInstalled = false

    func startListening() {
        guard !listenersInstalled else { return }
        listenersInstalled = true
        let queue = DispatchQueue(label: "com.sakura.multiout.coreaudio")

        var devicesAddr = CA.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(CA.systemObject, &devicesAddr, queue) { [weak self] _, _ in
            DispatchQueue.main.async { self?.onDevicesChanged?() }
        }
        var defaultAddr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(CA.systemObject, &defaultAddr, queue) { [weak self] _, _ in
            DispatchQueue.main.async { self?.onDefaultOutputChanged?() }
        }
    }

    /// 所有可用的输出设备（过滤纯输入设备与聚合设备，App 自己的聚合设备不会出现在候选里）。
    func allOutputDevices() -> [AudioDevice] {
        var result: [AudioDevice] = []
        for id in CA.audioDeviceIDs(objectID: CA.systemObject, selector: kAudioHardwarePropertyDevices) {
            guard CA.hasOutputStreams(id) else { continue }
            let transport = CA.uint32Property(id, kAudioDevicePropertyTransportType) ?? 0
            guard transport != kAudioDeviceTransportTypeAggregate else { continue }
            guard let uid = CA.stringProperty(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty else { continue }
            let name = CA.stringProperty(id, kAudioObjectPropertyName) ?? "未知设备"
            result.append(AudioDevice(id: id, uid: uid, name: name, transportType: transport))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func defaultOutputDeviceID() -> AudioDeviceID? {
        CA.audioDeviceIDProperty(CA.systemObject, kAudioHardwarePropertyDefaultOutputDevice)
    }

    func defaultOutputDevice() -> AudioDevice? {
        guard let id = defaultOutputDeviceID() else { return nil }
        let uid = CA.stringProperty(id, kAudioDevicePropertyDeviceUID) ?? ""
        let name = CA.stringProperty(id, kAudioObjectPropertyName) ?? "未知设备"
        let transport = CA.uint32Property(id, kAudioDevicePropertyTransportType) ?? 0
        return AudioDevice(id: id, uid: uid, name: name, transportType: transport)
    }

    @discardableResult
    func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
        var deviceID = id
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectSetPropertyData(CA.systemObject, &addr, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID)
        return status == noErr
    }

    /// 通过 UID 解析设备 ID（设备重连后 AudioDeviceID 会变，UID 稳定）。
    func deviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = CA.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(CA.systemObject, &addr,
                                       UInt32(MemoryLayout<CFString>.size), qualifier, &size, &deviceID)
        }
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    /// 兜底：原默认设备不可用时挑一台可用的输出设备（优先内置扬声器，其次物理设备，最后虚拟）。
    func bestPhysicalOutput() -> AudioDeviceID? {
        let devices = allOutputDevices()
        let physical = devices.filter { $0.transportType != kAudioDeviceTransportTypeVirtual }
        let builtin = physical.first { $0.transportType == kAudioDeviceTransportTypeBuiltIn }
        return (builtin ?? physical.first ?? devices.first)?.id
    }

    /// 清理上次异常退出遗留的聚合设备；若遗留聚合设备正占据默认输出，先切到可用的物理输出再销毁。
    func cleanupStaleAggregates() {
        let ids = CA.audioDeviceIDs(objectID: CA.systemObject, selector: kAudioHardwarePropertyDevices)
        var staleIDs = Set<AudioDeviceID>()
        for id in ids {
            guard let uid = CA.stringProperty(id, kAudioDevicePropertyDeviceUID),
                  uid.hasPrefix(MultiOutConfig.aggregateUIDPrefix) else { continue }
            staleIDs.insert(id)
        }
        guard !staleIDs.isEmpty else { return }

        if let defaultID = defaultOutputDeviceID(), staleIDs.contains(defaultID) {
            let candidates = ids.filter { !staleIDs.contains($0) && CA.hasOutputStreams($0) }
            let best = candidates
                .filter { (CA.uint32Property($0, kAudioDevicePropertyTransportType) ?? 0) != kAudioDeviceTransportTypeVirtual }
                .first ?? candidates.first
            if let best {
                _ = setDefaultOutput(best)
            }
        }
        for id in staleIDs {
            AudioHardwareDestroyAggregateDevice(id)
        }
    }
}
