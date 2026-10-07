import SwiftUI
import Combine
import CoreAudio

// MARK: - 面板数据模型

final class PanelModel: ObservableObject {
    struct DeviceRow: Identifiable {
        let id: String          // 设备 UID
        var device: AudioDevice
        var selected: Bool
        var volume: Double
        var channels: [UInt32]  // 可写音量通道；空 = 设备不支持软件音量
        var controllable: Bool { !channels.isEmpty }
    }

    static let excludeVirtualKey = "excludeVirtualOutputs"

    @Published private(set) var rows: [DeviceRow] = []
    @Published private(set) var isRunning = false
    @Published private(set) var masterVolume: Double = 0
    @Published private(set) var statusText = "勾选设备后点击「开启同播」"
    @Published private(set) var errorMessage: String?
    @Published private(set) var excludeVirtual = UserDefaults.standard.bool(forKey: PanelModel.excludeVirtualKey)

    let aggregate = AggregateController()
    private let manager: AudioDeviceManager
    private let volumeController = VolumeController()

    var canStart: Bool { rows.contains { $0.selected } }
    var masterAdjustable: Bool { rows.contains { $0.selected && $0.controllable } }

    init(manager: AudioDeviceManager = .shared) {
        self.manager = manager
        manager.onDevicesChanged = { [weak self] in self?.handleDevicesChanged() }
        manager.onDefaultOutputChanged = { [weak self] in self?.handleDefaultOutputChanged() }
        manager.startListening()
        refresh()
    }

    func shutdown() {
        aggregate.stop()
    }

    // MARK: 刷新

    func refresh() {
        var newRows: [DeviceRow] = []
        for device in manager.allOutputDevices() {
            if excludeVirtual && device.transportType == kAudioDeviceTransportTypeVirtual { continue }
            let old = rows.first { $0.id == device.uid }
            let channels = volumeController.settableChannels(for: device.id)
            let readVolume = channels.isEmpty ? nil : volumeController.volume(for: device.id, channels: channels)
            newRows.append(DeviceRow(id: device.uid,
                                     device: device,
                                     selected: old?.selected ?? false,
                                     volume: readVolume ?? old?.volume ?? 0.8,
                                     channels: channels))
        }
        rows = newRows

        if isRunning {
            // 聚合设备仍在运行时，保证运行中的子设备在界面上处于勾选状态
            for index in rows.indices where aggregate.subDeviceUIDs.contains(rows[index].id) {
                rows[index].selected = true
            }
        }
        recomputeMasterVolume()
    }

    private func recomputeMasterVolume() {
        let volumes = rows.filter { $0.selected && $0.controllable }.map { $0.volume }
        masterVolume = volumes.max() ?? 0
    }

    // MARK: 用户操作

    func setExcludeVirtual(_ on: Bool) {
        guard on != excludeVirtual else { return }
        excludeVirtual = on
        UserDefaults.standard.set(on, forKey: Self.excludeVirtualKey)
        if on {
            // 把被隐藏的虚拟设备从同播里移除
            var deselectedVirtual = false
            for index in rows.indices
            where rows[index].device.transportType == kAudioDeviceTransportTypeVirtual && rows[index].selected {
                rows[index].selected = false
                deselectedVirtual = true
            }
            if isRunning && deselectedVirtual { applySelection() }
        }
        refresh()
    }

    func toggleSelection(uid: String, on: Bool) {
        guard let index = rows.firstIndex(where: { $0.id == uid }) else { return }
        rows[index].selected = on
        if isRunning { applySelection() }
    }

    func startStop() {
        if isRunning { stop() } else { applySelection() }
    }

    func stop() {
        errorMessage = nil
        aggregate.stop()
        syncRunState()
        statusText = "同播已关闭，默认输出已恢复"
    }

    func applySelection() {
        errorMessage = nil
        let selected = rows.filter { $0.selected }.map { $0.device }
        guard !selected.isEmpty else {
            if isRunning { stop() }
            statusText = "请先勾选要同播的设备"
            return
        }
        let error = isRunning
            ? aggregate.rebuild(subDevices: selected)
            : aggregate.start(subDevices: selected)
        if let error { errorMessage = error }
        syncRunState()
    }

    func setDeviceVolume(uid: String, _ value: Double) {
        guard let index = rows.firstIndex(where: { $0.id == uid }), rows[index].controllable else { return }
        let clamped = min(max(value, 0), 1)
        let channels = rows[index].channels
        guard let deviceID = manager.deviceID(forUID: uid) else { return }
        _ = volumeController.setVolume(clamped, deviceID: deviceID, channels: channels)
        rows[index].volume = clamped
        recomputeMasterVolume()
    }

    /// 总音量按比例缩放所有已勾选设备，保持设备之间的相对音量关系。
    func setMaster(_ newValue: Double) {
        let target = min(max(newValue, 0), 1)
        let selectedRows = rows.filter { $0.selected && $0.controllable }
        guard !selectedRows.isEmpty else { return }

        if masterVolume < 0.001 {
            for row in selectedRows { setDeviceVolume(uid: row.id, target) }
        } else {
            let ratio = target / masterVolume
            for row in selectedRows {
                setDeviceVolume(uid: row.id, min(1, max(0, row.volume * ratio)))
            }
        }
        masterVolume = target
    }

    // MARK: 系统事件

    private func handleDevicesChanged() {
        refresh()
        guard isRunning else { return }
        let selectedUIDs = Set(rows.filter { $0.selected }.map { $0.id })
        let subUIDsResolvable = aggregate.subDeviceUIDs.allSatisfy { manager.deviceID(forUID: $0) != nil }
        if selectedUIDs != Set(aggregate.subDeviceUIDs) || !subUIDsResolvable {
            applySelection()
        }
    }

    private func handleDefaultOutputChanged() {
        guard isRunning, !aggregate.isDefaultOurs() else { return }
        // 用户在系统设置里手动切换了输出：退出同播，但绝不抢回默认输出
        aggregate.stopWithoutRestore()
        syncRunState()
        statusText = "检测到你手动切换了系统输出，同播已关闭"
    }

    private func syncRunState() {
        isRunning = aggregate.isRunning
        if isRunning {
            statusText = "同播中 · \(aggregate.subDeviceUIDs.count) 台设备"
        }
        recomputeMasterVolume()
    }
}

// MARK: - 弹出面板

struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                if model.rows.isEmpty {
                    Text("未发现任何输出设备")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                }
                ForEach(model.rows) { row in
                    DeviceRowView(row: row,
                                  onToggle: { model.toggleSelection(uid: row.id, on: $0) },
                                  onVolume: { model.setDeviceVolume(uid: row.id, $0) })
                }
            }
            Toggle("排除虚拟输出", isOn: Binding(get: { model.excludeVirtual },
                                              set: { model.setExcludeVirtual($0) }))
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            masterVolumeRow
            startButton
            footer
        }
        .padding(14)
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "hifispeaker.2.fill")
                .foregroundStyle(Color.accentColor)
            Text("MultiOut 多设备同播")
                .font(.headline)
            Spacer()
            if model.isRunning {
                Text("同播中")
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.green.opacity(0.18)))
                    .foregroundStyle(.green)
            }
        }
    }

    private var masterVolumeRow: some View {
        HStack(spacing: 10) {
            Text("总音量")
                .font(.callout)
                .frame(width: 46, alignment: .leading)
            Slider(value: Binding(get: { model.masterVolume },
                                  set: { model.setMaster($0) }),
                   in: 0...1)
                .disabled(!model.masterAdjustable)
            Text("\(Int((model.masterVolume * 100).rounded()))%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private var startButton: some View {
        Button {
            model.startStop()
        } label: {
            Text(model.isRunning ? "关闭同播" : "开启同播")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!model.isRunning && !model.canStart)
    }

    private var footer: some View {
        HStack(alignment: .top) {
            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer()
            Button("退出") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct DeviceRowView: View {
    let row: PanelModel.DeviceRow
    let onToggle: (Bool) -> Void
    let onVolume: (Double) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { row.selected }, set: onToggle))
                .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(row.device.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .help(row.device.name)
                Text(row.device.transportDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            if row.controllable {
                Slider(value: Binding(get: { row.volume }, set: onVolume), in: 0...1)
                    .frame(width: 110)
                Text("\(Int((row.volume * 100).rounded()))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            } else {
                Text("需用设备自身音量键")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
