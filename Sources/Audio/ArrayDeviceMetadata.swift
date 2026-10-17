import CoreAudio
import Foundation

struct ArrayDeviceMetadata: Codable {
    struct Channel: Codable {
        let halChannel: Int
        let name: String?
        let label: UInt32?
        let coordinateFlags: UInt32?
        let reportedCoordinates: [Float]?
    }
    let sampleRate: Double
    let inputChannels: Int
    let latencyFrames: UInt32?
    let safetyOffsetFrames: UInt32?
    let clockDomain: UInt32?
    let layoutTag: UInt32?
    let channels: [Channel]
    let geometry: String

    static func read(_ device: AudioDevice, rate: Double) -> Self {
        func number(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeInput) -> UInt32? {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: 0)
            var value: UInt32 = 0, size: UInt32 = 4
            return AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &value) == noErr ? value : nil
        }
        var channels = (0..<device.channels).map { index -> Channel in
            var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyElementName,
                mScope: kAudioObjectPropertyScopeInput, mElement: UInt32(index + 1))
            var name: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let success = AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &name) == noErr
            return Channel(halChannel: index, name: success ? name.map { $0.takeRetainedValue() as String } : nil,
                           label: nil, coordinateFlags: nil, reportedCoordinates: nil)
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyPreferredChannelLayout,
            mScope: kAudioObjectPropertyScopeInput, mElement: 0)
        var size: UInt32 = 0, tag: UInt32?
        if AudioObjectGetPropertyDataSize(device.id, &address, 0, nil, &size) == noErr, size >= 12 {
            let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
            defer { data.deallocate() }
            if AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, data) == noErr {
                let layout = data.assumingMemoryBound(to: AudioChannelLayout.self).pointee
                tag = layout.mChannelLayoutTag
                let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
                let count = min(device.channels, min(Int(layout.mNumberChannelDescriptions),
                    max(0, (Int(size) - offset) / MemoryLayout<AudioChannelDescription>.stride)))
                let descriptions = data.advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
                for index in 0..<count {
                    let d = descriptions[index]
                    channels[index] = Channel(halChannel: index, name: channels[index].name,
                        label: d.mChannelLabel, coordinateFlags: d.mChannelFlags.rawValue,
                        reportedCoordinates: [d.mCoordinates.0, d.mCoordinates.1, d.mCoordinates.2])
                }
            }
        }
        return Self(sampleRate: rate, inputChannels: device.channels,
            latencyFrames: number(kAudioDevicePropertyLatency), safetyOffsetFrames: number(kAudioDevicePropertySafetyOffset),
            clockDomain: number(kAudioDevicePropertyClockDomain, scope: kAudioObjectPropertyScopeGlobal),
            layoutTag: tag, channels: channels,
            geometry: "Capsule positions/order are not calibrated. A preferred channel layout is not proof of physical microphone coordinates.")
    }
}
