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
    
    var outputSampleBufferCapturer: OutputSampleBufferCapturer? {
        return outputDelegate as? OutputSampleBufferCapturer
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
            connection.videoOrientation = .portrait        }
    }
    
    private func setupDepthDataOutput(
        _ output: AVCaptureDepthDataOutput,
        for captureSession: AVCaptureSession
    ) throws {
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
            output.isFilteringEnabled = true
            if let connection = output.connection(with: .depthData) {
                connection.isEnabled = true
                connection.isVideoMirrored = true
                connection.videoOrientation = .portrait
            } else {
                throw LivenessCaptureSessionError.cameraUnavailable
            }
        } else {
            throw LivenessCaptureSessionError.captureSessionOutputUnavailable
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
}
