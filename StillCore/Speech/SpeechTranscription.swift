import AVFoundation
import Speech

public enum SpeechTranscriptionError: Error, LocalizedError {
    case unsupportedLanguage(String)
    case noSound
    case unreadableSound(Error?)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLanguage:
            String(localized: "This language can’t be transcribed on this device.", bundle: #bundle)
        case .noSound:
            String(localized: "This video has no sound.", bundle: #bundle)
        case .unreadableSound:
            String(localized: "The sound couldn’t be read.", bundle: #bundle)
        }
    }
}

/// Transcribes a video's speech on the device, word by word, for captions drawn into a Live Photo.
public enum SpeechTranscription {
    /// The language the device transcribes for `language`, a BCP 47 tag such as “en-US”; nil when it can't.
    public static func supportedLanguage(for language: String) async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language))
    }

    /// Everything `source` says in `language`, at source times. Fetches the language's speech model first if the
    /// device doesn't have it yet.
    public static func transcribe(_ source: SourceMedia, language: Locale) async throws -> Transcript {
        guard source.audioTrack != nil else { throw SpeechTranscriptionError.noSound }
        let transcriber = SpeechTranscriber(
            locale: language, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange]
        )
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechTranscriptionError.unsupportedLanguage(language.identifier(.bcp47))
        }

        let results = Task {
            var phrases: [[SpokenWord]] = []
            for try await result in transcriber.results {
                let words = result.text.runs.compactMap { run -> SpokenWord? in
                    guard let range = run.audioTimeRange else { return nil }
                    return SpokenWord(text: String(result.text[run.range].characters),
                                      start: range.start.seconds, end: range.end.seconds)
                }
                if !words.isEmpty { phrases.append(words) }
            }
            return phrases
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            if let end = try await analyzer.analyzeSequence(sound(of: source, as: format)) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            results.cancel()
            throw error
        }
        let phrases = try await results.value.sorted { $0[0].start < $1[0].start }
        return Transcript(language: language.identifier(.bcp47), phrases: phrases)
    }

    /// The source's sound in the analyzer's format, stamped with source times.
    private static func sound(of source: SourceMedia, as format: AVAudioFormat) -> AsyncThrowingStream<AnalyzerInput, Error> {
        // The format crosses to the reading task as its description, which is plain data.
        let description = format.streamDescription.pointee
        return AsyncThrowingStream { continuation in
            let reading = Task.detached(priority: .utility) {
                do {
                    var description = description
                    guard let format = AVAudioFormat(streamDescription: &description) else {
                        throw SpeechTranscriptionError.unreadableSound(nil)
                    }
                    let settings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: format.sampleRate,
                        AVNumberOfChannelsKey: format.channelCount,
                        AVLinearPCMBitDepthKey: description.mBitsPerChannel,
                        AVLinearPCMIsFloatKey: description.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsNonInterleaved: !format.isInterleaved,
                    ]
                    guard let track = source.audioTrack else { throw SpeechTranscriptionError.noSound }
                    let reader = try AVAssetReader(asset: source.asset)
                    let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
                    guard reader.canAdd(output) else { throw SpeechTranscriptionError.unreadableSound(nil) }
                    reader.add(output)
                    guard reader.startReading() else { throw SpeechTranscriptionError.unreadableSound(reader.error) }
                    while let sample = output.copyNextSampleBuffer() {
                        try Task.checkCancellation()
                        let frames = CMSampleBufferGetNumSamples(sample)
                        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
                        else { continue }
                        buffer.frameLength = AVAudioFrameCount(frames)
                        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                            sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
                        )
                        guard status == noErr else { throw SpeechTranscriptionError.unreadableSound(nil) }
                        continuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: CMSampleBufferGetPresentationTimeStamp(sample)))
                    }
                    if reader.status == .failed { throw SpeechTranscriptionError.unreadableSound(reader.error) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reading.cancel() }
        }
    }
}
