import AVFoundation
import CoreMedia
import Foundation
import MultiKVMCore
import OSLog
import QuartzCore
import UIKit

final class VideoLayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        guard let sampleLayer = layer as? AVSampleBufferDisplayLayer else {
            fatalError("layerClass が AVSampleBufferDisplayLayer ではありません")
        }
        return sampleLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

struct RendererFailure: Equatable {
    enum Operation: String { case format, block, copy, sample, attachments }
    let operation: Operation
    let status: OSStatus
}

struct RendererSnapshot: Equatable {
    var videoSize = PlaneSize(width: 0, height: 0)
    var dropped = 0
    var lastEnqueueMs = 0.0
    var framesPerSecond = 0.0
    var bitsPerSecond = 0.0
    var processingFailures = 0
    var lastFailure: RendererFailure?
}

/// エンコード済みアクセスユニットを、待ち時間を足さずに表示する。
/// UIKit と表示状態は MainActor が所有する。デコーダからは FIFO で転送する。
/// AirPlay ミラーを止めないため、画面収録の防止は設定しない。
@MainActor
final class VideoRenderer {
    let view = VideoLayerView()
    var onNeedsKeyframe: (() -> Void)?
    private let recovery = H264RecoveryGate(waitingForKeyframe: true)
    private var videoSize = PlaneSize(width: 0, height: 0)
    private var dropped = 0
    private var lastEnqueueMs = 0.0
    private var stats = StreamStats()
    private var sps: Data?
    private var pps: Data?
    private var format: CMFormatDescription?
    private var formatKey: Data?
    private var processingFailures = 0
    private var lastFailure: RendererFailure?
    private let logger = Logger(subsystem: "dev.multikvm.ios", category: "VideoRenderer")

    func snapshot() -> RendererSnapshot {
        return RendererSnapshot(
            videoSize: videoSize,
            dropped: dropped,
            lastEnqueueMs: lastEnqueueMs,
            framesPerSecond: stats.framesPerSecond,
            bitsPerSecond: stats.bitsPerSecond,
            processingFailures: processingFailures, lastFailure: lastFailure
        )
    }

    func reset() {
        recovery.requestKeyframe()
        onNeedsKeyframe = nil
        sps = nil
        pps = nil
        format = nil
        formatKey = nil
        videoSize = PlaneSize(width: 0, height: 0)
        stats = StreamStats()
        dropped = 0
        lastEnqueueMs = 0
        processingFailures = 0
        lastFailure = nil
        view.displayLayer.flushAndRemoveImage()
    }

    func render(_ data: Data, width: Int32, height: Int32) {
        let started = CFAbsoluteTimeGetCurrent()
        let sample = makeAccessUnitSample(data, width: width, height: height)
        guard let sample else { return }
        let layer = view.displayLayer
        if layer.status == .failed || !layer.isReadyForMoreMediaData {
            dropped += 1
            recovery.requestKeyframe()
            layer.flushAndRemoveImage()
            onNeedsKeyframe?()
            return
        }
        layer.enqueue(sample)
        lastEnqueueMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
        stats.record(byteCount: data.count, at: CFAbsoluteTimeGetCurrent())
    }

    private func makeAccessUnitSample(_ data: Data, width: Int32, height: Int32) -> CMSampleBuffer? {
        if width > 0, height > 0 {
            videoSize = PlaneSize(width: Double(width), height: Double(height))
        }
        let unit = H264AccessUnit.parseBitstream(data)
        if let found = unit.sps { sps = found }
        if let found = unit.pps { pps = found }
        if let sps, let pps {
            guard updateFormat(sps: sps, pps: pps) else { return nil }
        }
        guard recovery.accepts(unit) else {
            dropped += 1
            return nil
        }
        let slices = unit.sliceUnits
        guard !slices.isEmpty, let format else { return nil }
        return makeSample(slices, format: format)
    }

    private func recordFailure(_ operation: RendererFailure.Operation, _ status: OSStatus) {
        processingFailures += 1
        let failure = RendererFailure(operation: operation, status: status)
        if lastFailure != failure {
            logger.error("CoreMedia \(operation.rawValue, privacy: .public) failed (\(status))")
        }
        lastFailure = failure
        recovery.requestKeyframe()
        onNeedsKeyframe?()
    }

    private func updateFormat(sps: Data, pps: Data) -> Bool {
        let key = sps + pps
        if key == formatKey { return true }
        var description: CMFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsBase = spsRaw.baseAddress, let ppsBase = ppsRaw.baseAddress else {
                    return kCMFormatDescriptionError_InvalidParameter
                }
                let spsPointer = spsBase.assumingMemoryBound(to: UInt8.self)
                let ppsPointer = ppsBase.assumingMemoryBound(to: UInt8.self)
                var pointers = [spsPointer, ppsPointer]
                var sizes = [sps.count, pps.count]
                return pointers.withUnsafeMutableBufferPointer { pointerBuffer in
                    sizes.withUnsafeMutableBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description
                        )
                    }
                }
            }
        }
        if status == noErr, let description {
            format = description
            formatKey = key
            return true
        } else {
            recordFailure(.format, status)
            return false
        }
    }

    private func makeSample(_ slices: [Data], format: CMFormatDescription) -> CMSampleBuffer? {
        let avcc = H264AccessUnit(nalUnits: slices).lengthPrefixed()
        var block: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &block
        )
        guard blockStatus == kCMBlockBufferNoErr, let block else {
            recordFailure(.block, blockStatus)
            return nil
        }
        let replace = avcc.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard replace == kCMBlockBufferNoErr else {
            recordFailure(.copy, replace)
            return nil
        }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid
        )
        var size = avcc.count
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        )
        guard sampleStatus == noErr, let sample else {
            recordFailure(.sample, sampleStatus)
            return nil
        }
        guard markDisplayImmediately(sample) else { return nil }
        return sample
    }

    private func markDisplayImmediately(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0
        else {
            recordFailure(.attachments, kCMFormatDescriptionError_InvalidParameter)
            return false
        }
        let raw = CFArrayGetValueAtIndex(attachments, 0)
        let dictionary = unsafeBitCast(raw, to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
        return true
    }
}
