import AudioToolbox
import CoreAudio
import Foundation

/// Микрофон или динамик Mac. Выбор хранится по `uid`: номер устройства
/// (`AudioDeviceID`) меняется, когда наушники отключают и подключают снова.
struct AudioDevice: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}

/// Устройства звука через CoreAudio — для выбора микрофона и динамика телефона.
enum AudioDevices {
    /// Устройства с входом (`input`) или выходом. Скрытые — например,
    /// сборное устройство, которое система заводит для подавления эха, — не показываем.
    static func list(input: Bool) -> [AudioDevice] {
        allIDs().compactMap { id in
            guard channels(of: id, input: input) > 0, !isHidden(id),
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioDevice(uid: uid, name: name)
        }
    }

    /// Номер устройства по `uid`; `nil` — его сейчас нет (наушники отключены).
    static func deviceID(uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        return allIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    /// Устройство по умолчанию в системе — его имя для пункта «Как в системе».
    static func defaultName(input: Bool) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return string(id, kAudioObjectPropertyName)
    }

    /// Следить за подключением устройств и сменой устройств по умолчанию.
    /// Обработчик зовётся на главной очереди; слежение — до выхода из приложения.
    static func observe(_ handler: @escaping @Sendable () -> Void) {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in handler() }
        }
    }

    /// Направить звук узла `AVAudioEngine` на устройство. Возвращает код
    /// ошибки CoreAudio — для журнала (без имён устройств: в них бывают имена людей).
    @discardableResult
    static func route(_ unit: AudioUnit, to device: AudioDeviceID) -> OSStatus {
        var device = device
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                    &device, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    // MARK: - CoreAudio

    private static func allIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func channels(of id: AudioDeviceID, input: Bool) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func isHidden(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIsHidden,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var hidden: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &hidden) == noErr else { return false }
        return hidden != 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
