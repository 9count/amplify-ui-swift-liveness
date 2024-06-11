//
// Copyright Amazon.com Inc. or its affiliates.
// All Rights Reserved.
//
// SPDX-License-Identifier: Apache-2.0
//

import Foundation
import AVFoundation
import UIKit

class DepthCaptureSession: NSObject, LivenessCaptureSessionProtocol {
    let captureDevice: DepthLivenessCaptureDevice
    private let captureQueue = DispatchQueue(label: "com.amazonaws.faceliveness.cameracapturequeue")
    private let configurationQueue = DispatchQueue(label: "com.amazonaws.faceliveness.sessionconfiguration", qos: .userInitiated)
    let faceDetector: FaceDetector
    let videoChunker: VideoChunker
    var captureSession: AVCaptureSession?
    private var outputSynchronizer: AVCaptureDataOutputSynchronizer?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var depthOutput: AVCaptureDepthDataOutput?
    var capturedJETPixelBuffer: CVPixelBuffer?

    // MARK: Video processing helpers
    private let videoDepthConverter = DepthToJETConverter()
    private let videoDepthMixer = VideoMixer()
    private let livenessPredictor = LivenessPredictor()

    init(captureDevice: DepthLivenessCaptureDevice, faceDetector: FaceDetector, videoChunker: VideoChunker) {
        self.captureDevice = captureDevice
        self.faceDetector = faceDetector
        self.videoChunker = videoChunker
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
        let videoOutput = AVCaptureVideoDataOutput()
        let depthOutput = AVCaptureDepthDataOutput()

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

        configurationQueue.async {
            captureSession.startRunning()
        }

        outputSynchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
        outputSynchronizer?.setDelegate(self, queue: captureQueue)

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
    
    private func setupDepthOutput(
        _ output: AVCaptureDepthDataOutput,
        for captureSession: AVCaptureSession) throws {
            if captureSession.canAddOutput(output) {
                captureSession.addOutput(output)
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

extension DepthCaptureSession: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer, didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        guard
            let depthOutput, let videoOutput,
            let syncedDepthData: AVCaptureSynchronizedDepthData = synchronizedDataCollection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData,
            let syncedVideoData: AVCaptureSynchronizedSampleBufferData = synchronizedDataCollection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData else {
            return
        }
        
        if syncedDepthData.depthDataWasDropped || syncedVideoData.sampleBufferWasDropped { return }
        let depthData = syncedDepthData.depthData
        let depthPixelBuffer = depthData.depthDataMap
        let sampleBuffer = syncedVideoData.sampleBuffer
        
        videoChunker.consume(sampleBuffer)
        guard
            let videoPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        else {
            return
        }
        
        faceDetector.detectFaces(from: videoPixelBuffer)
        
        
        if !videoDepthConverter.isPrepared {
            var depthFormatDescription: CMFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: depthPixelBuffer, formatDescriptionOut: &depthFormatDescription)
            videoDepthConverter.prepare(with: depthFormatDescription!, outputRetainedBufferCountHint: 2)
        }
        
        guard let jetPixelBuffer = videoDepthConverter.render(pixelBuffer: depthPixelBuffer) else {
            debugPrint("unable to process depth")
            return
        }
        
        if !videoDepthMixer.isPrepared {
            videoDepthMixer.prepare(with: formatDescription, outputRetainedBufferCountHint: 3)
        }
        
        guard let mixedBuffer = videoDepthMixer.mix(videoPixelBuffer: videoPixelBuffer, depthPixelBuffer: jetPixelBuffer) else { return }
        self.capturedJETPixelBuffer = jetPixelBuffer
    }
    
    func capture(completion: ((LivenessPredictor.Liveness, UIImage) -> ())?) {
        guard let pixelBuffer = capturedJETPixelBuffer else { return }
        
        guard let uiImage = UIImage(pixelBuffer: pixelBuffer) else { return }
        do {
            try self.livenessPredictor.makePrediction(for: uiImage) { liveness in
                completion?(liveness, uiImage)
            }
        } catch {
            debugPrint("predictor failure")
        }
    }
}
