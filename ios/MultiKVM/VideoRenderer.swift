import AVFoundation
import CoreMedia
import Foundation
import MultiKVMCore
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

struct RendererSnapshot: Equatable {
    var videoSize = PlaneSize(width: 0, height: 0)
    var dropped = 0
    var lastEnqueueMs = 0.0
    var framesPerSecond = 0.0
    var bitsPerSecond = 0.0
}

/// エンコード済みアクセスユニットを、待ち時間を足さずに表示する。
/// デコーダスレッドとメインスレッドが統計を読むので、数値は lock の内側だけを更新する。
/// AirPlay ミラーを止めないため、画面収録の防止は設定しない。
final class VideoRenderer {
    let view = VideoLayerView()
    var onNeedsKeyframe: (() -> Void)?
    private let recovery = H264RecoveryGate(waitingForKeyframe: true)
    private let stateLock = NSLock()
    private var videoSize = PlaneSize(width: 0, height: 0)
    private var dropped = 0
    private var lastEnqueueMs = 0.0
    private var stats = StreamStats()
    private var sps: Data?
    private var pps: Data?
    private var format: CMFormatDescription?
    private var formatKey: Data?

    func snapshot() -> RendererSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return RendererSnapshot(
            videoSize: videoSize,
            dropped: dropped,
            lastEnqueueMs: lastEnqueueMs,
            framesPerSecond: stats.framesPerSecond,
            bitsPerSecond: stats.bitsPerSecond
        )
    }

    func reset() {
        recovery.requestKeyframe()
        onNeedsKeyframe = nil
        stateLock.withLock {
            sps = nil
            pps = nil
            format = nil
            formatKey = nil
            videoSize = PlaneSize(width: 0, height: 0)
            stats = StreamStats()
            dropped = 0
            lastEnqueueMs = 0
        }
        view.displayLayer.flushAndRemoveImage()
    }

    func render(_ data: Data, width: Int32, height: Int32) {
        let started = CFAbsoluteTimeGetCurrent()
        let sample = stateLock.withLock { () -> CMSampleBuffer? in
            if width > 0, height > 0 {
                videoSize = PlaneSize(width: Double(width), height: Double(height))
            }
            let unit = H264AccessUnit.parseBitstream(data)
            if let found = unit.sps { sps = found }
            if let found = unit.pps { pps = found }
            if let sps, let pps {
                updateFormat(sps: sps, pps: pps)
            }
            guard recovery.accepts(unit) else {
                dropped += 1
                return nil
            }
            let slices = unit.sliceUnits
            guard !slices.isEmpty, let format else { return nil }
            return makeSample(slices, format: format)
        }
        guard let sample else { return }
        let layer = view.displayLayer
        if layer.status == .failed || !layer.isReadyForMoreMediaData {
            stateLock.withLock { dropped += 1 }
            recovery.requestKeyframe()
            layer.flushAndRemoveImage()
            onNeedsKeyframe?()
            return
        }
        layer.enqueue(sample)
        let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
        stateLock.withLock {
            lastEnqueueMs = elapsed
            stats.record(byteCount: data.count, at: CFAbsoluteTimeGetCurrent())
        }
    }

    private func updateFormat(sps: Data, pps: Data) {
        let key = sps + pps
        if key == formatKey { return }
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
        guard blockStatus == kCMBlockBufferNoErr, let block else { return nil }
        let replace = avcc.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard replace == kCMBlockBufferNoErr else { return nil }
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
        guard sampleStatus == noErr, let sample else { return nil }
        markDisplayImmediately(sample)
        return sample
    }

    private func markDisplayImmediately(_ sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else {
            return
        }
        let raw = CFArrayGetValueAtIndex(attachments, 0)
        let dictionary = unsafeBitCast(raw, to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}
