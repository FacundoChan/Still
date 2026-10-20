import AVFoundation
import CoreMedia

public enum AudioRetimingError: Error, LocalizedError {
    case decodeFailed(Error?)
    case retimeFailed(Error?)
    case bufferCreationFailed(OSStatus)

    public var errorDescription: String? {
        "The sound couldn’t be prepared."
    }
}

/// Decodes the selected source audio and changes its speed with `AVAudioUnitTimePitch`, preserving pitch.
///
/// Export doesn’t use the composition’s `audioTimePitchAlgorithm`: on macOS 27 it delays sound by up to
/// about 90 ms when speeding up, in both `AVAssetReaderAudioMixOutput` and `AVAssetExportSession`
/// (measured with the flash-and-beep fixture). Driving the audio unit offline and discarding its reported
/// latency stays within ±5 ms at every supported speed.
struct AudioRetimer {
    static let sampleRate = 44_100.0
    static let channelCount = 2
    private static let chunkFrames = 4096

    let asset: AVAsset
    let track: AVAssetTrack
    /// Source time range to use.
    let sourceRange: CMTimeRange
    let speed: Double
    /// The rendered audio is padded or trimmed to exactly this length.
    let outputDuration: CMTime

    /// Interleaved 32-bit float PCM sample buffers covering the output, ready for an AAC writer input.
    func render() throws -> [CMSampleBuffer] {
        try sampleBuffers(from: renderChannels())
    }

    /// One array of samples per channel, exactly `outputDuration` long.
    func renderChannels() throws -> [[Float]] {
        var channels = try decode()
        if speed != 1 {
            channels = try retime(channels)
        }
        let frameCount = Int((outputDuration.seconds * Self.sampleRate).rounded())
        for index in channels.indices {
            channels[index] = Array(channels[index].prefix(frameCount))
            channels[index] += [Float](repeating: 0, count: frameCount - channels[index].count)
        }
        return channels
    }

    // MARK: - Decoding

    private func decode() throws -> [[Float]] {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioRetimingError.decodeFailed(error)
        }
        reader.timeRange = sourceRange
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: Self.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw AudioRetimingError.decodeFailed(nil) }
        reader.add(output)
        guard reader.startReading() else { throw AudioRetimingError.decodeFailed(reader.error) }

        var interleaved: [Float] = []
        var firstTime: CMTime?
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            if firstTime == nil { firstTime = CMSampleBufferGetPresentationTimeStamp(sample) }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = chunk.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw AudioRetimingError.bufferCreationFailed(status) }
            interleaved += chunk
        }
        guard reader.status == .completed else { throw AudioRetimingError.decodeFailed(reader.error) }

        // An audio track that starts after the selection begins gets leading silence, so sound stays in place.
        let leadingSeconds = max(0, ((firstTime ?? sourceRange.start) - sourceRange.start).seconds)
        let leadingFrames = Int((leadingSeconds * Self.sampleRate).rounded())
        return (0..<Self.channelCount).map { channel in
            [Float](repeating: 0, count: leadingFrames)
                + stride(from: channel, to: interleaved.count, by: Self.channelCount).map { interleaved[$0] }
        }
    }

    // MARK: - Retiming

    private func retime(_ channels: [[Float]]) throws -> [[Float]] {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate,
                                   channels: AVAudioChannelCount(Self.channelCount))!
        let frames = channels.first?.count ?? 0
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return channels
        }
        input.frameLength = AVAudioFrameCount(frames)
        for (index, channel) in channels.enumerated() {
            channel.withUnsafeBufferPointer { input.floatChannelData![index].update(from: $0.baseAddress!, count: frames) }
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = Float(speed)
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: AVAudioFrameCount(Self.chunkFrames))
            try engine.start()
        } catch {
            throw AudioRetimingError.retimeFailed(error)
        }
        defer { engine.stop() }
        player.scheduleBuffer(input)
        player.play()

        let latencyFrames = Int((timePitch.auAudioUnit.latency * Self.sampleRate).rounded())
        let wanted = Int((Double(frames) / speed).rounded(.up)) + latencyFrames
        guard let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                           frameCapacity: AVAudioFrameCount(Self.chunkFrames)) else {
            throw AudioRetimingError.retimeFailed(nil)
        }
        var output = [[Float]](repeating: [], count: Self.channelCount)
        while output[0].count < wanted {
            let status: AVAudioEngineManualRenderingStatus
            do {
                status = try engine.renderOffline(AVAudioFrameCount(Self.chunkFrames), to: chunk)
            } catch {
                throw AudioRetimingError.retimeFailed(error)
            }
            guard status == .success else { throw AudioRetimingError.retimeFailed(nil) }
            for index in output.indices {
                output[index] += UnsafeBufferPointer(start: chunk.floatChannelData![index], count: Int(chunk.frameLength))
            }
        }
        return output.map { Array($0.dropFirst(latencyFrames)) }
    }

    // MARK: - Sample buffers

    private func sampleBuffers(from channels: [[Float]]) throws -> [CMSampleBuffer] {
        var description = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size * Self.channelCount),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size * Self.channelCount),
            mChannelsPerFrame: UInt32(Self.channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
        guard status == noErr, let format else { throw AudioRetimingError.bufferCreationFailed(status) }

        let frameCount = channels.first?.count ?? 0
        var buffers: [CMSampleBuffer] = []
        for start in stride(from: 0, to: frameCount, by: Self.chunkFrames) {
            let frames = min(Self.chunkFrames, frameCount - start)
            var interleaved = [Float](repeating: 0, count: frames * Self.channelCount)
            for frame in 0..<frames {
                for channel in 0..<Self.channelCount {
                    interleaved[frame * Self.channelCount + channel] = channels[channel][start + frame]
                }
            }
            let byteCount = interleaved.count * MemoryLayout<Float>.size
            var block: CMBlockBuffer?
            status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
            )
            guard status == kCMBlockBufferNoErr, let block else { throw AudioRetimingError.bufferCreationFailed(status) }
            status = interleaved.withUnsafeBytes { bytes in
                CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                                              offsetIntoDestination: 0, dataLength: byteCount)
            }
            guard status == kCMBlockBufferNoErr else { throw AudioRetimingError.bufferCreationFailed(status) }

            var sample: CMSampleBuffer?
            status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: frames, presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(Self.sampleRate)),
                packetDescriptions: nil, sampleBufferOut: &sample
            )
            guard status == noErr, let sample else { throw AudioRetimingError.bufferCreationFailed(status) }
            buffers.append(sample)
        }
        return buffers
    }
}
