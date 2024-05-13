//
// Copyright Amazon.com Inc. or its affiliates.
// All Rights Reserved.
//
// SPDX-License-Identifier: Apache-2.0
//

import AVFoundation

class DepthLivenessCaptureSession: LivenessCaptureSessionProtocol {
    let captureDevice: LivenessCaptureDevice
    private let captureQueue = DispatchQueue(label: "com.amazonaws.faceliveness.cameracapturequeue")
    private let configurationQueue = DispatchQueue(label: "com.amazonaws.faceliveness.sessionconfiguration", qos: .userInteractive)
    let outputDelegate: AVCaptureDataOutputSynchronizerDelegate
    var outputSynchronizer: AVCaptureDataOutputSynchronizer?
    var captureSession: AVCaptureSession?
    var photoOutput: AVCapturePhotoOutput?
    
    var outputSampleBufferCapturer: OutputSampleBufferCapturer? {
        return outputDelegate as? OutputSampleBufferCapturer
    }
    
    var outputPhotoCapturer: AVCapturePhotoCaptureDelegate? {
        return outputDelegate as? AVCapturePhotoCaptureDelegate
    }

    init(captureDevice: LivenessCaptureDevice, outputDelegate: AVCaptureDataOutputSynchronizerDelegate) {
        self.captureDevice = captureDevice
        self.outputDelegate = outputDelegate
    }

    func startSession(frame: CGRect) throws -> CALayer {
        try startSession()

        guard let captureSession = captureSession else {
            throw LivenessCaptureSessionError.captureSessionUnavailable
        }
        
        let previewLayer = previewLayer(
            frame: frame,
            for: captureSession
        )

        return previewLayer
    }
    
    func startSession() throws {
        guard let camera = captureDevice.avCaptureDevice
        else { throw LivenessCaptureSessionError.cameraUnavailable }


        let cameraInput = try AVCaptureDeviceInput(device: camera)
        teardownExistingSession(input: cameraInput)
        captureSession = AVCaptureSession()

        guard let captureSession = captureSession else {
            throw LivenessCaptureSessionError.captureSessionUnavailable
        }

        captureSession.beginConfiguration()
        
        guard let videoDataOutput = outputSampleBufferCapturer?.videoDataOutput as? AVCaptureVideoDataOutput,
              let depthDataOutput = outputSampleBufferCapturer?.depthDataOutput as? AVCaptureDepthDataOutput else {
            captureSession.commitConfiguration()
            return
        }
        do {
            try setupInput(cameraInput, for: captureSession)
            captureSession.sessionPreset = captureDevice.preset
            try setupOutput(videoDataOutput, for: captureSession)
            try setupDepthDataOutput(depthDataOutput, for: captureSession)
            try setupPhotoCaptureOutput(AVCapturePhotoOutput(), for: captureSession)
            try setupHighestResolution(for: camera)
        } catch {
            captureSession.commitConfiguration()
            throw LivenessCaptureSessionError.captureSessionUnavailable
            captureSession.commitConfiguration()
        }

        outputSynchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoDataOutput, depthDataOutput])
        outputSynchronizer?.setDelegate(outputDelegate as! AVCaptureDataOutputSynchronizerDelegate, queue: configurationQueue)

        captureSession.commitConfiguration()

        try captureDevice.configure()
        
        configurationQueue.async {
            captureSession.startRunning()
        }
    }

    func stopRunning() {
        guard let session = captureSession else { return }
        defer {
            captureSession = nil
        }

        if session.isRunning {
            session.stopRunning()
        }

        for input in session.inputs {
            session.removeInput(input)
        }
        
        for output in session.outputs {
            session.removeOutput(output)
        }
    }

    private func teardownExistingSession(input: AVCaptureDeviceInput) {
        stopRunning()
        captureSession?.removeInput(input)
    }

    private func setupInput(
        _ input: AVCaptureDeviceInput,
        for captureSession: AVCaptureSession
    ) throws {
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        } else {
            throw LivenessCaptureSessionError.captureSessionInputUnavailable
        }
    }

    private func setupOutput(
        _ output: AVCaptureVideoDataOutput,
        for captureSession: AVCaptureSession
    ) throws {
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
        } else {
            throw LivenessCaptureSessionError.captureSessionOutputUnavailable
        }
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        
        if let connection = output.connection(with: .video) {
            connection.isEnabled = true
            connection.isVideoMirrored = true
            connection.videoOrientation = .portrait
        }
    }
    
    private func setupDepthDataOutput(
        _ output: AVCaptureDepthDataOutput,
        for captureSession: AVCaptureSession
    ) throws {
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
            output.isFilteringEnabled = false
            if let connection = output.connection(with: .depthData) {
                connection.isEnabled = true
            } else {
                throw LivenessCaptureSessionError.cameraUnavailable
            }
        } else {
            throw LivenessCaptureSessionError.captureSessionOutputUnavailable
        }
    }
    
    private func setupPhotoCaptureOutput(
        _ output: AVCapturePhotoOutput,
        for captureSession: AVCaptureSession
    ) throws {
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
            self.photoOutput = output
            output.isDepthDataDeliveryEnabled = output.isDepthDataDeliverySupported
        }
        
        if let connection = output.connection(with: AVMediaType.video) {
            connection.videoOrientation = .portrait
            connection.isVideoMirrored = true
        }
    }

    private func previewLayer(
        frame: CGRect,
        for captureSession: AVCaptureSession
    ) -> AVCaptureVideoPreviewLayer {
        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.connection?.videoOrientation = .portrait
        previewLayer.frame = frame
        return previewLayer
    }
    
    func capturePhoto() {
        guard 
            let photoOutput = self.photoOutput,
            let delegate = outputPhotoCapturer
        else { return }
        let photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        photoSettings.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliverySupported
        photoOutput.capturePhoto(with: photoSettings, delegate: delegate)
    }
    
    private func setupHighestResolution(for device: AVCaptureDevice) throws {
        let depthFormats = device.activeFormat.supportedDepthDataFormats
        let filtered = depthFormats.filter({
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat16
        })
        let selectedFormat = filtered.max(by: {
            first, second in CMVideoFormatDescriptionGetDimensions(first.formatDescription).width < CMVideoFormatDescriptionGetDimensions(second.formatDescription).width
        })
        
        do {
            try device.lockForConfiguration()
            device.activeDepthDataFormat = selectedFormat
            device.unlockForConfiguration()
        } catch {
            throw LivenessCaptureSessionError.cameraUnavailable
        }
    }
    
    /**
     Finds the highest resolution AVCaptureDevice.Format with a 420YpCbCr8BiPlanarFullRange pixel format for the given AVCaptureDevice.

     - Parameters:
        - device: The AVCaptureDevice for which to find the highest resolution format.

     - Returns: A CGSize representing the highest resolution found with the specified pixel format, or nil if no format with the specified pixel format is available.

     - Note: This function iterates through the formats supported by the AVCaptureDevice and selects the one with the highest resolution that matches the specified pixel format (420YpCbCr8BiPlanarFullRange). If such a format is found, its dimensions are converted into a CGSize and returned. If no suitable format is found, nil is returned.
     */
    /// - Tag: ConfigureDeviceResolution
    fileprivate func highestResolution420Format(for device: AVCaptureDevice) -> CGSize? {
        var highestResolutionFormat: AVCaptureDevice.Format? = nil
        var highestResolutionDimensions = CMVideoDimensions(width: 0, height: 0)
        
        for format in device.formats {
            let deviceFormat = format as AVCaptureDevice.Format
            
            let deviceFormatDescription = deviceFormat.formatDescription
            if CMFormatDescriptionGetMediaSubType(deviceFormatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
                let candidateDimensions = CMVideoFormatDescriptionGetDimensions(deviceFormatDescription)
                if (highestResolutionFormat == nil) || (candidateDimensions.width > highestResolutionDimensions.width) {
                    highestResolutionFormat = deviceFormat
                    highestResolutionDimensions = candidateDimensions
                }
            }
        }
        
        if highestResolutionFormat != nil {
            let resolution = CGSize(width: CGFloat(highestResolutionDimensions.width), height: CGFloat(highestResolutionDimensions.height))
            return resolution
        }
        
        return nil
    }
}
