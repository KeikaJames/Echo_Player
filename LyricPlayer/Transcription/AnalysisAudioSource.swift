import Foundation
import AVFoundation
import FFmpegKit
import Libavcodec
import Libavformat
import Libavutil
import Libswresample
import Darwin

enum AnalysisAudioSource {
    enum PreparationError: LocalizedError {
        case noAudioTrack
        case cannotDecode
        case cannotCreateTemporaryFile
        case analysisTooLarge
        case notEnoughTemporarySpace
        case sourceChanged

        var errorDescription: String? {
            switch self {
            case .noAudioTrack:
                return "该媒体没有可分析的音轨。"
            case .cannotDecode:
                return "无法解码该媒体的音轨。"
            case .cannotCreateTemporaryFile:
                return "无法创建音频分析临时文件。"
            case .analysisTooLarge:
                return "音轨过长，已停止自动分析。"
            case .notEnoughTemporarySpace:
                return "可用磁盘空间不足，已停止自动分析。"
            case .sourceChanged:
                return "媒体文件已发生变化，请重新分析。"
            }
        }
    }

    private static let maximumTemporaryPCMBytes: Int64 = 2 * 1024 * 1024 * 1024
    private static let temporarySpaceReserve: Int64 = 512 * 1024 * 1024
    private static let runtimeSpaceReserve: Int64 = 256 * 1024 * 1024
    private static let capacityCheckIntervalFrames: AVAudioFramePosition = 32 * 1024 * 1024
    private static let temporaryFilePrefix = "LyricPlayer-Analysis-"
    private static let abandonedTemporaryFileCleanup: Void = {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let files = try? manager.contentsOfDirectory(at: directory,
                                                           includingPropertiesForKeys: keys) else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let legacyDeadline = Date().addingTimeInterval(-24 * 60 * 60)

        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix(temporaryFilePrefix), name.hasSuffix(".wav") else { continue }
            let values = try? file.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true || values?.isSymbolicLink == true else { continue }

            let stem = name.dropFirst(temporaryFilePrefix.count).dropLast(4)
            if let separator = stem.firstIndex(of: "-"),
               let pid = Int32(stem[..<separator]), pid > 0 {
                guard pid != currentPID else { continue }
                errno = 0
                let isRunning = Darwin.kill(pid, 0) == 0 || errno == EPERM
                if !isRunning { try? manager.removeItem(at: file) }
            } else if let date = values?.contentModificationDate, date < legacyDeadline {
                // 旧版文件名没有 PID，只清理明显超龄的遗留文件。
                try? manager.removeItem(at: file)
            }
        }
    }()

    final class Prepared: @unchecked Sendable {
        let url: URL
        let sourceIdentity: MediaFileIdentity
        private let removesWhenReleased: Bool

        fileprivate init(url: URL,
                         sourceIdentity: MediaFileIdentity,
                         removesWhenReleased: Bool) {
            self.url = url
            self.sourceIdentity = sourceIdentity
            self.removesWhenReleased = removesWhenReleased
        }

        deinit {
            if removesWhenReleased {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private final class CancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    static func prepare(url: URL,
                        expectedSourceIdentity: MediaFileIdentity? = nil,
                        preferredAudioTrackID: CMPersistentTrackID? = nil,
                        preferredAudioStreamIndex: Int32? = nil) async throws -> Prepared {
        _ = abandonedTemporaryFileCleanup
        try Task.checkCancellation()
        guard let sourceIdentity = MediaFileIdentity(url: url) else {
            throw PreparationError.cannotDecode
        }
        if let expectedSourceIdentity,
           !sourceIdentity.hasSameContent(as: expectedSourceIdentity) {
            throw PreparationError.sourceChanged
        }
        if preferredAudioTrackID == nil, preferredAudioStreamIndex == nil,
           (try? AVAudioFile(forReading: url)) != nil {
            guard sourceIdentity.isCurrentContent(url: url) else { throw PreparationError.sourceChanged }
            return Prepared(url: url,
                            sourceIdentity: sourceIdentity,
                            removesWhenReleased: false)
        }

        let cancellation = CancellationState()
        let worker = Task.detached(priority: .utility) {
            try decodeToTemporaryPCM(url: url,
                                     sourceIdentity: sourceIdentity,
                                     preferredAudioTrackID: preferredAudioTrackID,
                                     preferredAudioStreamIndex: preferredAudioStreamIndex,
                                     cancellation: cancellation)
        }
        return try await withTaskCancellationHandler {
            let prepared = try await worker.value
            try Task.checkCancellation()
            return prepared
        } onCancel: {
            cancellation.cancel()
            worker.cancel()
        }
    }

    private static func decodeToTemporaryPCM(url: URL,
                                             sourceIdentity: MediaFileIdentity,
                                             preferredAudioTrackID: CMPersistentTrackID?,
                                             preferredAudioStreamIndex: Int32?,
                                             cancellation: CancellationState) throws -> Prepared {
        try checkCancellation(cancellation)
        guard sourceIdentity.isCurrentContent(url: url) else { throw PreparationError.sourceChanged }

        var formatContext = avformat_alloc_context()
        guard let allocatedContext = formatContext else { throw PreparationError.cannotDecode }
        allocatedContext.pointee.interrupt_callback = AVIOInterruptCB(
            callback: { opaque in
                guard let opaque else { return 0 }
                let state = Unmanaged<CancellationState>.fromOpaque(opaque).takeUnretainedValue()
                return state.isCancelled ? 1 : 0
            },
            opaque: Unmanaged.passUnretained(cancellation).toOpaque()
        )
        defer {
            formatContext?.pointee.interrupt_callback.callback = nil
            formatContext?.pointee.interrupt_callback.opaque = nil
            avformat_close_input(&formatContext)
        }

        let openResult = avformat_open_input(&formatContext, url.path, nil, nil)
        guard openResult >= 0, let formatContext else {
            try checkCancellation(cancellation)
            throw PreparationError.cannotDecode
        }
        guard sourceIdentity.isCurrentContent(url: url) else { throw PreparationError.sourceChanged }
        guard avformat_find_stream_info(formatContext, nil) >= 0 else {
            try checkCancellation(cancellation)
            throw PreparationError.cannotDecode
        }
        try checkCancellation(cancellation)

        let videoStreamIndex = av_find_best_stream(formatContext,
                                                   AVMEDIA_TYPE_VIDEO,
                                                   -1, -1, nil, 0)
        let streamIndex: Int32
        if let preferredAudioStreamIndex {
            let index = Int(preferredAudioStreamIndex)
            if index >= 0, index < Int(formatContext.pointee.nb_streams),
               let stream = formatContext.pointee.streams[index],
               stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                streamIndex = preferredAudioStreamIndex
            } else {
                streamIndex = -1
            }
        } else if let preferredAudioTrackID {
            streamIndex = (0..<Int(formatContext.pointee.nb_streams)).first { index in
                guard let stream = formatContext.pointee.streams[index],
                      stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO else { return false }
                return stream.pointee.id == preferredAudioTrackID
            }.map(Int32.init) ?? -1
        } else {
            streamIndex = av_find_best_stream(formatContext,
                                              AVMEDIA_TYPE_AUDIO,
                                              -1, videoStreamIndex, nil, 0)
        }
        guard streamIndex >= 0,
              let stream = formatContext.pointee.streams[Int(streamIndex)],
              let parameters = stream.pointee.codecpar,
              let decoder = avcodec_find_decoder(parameters.pointee.codec_id) else {
            throw PreparationError.noAudioTrack
        }

        var codecContext = avcodec_alloc_context3(decoder)
        defer { avcodec_free_context(&codecContext) }
        guard let codecContext,
              avcodec_parameters_to_context(codecContext, parameters) >= 0,
              avcodec_open2(codecContext, decoder, nil) >= 0 else {
            throw PreparationError.cannotDecode
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(temporaryFilePrefix)\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).wav")
        let frameLimit = try temporaryPCMFrameLimit()
        var keepTemporaryFile = false
        defer {
            if !keepTemporaryFile {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: 16_000,
                                               channels: 1,
                                               interleaved: false),
              let outputFile = try? AVAudioFile(forWriting: temporaryURL,
                                                settings: outputFormat.settings,
                                                commonFormat: .pcmFormatInt16,
                                                interleaved: false) else {
            throw PreparationError.cannotCreateTemporaryFile
        }

        var packetStorage = av_packet_alloc()
        var frameStorage = av_frame_alloc()
        guard let packet = packetStorage, let frame = frameStorage else {
            throw PreparationError.cannotDecode
        }
        defer {
            av_packet_free(&packetStorage)
            av_frame_free(&frameStorage)
        }

        let resampler = AudioResampler(outputFormat: outputFormat)
        var wroteFrames: AVAudioFramePosition = 0
        var nextCapacityCheck = capacityCheckIntervalFrames
        let timelineToleranceFrames = AVAudioFramePosition(outputFormat.sampleRate * 0.02)
        let streamTimeBase = stream.pointee.time_base
        let formatStartSeconds = formatContext.pointee.start_time == swift_AV_NOPTS_VALUE
            ? 0
            : Double(formatContext.pointee.start_time) / Double(AV_TIME_BASE)

        func validateOutputBudget() throws {
            guard wroteFrames <= frameLimit else { throw PreparationError.analysisTooLarge }
            guard wroteFrames >= nextCapacityCheck else { return }
            guard availableTemporaryCapacity() > runtimeSpaceReserve else {
                throw PreparationError.notEnoughTemporarySpace
            }
            nextCapacityCheck += capacityCheckIntervalFrames
        }

        func timelineStartFrame(for frame: UnsafeMutablePointer<AVFrame>) throws -> AVAudioFramePosition? {
            var timestamp = frame.pointee.best_effort_timestamp
            if timestamp == swift_AV_NOPTS_VALUE { timestamp = frame.pointee.pts }
            if timestamp == swift_AV_NOPTS_VALUE { timestamp = frame.pointee.pkt_dts }
            guard timestamp != swift_AV_NOPTS_VALUE,
                  streamTimeBase.num > 0, streamTimeBase.den > 0 else { return nil }
            let seconds = Double(timestamp) * Double(streamTimeBase.num)
                / Double(streamTimeBase.den) - formatStartSeconds
            guard let outputFrame = boundedTimelineFrame(seconds * outputFormat.sampleRate,
                                                         maximum: frameLimit) else {
                throw PreparationError.analysisTooLarge
            }
            return outputFrame
        }

        func writeSilence(_ frameCount: AVAudioFramePosition) throws {
            var remaining = frameCount
            while remaining > 0 {
                try checkCancellation(cancellation)
                let count = AVAudioFrameCount(min(remaining, 65_536))
                guard wroteFrames + AVAudioFramePosition(count) <= frameLimit,
                      let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                    frameCapacity: count),
                      let samples = buffer.int16ChannelData?[0] else {
                    throw PreparationError.analysisTooLarge
                }
                memset(samples, 0, Int(count) * MemoryLayout<Int16>.size)
                buffer.frameLength = count
                try outputFile.write(from: buffer)
                wroteFrames += AVAudioFramePosition(count)
                remaining -= AVAudioFramePosition(count)
                try validateOutputBudget()
            }
        }

        func write(_ buffer: AVAudioPCMBuffer,
                   skipping skippedFrames: AVAudioFramePosition) throws -> AVAudioFramePosition {
            let frameLength = AVAudioFramePosition(buffer.frameLength)
            guard skippedFrames < frameLength else { return 0 }
            guard skippedFrames > 0 else {
                try outputFile.write(from: buffer)
                return frameLength
            }

            let remaining = AVAudioFrameCount(frameLength - skippedFrames)
            guard let source = buffer.int16ChannelData?[0],
                  let trimmed = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                 frameCapacity: remaining),
                  let destination = trimmed.int16ChannelData?[0] else {
                throw PreparationError.cannotDecode
            }
            destination.update(from: source.advanced(by: Int(skippedFrames)),
                               count: Int(remaining))
            trimmed.frameLength = remaining
            try outputFile.write(from: trimmed)
            return AVAudioFramePosition(remaining)
        }

        enum DrainResult {
            case needsInput
            case endOfStream
        }

        func receiveFrames() throws -> DrainResult {
            while true {
                let receiveResult = avcodec_receive_frame(codecContext, frame)
                if receiveResult >= 0 {
                    try checkCancellation(cancellation)
                    defer { av_frame_unref(frame) }
                    let desiredStart = try timelineStartFrame(for: frame)
                    if let desiredStart,
                       desiredStart > wroteFrames + timelineToleranceFrames {
                        try writeSilence(desiredStart - wroteFrames)
                    }
                    guard let buffer = try resampler.convert(
                        frame: frame,
                        maximumFrames: frameLimit - wroteFrames
                    ) else { continue }
                    let skippedFrames: AVAudioFramePosition
                    if let desiredStart,
                       wroteFrames > desiredStart + timelineToleranceFrames {
                        skippedFrames = wroteFrames - desiredStart
                    } else {
                        skippedFrames = 0
                    }
                    wroteFrames += try write(buffer, skipping: skippedFrames)
                    try validateOutputBudget()
                } else if receiveResult == swift_AVERROR(EAGAIN) {
                    return .needsInput
                } else if receiveResult == swift_AVERROR_EOF {
                    return .endOfStream
                } else {
                    try checkCancellation(cancellation)
                    throw PreparationError.cannotDecode
                }
            }
        }

        while true {
            try checkCancellation(cancellation)
            let readResult = av_read_frame(formatContext, packet)
            if readResult == swift_AVERROR_EOF { break }
            if readResult == swift_AVERROR(EAGAIN) { continue }
            guard readResult >= 0 else {
                try checkCancellation(cancellation)
                throw PreparationError.cannotDecode
            }
            do {
                defer { av_packet_unref(packet) }
                guard packet.pointee.stream_index == streamIndex else { continue }

                var sendResult = avcodec_send_packet(codecContext, packet)
                if sendResult == swift_AVERROR(EAGAIN) {
                    guard try receiveFrames() == .needsInput else {
                        throw PreparationError.cannotDecode
                    }
                    sendResult = avcodec_send_packet(codecContext, packet)
                }
                guard sendResult >= 0 else {
                    try checkCancellation(cancellation)
                    throw PreparationError.cannotDecode
                }
                guard try receiveFrames() == .needsInput else {
                    throw PreparationError.cannotDecode
                }
            }
        }

        try checkCancellation(cancellation)
        let flushResult = avcodec_send_packet(codecContext, nil)
        guard flushResult >= 0 || flushResult == swift_AVERROR_EOF else {
            try checkCancellation(cancellation)
            throw PreparationError.cannotDecode
        }
        guard try receiveFrames() == .endOfStream else {
            throw PreparationError.cannotDecode
        }
        wroteFrames += try resampler.flush(to: outputFile,
                                           maximumFrames: frameLimit - wroteFrames)
        try validateOutputBudget()
        try checkCancellation(cancellation)
        guard sourceIdentity.isCurrentContent(url: url) else { throw PreparationError.sourceChanged }

        guard wroteFrames > 0 else { throw PreparationError.noAudioTrack }
        keepTemporaryFile = true
        return Prepared(url: temporaryURL,
                        sourceIdentity: sourceIdentity,
                        removesWhenReleased: true)
    }

    private static func checkCancellation(_ state: CancellationState) throws {
        if state.isCancelled || Task.isCancelled {
            throw CancellationError()
        }
    }

    private static func temporaryPCMFrameLimit() throws -> AVAudioFramePosition {
        let available = availableTemporaryCapacity()
        let byteLimit = try temporaryPCMByteLimit(availableCapacity: available)
        return AVAudioFramePosition(byteLimit / Int64(MemoryLayout<Int16>.size))
    }

    static func temporaryPCMByteLimit(availableCapacity: Int64) throws -> Int64 {
        guard availableCapacity > temporarySpaceReserve else {
            throw PreparationError.notEnoughTemporarySpace
        }
        return min(maximumTemporaryPCMBytes, availableCapacity - temporarySpaceReserve)
    }

    static func boundedTimelineFrame(_ value: Double,
                                     maximum: AVAudioFramePosition) -> AVAudioFramePosition? {
        let maximumExactFrame = AVAudioFramePosition(9_007_199_254_740_991)
        guard value.isFinite, maximum >= 0 else { return nil }
        let rounded = max(0, value).rounded()
        guard rounded <= Double(min(maximum, maximumExactFrame)) else { return nil }
        return AVAudioFramePosition(rounded)
    }

    private static func availableTemporaryCapacity() -> Int64 {
        let path = FileManager.default.temporaryDirectory.path
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }
}

private final class AudioResampler {
    private let outputFormat: AVAudioFormat
    private var context: OpaquePointer?
    private var inputFormat = AV_SAMPLE_FMT_NONE
    private var inputSampleRate: Int32 = 0
    private var inputChannelCount: Int32 = 0

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    deinit {
        swr_free(&context)
    }

    func convert(frame: UnsafeMutablePointer<AVFrame>,
                 maximumFrames: AVAudioFramePosition) throws -> AVAudioPCMBuffer? {
        try configureIfNeeded(for: frame)
        let capacity = swr_get_out_samples(context, frame.pointee.nb_samples)
        guard capacity > 0 else { throw AnalysisAudioSource.PreparationError.cannotDecode }
        guard AVAudioFramePosition(capacity) <= maximumFrames else {
            throw AnalysisAudioSource.PreparationError.analysisTooLarge
        }
        guard
              let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                            frameCapacity: AVAudioFrameCount(capacity)),
              let channel = buffer.int16ChannelData?[0] else {
            throw AnalysisAudioSource.PreparationError.cannotDecode
        }

        var outputPlanes: [UnsafeMutablePointer<UInt8>?] = [
            UnsafeMutableRawPointer(channel).assumingMemoryBound(to: UInt8.self),
        ]
        let planeCount = av_sample_fmt_is_planar(inputFormat) != 0
            ? Int(inputChannelCount)
            : 1
        guard let extendedData = frame.pointee.extended_data else {
            throw AnalysisAudioSource.PreparationError.cannotDecode
        }
        var inputPlanes: [UnsafePointer<UInt8>?] = (0 ..< planeCount).map {
            UnsafePointer(extendedData[$0])
        }
        let converted = swr_convert(context, &outputPlanes, capacity,
                                    &inputPlanes, frame.pointee.nb_samples)
        guard converted >= 0 else { throw AnalysisAudioSource.PreparationError.cannotDecode }
        guard converted > 0 else { return nil }

        buffer.frameLength = AVAudioFrameCount(converted)
        return buffer
    }

    func flush(to file: AVAudioFile,
               maximumFrames: AVAudioFramePosition) throws -> AVAudioFramePosition {
        var total: AVAudioFramePosition = 0
        while let context {
            let capacity = swr_get_out_samples(context, 0)
            guard capacity > 0 else { break }
            guard AVAudioFramePosition(capacity) <= maximumFrames - total else {
                throw AnalysisAudioSource.PreparationError.analysisTooLarge
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                frameCapacity: AVAudioFrameCount(capacity)),
                  let channel = buffer.int16ChannelData?[0] else {
                throw AnalysisAudioSource.PreparationError.cannotDecode
            }
            var outputPlanes: [UnsafeMutablePointer<UInt8>?] = [
                UnsafeMutableRawPointer(channel).assumingMemoryBound(to: UInt8.self),
            ]
            let converted = swr_convert(context, &outputPlanes, capacity, nil, 0)
            guard converted >= 0 else { throw AnalysisAudioSource.PreparationError.cannotDecode }
            guard converted > 0 else { break }
            buffer.frameLength = AVAudioFrameCount(converted)
            try file.write(from: buffer)
            total += AVAudioFramePosition(converted)
        }
        return total
    }

    private func configureIfNeeded(for frame: UnsafeMutablePointer<AVFrame>) throws {
        let format = AVSampleFormat(rawValue: frame.pointee.format)
        let sampleRate = frame.pointee.sample_rate
        let channelCount = frame.pointee.ch_layout.nb_channels
        guard format != AV_SAMPLE_FMT_NONE, sampleRate > 0, channelCount > 0 else {
            throw AnalysisAudioSource.PreparationError.cannotDecode
        }
        guard context == nil || format != inputFormat || sampleRate != inputSampleRate
                || channelCount != inputChannelCount else { return }

        swr_free(&context)
        var outputLayout = AVChannelLayout()
        av_channel_layout_default(&outputLayout, 1)
        defer { av_channel_layout_uninit(&outputLayout) }
        var inputLayout = frame.pointee.ch_layout
        let result = swr_alloc_set_opts2(&context,
                                         &outputLayout, AV_SAMPLE_FMT_S16P, 16_000,
                                         &inputLayout, format, sampleRate,
                                         0, nil)
        guard result >= 0, swr_init(context) >= 0 else {
            swr_free(&context)
            throw AnalysisAudioSource.PreparationError.cannotDecode
        }
        inputFormat = format
        inputSampleRate = sampleRate
        inputChannelCount = channelCount
    }
}
