//
// Copyright Amazon.com Inc. or its affiliates.
// All Rights Reserved.
//
// SPDX-License-Identifier: Apache-2.0
//

import Foundation
import AVFoundation
import UIKit

class DepthCaptureSession: LivenessCaptureSessionProtocol {
    func capture(completion: ((DepthLivenessDataModel) -> ())?) {
        outputSampleBufferCapturer?.capture(completion: { dataModel in
            completion?(dataModel)
        })
    }
    
    let captureDevice: DepthLivenessCaptureDevice
    private let captureQueue = DispatchQueue(label: "com.amazonaws.faceliveness.cameracapturequeue")
    private let configurationQueue = DispatchQueue(label: "com.amazonaws.faceliveness.sessionconfiguration", qos: .userInitiated)
    var captureSession: AVCaptureSession?
    private var outputSynchronizer: AVCaptureDataOutputSynchronizer?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var depthOutput: AVCaptureDepthDataOutput?
    let outputDelegate: AVCaptureDataOutputSynchronizerDelegate
    
    var outputSampleBufferCapturer: DepthOutputSampleBufferCapturer? {
        return outputDelegate as? DepthOutputSampleBufferCapturer
    }


    init(captureDevice: DepthLivenessCaptureDevice, outputDelegate: AVCaptureDataOutputSynchronizerDelegate) {
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
            captureSession?.beginConfiguration()

            let cameraInput = try AVCaptureDeviceInput(device: camera)
            let videoOutput = AVCaptureVideoDataOutput()
            let depthOutput = AVCaptureDepthDataOutput()
        outputSampleBufferCapturer?.depthOutput = depthOutput
        outputSampleBufferCapturer?.videoOutput = videoOutput
            teardownExistingSession(input: cameraInput)
            captureSession = AVCaptureSession()
            
            guard let captureSession = captureSession else {
                throw LivenessCaptureSessionError.captureSessionUnavailable
            }
            
            try setupInput(cameraInput, for: captureSession)
            captureSession.sessionPreset = captureDevice.preset
            try setupOutput(videoOutput, for: captureSession)
            try setupDepthOutput(depthOutput, for: captureSession)
            try captureDevice.configure()
            
            outputSynchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
            outputSynchronizer!.setDelegate(outputSampleBufferCapturer, queue: captureQueue)
        captureSession.commitConfiguration()

        configurationQueue.async {
            self.captureSession?.startRunning()
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
    
    private func setupDepthOutput(
        _ output: AVCaptureDepthDataOutput,
        for captureSession: AVCaptureSession) throws {
            if captureSession.canAddOutput(output) {
                captureSession.addOutput(output)
            } else {
                if let connection = output.connection(with: .depthData) {
                    connection.isEnabled = true
                } else {
                    throw LivenessCaptureSessionError.cameraUnavailable
                }
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

public struct DepthLivenessDataModel {
    public var liveness: LivenessPredictor.Liveness
    public var depthUIImage: UIImage
}
