//
// Copyright Amazon.com Inc. or its affiliates.
// All Rights Reserved.
//
// SPDX-License-Identifier: Apache-2.0
//

import AVFoundation
import CoreImage
import UIKit

class OutputSampleBufferCapturer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let faceDetector: FaceDetector
    let videoChunker: VideoChunker

    init(faceDetector: FaceDetector, videoChunker: VideoChunker) {
        self.faceDetector = faceDetector
        self.videoChunker = videoChunker
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        videoChunker.consume(sampleBuffer)

        guard let imageBuffer = sampleBuffer.imageBuffer
        else { return }

        faceDetector.detectFaces(from: imageBuffer)
    }
}

class DepthOutputSampleBufferCapturer: NSObject, AVCaptureDataOutputSynchronizerDelegate {
    let faceDetector: FaceDetector
    let videoChunker: VideoChunker
    var depthOutput: AVCaptureDepthDataOutput?
    var videoOutput: AVCaptureVideoDataOutput?
    
    // MARK: Video processing helpers
    private let videoDepthConverter = DepthToJETConverter()
    private let videoDepthMixer = VideoMixer()
    private let livenessPredictor = LivenessPredictor()
    var capturedJETPixelBuffer: CVPixelBuffer?
    init(faceDetector: FaceDetector, videoChunker: VideoChunker) {
        self.faceDetector = faceDetector
        self.videoChunker = videoChunker
    }
    
    func capture(completion: ((DepthLivenessDataModel) -> ())?) {
        guard let pixelBuffer = capturedJETPixelBuffer else { return }
        
        guard let uiImage = UIImage(pixelBuffer: pixelBuffer) else { return }
        do {
            try self.livenessPredictor.makePrediction(for: uiImage) { liveness in
                let dataModel = DepthLivenessDataModel(liveness: liveness, depthUIImage: uiImage)
                completion?(dataModel)
            }
        } catch {
            debugPrint("predictor failure")
        }
    }
    
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
        guard let imageBuffer = sampleBuffer.imageBuffer else { return }
        faceDetector.detectFaces(from: imageBuffer)
        
        guard
            let videoPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        else {
            return
        }
        
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
}
