import CoreAudio
import Foundation

struct AudioDevice {
    let id: AudioDeviceID
    let uid: String
    let channels: Int

    static func builtIn(uid: String, scope: AudioObjectPropertyScope) throws -> Self {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        let name = uid as CFString
        var namePointer = Unmanaged.passUnretained(name).toOpaque()
        var id: AudioDeviceID = 0
        var bytes = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                  UInt32(MemoryLayout.size(ofValue: namePointer)), &namePointer, &bytes, &id), "Find built-in audio")
        guard id != 0 else { throw AudioFailure("Built-in audio is unavailable.") }
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                            mScope: scope, mElement: 0)
        try check(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &bytes), "Read channel count")
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &bytes, storage), "Read channels")
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return Self(id: id, uid: uid, channels: buffers.reduce(0) { $0 + Int($1.mNumberChannels) })
    }

    static func format(device: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat, mScope: scope, mElement: 0)
        var format = AudioStreamBasicDescription()
        var bytes = UInt32(MemoryLayout.size(ofValue: format))
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &bytes, &format), "Read audio format")
        guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else {
            throw AudioFailure("Native Float32 audio is required.")
        }
        return format
    }

    static func aggregate(input: Self, output: Self) throws -> AudioDeviceID {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "EchoGestures (temporary)",
            kAudioAggregateDeviceUIDKey: "dev.echogestures.audio.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: output.uid],
                [kAudioSubDeviceUIDKey: input.uid, kAudioSubDeviceDriftCompensationKey: true]
            ]
        ]
        var device: AudioDeviceID = 0
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &device), "Join speakers and microphones")
        return device
    }

    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw AudioFailure("\(operation) failed (Core Audio \(status)).") }
    }
}

struct AudioFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
