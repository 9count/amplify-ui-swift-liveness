//
// Copyright Amazon.com Inc. or its affiliates.
// All Rights Reserved.
//
// SPDX-License-Identifier: Apache-2.0
//

import UIKit
import AVFoundation

class LivenessCaptureSession {
    let captureDevice: LivenessCaptureDevice
    private let captureQueue = DispatchQueue(label: "com.amazonaws.faceliveness.cameracapturequeue")
    private let configurationQueue = DispatchQueue(label: "com.amazonaws.faceliveness.sessionconfiguration", qos: .userInteractive)
    let outputDelegate: AVCaptureVideoDataOutputSampleBufferDelegate
    var captureSession: AVCaptureSession?
    
    var outputSampleBufferCapturer: OutputSampleBufferCapturer? {
        return outputDelegate as? OutputSampleBufferCapturer
    }

    init(captureDevice: LivenessCaptureDevice, outputDelegate: AVCaptureVideoDataOutputSampleBufferDelegate) {
        self.captureDevice = captureDevice
        self.outputDelegate = outputDelegate
    }

    func configureCamera(frame: CGRect) throws -> CALayer {
        try configureCamera()

        guard let captureSession = captureSession else {
            throw LivenessCaptureSessionError.captureSessionUnavailable
        }
        
        let previewLayer = previewLayer(
            frame: frame,
            for: captureSession
        )

        return previewLayer
    }
    
    func configureCamera() throws {
        guard let camera = captureDevice.avCaptureDevice
        else { throw LivenessCaptureSessionError.cameraUnavailable }

        let cameraInput = try AVCaptureDeviceInput(device: camera)
        let videoOutput = AVCaptureVideoDataOutput()

        teardownExistingSession(input: cameraInput)
        captureSession = AVCaptureSession()

        guard let captureSession = captureSession else {
            throw LivenessCaptureSessionError.captureSessionUnavailable
        }

        try setupInput(cameraInput, for: captureSession)
        captureSession.sessionPreset = captureDevice.preset
        try setupOutput(videoOutput, for: captureSession)
        try captureDevice.configure()

        videoOutput.setSampleBufferDelegate(
            outputDelegate,
            queue: captureQueue
        )
    }

    func startSession() {
        guard let session = captureSession else { return }
        configurationQueue.async {
            session.startRunning()
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
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        output.connections
            .filter(\.isVideoOrientationSupported)
            .forEach {
                $0.videoOrientation = .portrait
                $0.isVideoMirrored = true
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
