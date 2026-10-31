import AVKit
import WebRTC

/**
 * Картинка-в-картинке для видеозвонка: видео собеседника дублируется в
 * AVSampleBufferDisplayLayer внутри AVPictureInPictureVideoCallViewController;
 * при сворачивании приложения система сама переносит его в плавающее окно.
 */
final class SampleBufferVideoView: UIView, RTCVideoRenderer {
    /// Свой слой, а не `layer` вида: кадры приходят из потока WebRTC, UIView трогать там нельзя.
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var rotation: RTCVideoRotation = ._0
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(displayLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setSize(_ size: CGSize) {}

    /// Кадр WebRTC → CMSampleBuffer (показать сразу). H.264 приходит готовым CVPixelBuffer,
    /// VP8/VP9 — I420, его перекладываем в NV12.
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, let pixelBuffer = pixelBuffer(frame.buffer), let sample = sampleBuffer(pixelBuffer) else { return }
        if frame.rotation != rotation {
            rotation = frame.rotation
            let angle = CGFloat(frame.rotation.rawValue) * .pi / 180
            DispatchQueue.main.async { self.transform = CGAffineTransform(rotationAngle: angle) }
        }
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sample)
    }

    private func pixelBuffer(_ buffer: RTCVideoFrameBuffer) -> CVPixelBuffer? {
        if let cv = buffer as? RTCCVPixelBuffer { return cv.pixelBuffer }
        let i420 = buffer.toI420()
        let size = CGSize(width: Int(i420.width), height: Int(i420.height))
        if pool == nil || poolSize != size {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: Int(i420.width),
                kCVPixelBufferHeightKey as String: Int(i420.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            poolSize = size
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        let w = Int(i420.width), h = Int(i420.height)
        guard let yDst = CVPixelBufferGetBaseAddressOfPlane(out, 0)?.assumingMemoryBound(to: UInt8.self),
              let uvDst = CVPixelBufferGetBaseAddressOfPlane(out, 1)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(out, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(out, 1)
        for row in 0..<h {
            memcpy(yDst + row * yStride, i420.dataY + row * Int(i420.strideY), w)
        }
        let cw = (w + 1) / 2, ch = (h + 1) / 2
        for row in 0..<ch {
            let u = i420.dataU + row * Int(i420.strideU)
            let v = i420.dataV + row * Int(i420.strideV)
            let dst = uvDst + row * uvStride
            for col in 0..<cw {
                dst[col * 2] = u[col]
                dst[col * 2 + 1] = v[col]
            }
        }
        return out
    }

    private func sampleBuffer(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

/// Якорь PiP на экране звонка: видео собеседника подключено к окну PiP, пока экран открыт.
final class CallPipAnchor: UIView {
    private let pipView = SampleBufferVideoView()
    private var controller: AVPictureInPictureController?
    private weak var track: RTCVideoTrack?

    func attach(_ track: RTCVideoTrack) {
        guard track !== self.track else { return }
        detach()
        self.track = track
        track.add(pipView)
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let content = AVPictureInPictureVideoCallViewController()
        content.preferredContentSize = CGSize(width: 9, height: 16)
        pipView.frame = content.view.bounds
        pipView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        content.view.addSubview(pipView)
        let pip = AVPictureInPictureController(contentSource: .init(activeVideoCallSourceView: self, contentViewController: content))
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        controller = pip
    }

    func detach() {
        controller?.stopPictureInPicture()
        controller = nil
        track?.remove(pipView)
        track = nil
        pipView.removeFromSuperview()
    }
}
