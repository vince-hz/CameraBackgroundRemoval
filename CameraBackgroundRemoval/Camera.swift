/*
 See the License.txt file for this sample’s licensing information.
 */

import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import os.log
import UIKit
import Vision

class Camera: NSObject {
    private let captureSession = AVCaptureSession()
    private var isCaptureSessionConfigured = false
    private var deviceInput: AVCaptureDeviceInput?
    private var photoOutput: AVCapturePhotoOutput?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var sessionQueue: DispatchQueue!

    var virtualBackgroundImage: CIImage = CIImage(color: CIColor.clear)
    let virtualBackgroundFilter = CIFilter.blendWithMask()
    
    
    private var allCaptureDevices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTrueDepthCamera, .builtInDualCamera, .builtInDualWideCamera, .builtInWideAngleCamera, .builtInDualWideCamera],
            mediaType: .video,
            position: .front
        ).devices
    }

    private var frontCaptureDevices: [AVCaptureDevice] {
        allCaptureDevices
            .filter { $0.position == .front }
    }

    private var backCaptureDevices: [AVCaptureDevice] {
        allCaptureDevices
            .filter { $0.position == .back }
    }

    private var captureDevices: [AVCaptureDevice] {
        var devices = [AVCaptureDevice]()
        #if os(macOS) || (os(iOS) && targetEnvironment(macCatalyst))
            devices += allCaptureDevices
        #else
            if let backDevice = backCaptureDevices.first {
                devices += [backDevice]
            }
            if let frontDevice = frontCaptureDevices.first {
                devices += [frontDevice]
            }
        #endif
        return devices
    }

    private var availableCaptureDevices: [AVCaptureDevice] {
        captureDevices
            .filter { $0.isConnected }
            .filter { !$0.isSuspended }
    }

    private var captureDevice: AVCaptureDevice? {
        didSet {
            guard let captureDevice = captureDevice else { return }
            logger.debug("Using capture device: \(captureDevice.localizedName)")
            sessionQueue.async {
                self.updateSessionForCaptureDevice(captureDevice)
            }
        }
    }

    var isRunning: Bool {
        captureSession.isRunning
    }

    var isUsingFrontCaptureDevice: Bool {
        guard let captureDevice = captureDevice else { return false }
        return frontCaptureDevices.contains(captureDevice)
    }

    var isUsingBackCaptureDevice: Bool {
        guard let captureDevice = captureDevice else { return false }
        return backCaptureDevices.contains(captureDevice)
    }

    private var addToPhotoStream: ((AVCapturePhoto) -> Void)?

    private var addToPreviewStream: ((CIImage) -> Void)?

    var isPreviewPaused = false

    lazy var previewStream: AsyncStream<CIImage> = AsyncStream { continuation in
        addToPreviewStream = { ciImage in
            if !self.isPreviewPaused {
                continuation.yield(ciImage)
            }
        }
    }

    lazy var photoStream: AsyncStream<AVCapturePhoto> = AsyncStream { continuation in
        addToPhotoStream = { photo in
            continuation.yield(photo)
        }
    }

    override init() {
        super.init()
        initialize()
    }

    private func initialize() {
        sessionQueue = DispatchQueue(label: "session queue")

        captureDevice = availableCaptureDevices.first ?? AVCaptureDevice.default(for: .video)

        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(updateForDeviceOrientation), name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    private func configureCaptureSession(completionHandler: (_ success: Bool) -> Void) {
        var success = false

        captureSession.beginConfiguration()

        defer {
            self.captureSession.commitConfiguration()
            completionHandler(success)
        }

        guard
            let captureDevice = captureDevice,
            let deviceInput = try? AVCaptureDeviceInput(device: captureDevice)
        else {
            logger.error("Failed to obtain video input.")
            return
        }

        let photoOutput = AVCapturePhotoOutput()

        captureSession.sessionPreset = .iFrame960x540
//        captureSession.sessionPreset = AVCaptureSession.Preset.photo

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "VideoDataOutputQueue"))

        guard captureSession.canAddInput(deviceInput) else {
            logger.error("Unable to add device input to capture session.")
            return
        }
        guard captureSession.canAddOutput(photoOutput) else {
            logger.error("Unable to add photo output to capture session.")
            return
        }
        guard captureSession.canAddOutput(videoOutput) else {
            logger.error("Unable to add video output to capture session.")
            return
        }

        captureSession.addInput(deviceInput)
        captureSession.addOutput(photoOutput)
        captureSession.addOutput(videoOutput)

        self.deviceInput = deviceInput
        self.photoOutput = photoOutput
        self.videoOutput = videoOutput

        photoOutput.isHighResolutionCaptureEnabled = true
        photoOutput.maxPhotoQualityPrioritization = .quality

        updateVideoOutputConnection()

        isCaptureSessionConfigured = true

        success = true
    }

    private func checkAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            logger.debug("Camera access authorized.")
            return true
        case .notDetermined:
            logger.debug("Camera access not determined.")
            sessionQueue.suspend()
            let status = await AVCaptureDevice.requestAccess(for: .video)
            sessionQueue.resume()
            return status
        case .denied:
            logger.debug("Camera access denied.")
            return false
        case .restricted:
            logger.debug("Camera library access restricted.")
            return false
        @unknown default:
            return false
        }
    }

    private func deviceInputFor(device: AVCaptureDevice?) -> AVCaptureDeviceInput? {
        guard let validDevice = device else { return nil }
        do {
            return try AVCaptureDeviceInput(device: validDevice)
        } catch {
            logger.error("Error getting capture device input: \(error.localizedDescription)")
            return nil
        }
    }

    private func updateSessionForCaptureDevice(_ captureDevice: AVCaptureDevice) {
        guard isCaptureSessionConfigured else { return }

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        for input in captureSession.inputs {
            if let deviceInput = input as? AVCaptureDeviceInput {
                captureSession.removeInput(deviceInput)
            }
        }

        if let deviceInput = deviceInputFor(device: captureDevice) {
            if !captureSession.inputs.contains(deviceInput), captureSession.canAddInput(deviceInput) {
                captureSession.addInput(deviceInput)
            }
        }

        updateVideoOutputConnection()
    }

    private func updateVideoOutputConnection() {
        if let videoOutput = videoOutput, let videoOutputConnection = videoOutput.connection(with: .video) {
            if videoOutputConnection.isVideoMirroringSupported {
                videoOutputConnection.isVideoMirrored = isUsingFrontCaptureDevice
            }
        }
    }

    func start() async {
        let authorized = await checkAuthorization()
        guard authorized else {
            logger.error("Camera access was not authorized.")
            return
        }

        if isCaptureSessionConfigured {
            if !captureSession.isRunning {
                sessionQueue.async { [self] in
                    self.captureSession.startRunning()
                }
            }
            return
        }

        sessionQueue.async { [self] in
            self.configureCaptureSession { success in
                guard success else { return }
                self.captureSession.startRunning()
            }
        }
    }

    func stop() {
        guard isCaptureSessionConfigured else { return }

        if captureSession.isRunning {
            sessionQueue.async {
                self.captureSession.stopRunning()
            }
        }
    }

    func switchCaptureDevice() {
        if let captureDevice = captureDevice, let index = availableCaptureDevices.firstIndex(of: captureDevice) {
            let nextIndex = (index + 1) % availableCaptureDevices.count
            self.captureDevice = availableCaptureDevices[nextIndex]
        } else {
            captureDevice = AVCaptureDevice.default(for: .video)
        }
    }

    private var deviceOrientation: UIDeviceOrientation {
        var orientation = UIDevice.current.orientation
        if orientation == UIDeviceOrientation.unknown {
            orientation = UIScreen.main.orientation
        }
        return orientation
    }

    @objc
    func updateForDeviceOrientation() {
        // TODO: Figure out if we need this for anything.
    }

    private func videoOrientationFor(_ deviceOrientation: UIDeviceOrientation) -> AVCaptureVideoOrientation? {
        switch deviceOrientation {
        case .portrait: return AVCaptureVideoOrientation.portrait
        case .portraitUpsideDown: return AVCaptureVideoOrientation.portraitUpsideDown
        case .landscapeLeft: return AVCaptureVideoOrientation.landscapeRight
        case .landscapeRight: return AVCaptureVideoOrientation.landscapeLeft
        default: return nil
        }
    }

    func takePhoto() {
        guard let photoOutput = photoOutput else { return }

        sessionQueue.async {
            var photoSettings = AVCapturePhotoSettings()

            if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            }

            let isFlashAvailable = self.deviceInput?.device.isFlashAvailable ?? false
            photoSettings.flashMode = isFlashAvailable ? .auto : .off
            photoSettings.isHighResolutionPhotoEnabled = true
            if let previewPhotoPixelFormatType = photoSettings.availablePreviewPhotoPixelFormatTypes.first {
                photoSettings.previewPhotoFormat = [kCVPixelBufferPixelFormatTypeKey as String: previewPhotoPixelFormatType]
            }
            photoSettings.photoQualityPrioritization = .balanced

            if let photoOutputVideoConnection = photoOutput.connection(with: .video) {
                if photoOutputVideoConnection.isVideoOrientationSupported,
                   let videoOrientation = self.videoOrientationFor(self.deviceOrientation)
                {
                    photoOutputVideoConnection.videoOrientation = videoOrientation
                }
            }

            photoOutput.capturePhoto(with: photoSettings, delegate: self)
        }
    }
}

extension Camera: AVCapturePhotoCaptureDelegate {
    func photoOutput(_: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            logger.error("Error capturing photo: \(error.localizedDescription)")
            return
        }

        addToPhotoStream?(photo)
    }
}

extension Camera: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let beginTime = Date()
        if connection.isVideoOrientationSupported,
           let videoOrientation = videoOrientationFor(deviceOrientation)
        {
            connection.videoOrientation = videoOrientation
        }

        if #available(iOS 17.0, *) {
            let req = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer)
            do {
                try handler.perform([req])
            } catch {
                print("fail to perform", error)
            }
            guard let result = req.results?.first else { return }
            let instances = instances(atPoint: nil, inObservation: result)
            do {
                let input = CIImage(cvPixelBuffer: pixelBuffer)
                let mask = try result.generateScaledMaskForImage(forInstances: instances, from: handler)
                virtualBackgroundFilter.inputImage = input
                virtualBackgroundFilter.maskImage = CIImage(cvPixelBuffer: mask)
                virtualBackgroundFilter.backgroundImage = virtualBackgroundImage.cropped(to: input.extent)
                let composedResult = virtualBackgroundFilter.outputImage!
                addToPreviewStream?(composedResult)
                let interval = Date().timeIntervalSince(beginTime)
                print("process one frame cost", interval, "fps", 1/interval, "resolution", input.extent.size)
                return
            } catch {
                print("fail to mask", error)
            }
        }

        addToPreviewStream?(CIImage(cvPixelBuffer: pixelBuffer))
    }

    func mix(input: CIImage, mask: CIImage) -> CIImage {
        let bg = CIImage(color: CIColor.clear).cropped(to: input.extent)
        let filter = CIFilter.blendWithMask()
        filter.inputImage = input
        filter.backgroundImage = bg
        filter.maskImage = mask
        return filter.outputImage!
    }

    @available(iOS, introduced: 17.0)
    private func instances(
        atPoint maybePoint: CGPoint?,
        inObservation observation: VNInstanceMaskObservation
    ) -> IndexSet {
        guard let point = maybePoint else {
            return observation.allInstances
        }

        // Transform the normalized UI point to an instance map pixel coordinate.
        let instanceMap = observation.instanceMask
        let coords = VNImagePointForNormalizedPoint(
            point,
            CVPixelBufferGetWidth(instanceMap) - 1,
            CVPixelBufferGetHeight(instanceMap) - 1
        )

        // Look up the instance label at the computed pixel coordinate.
        CVPixelBufferLockBaseAddress(instanceMap, .readOnly)
        guard let pixels = CVPixelBufferGetBaseAddress(instanceMap) else {
            fatalError("Failed to access instance map data.")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(instanceMap)
        let instanceLabel = pixels.load(
            fromByteOffset: Int(coords.y) * bytesPerRow + Int(coords.x),
            as: UInt8.self
        )
        CVPixelBufferUnlockBaseAddress(instanceMap, .readOnly)

        // If the point lies on the background, select all instances.
        // Otherwise, restrict this to just the selected instance.
        return instanceLabel == 0 ? observation.allInstances : [Int(instanceLabel)]
    }
}

private extension UIScreen {
    var orientation: UIDeviceOrientation {
        let point = coordinateSpace.convert(CGPoint.zero, to: fixedCoordinateSpace)
        if point == CGPoint.zero {
            return .portrait
        } else if point.x != 0 && point.y != 0 {
            return .portraitUpsideDown
        } else if point.x == 0 && point.y != 0 {
            return .landscapeRight // .landscapeLeft
        } else if point.x != 0 && point.y == 0 {
            return .landscapeLeft // .landscapeRight
        } else {
            return .unknown
        }
    }
}

private let logger = Logger(subsystem: "com.apple.swiftplaygroundscontent.capturingphotos", category: "Camera")
