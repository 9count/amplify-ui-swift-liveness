//
// Copyright Amazon.com Inc. or its affiliates.
// All Rights Reserved.
//
// SPDX-License-Identifier: Apache-2.0
//

import AVFoundation
import CoreImage
import UIKit

class OutputSampleBufferCapturer: NSObject {
    let faceDetector: FaceDetector
    let videoChunker: VideoChunker
    // Violates SOLID
    var depthDataOutput: AVCaptureOutput?
    var videoDataOutput: AVCaptureOutput?
    
    typealias DepthLivenessCompletionHandler = (Result<DepthLivenessDataModel?, Error>) -> Void
    var depthLivenessCompletionHandler: DepthLivenessCompletionHandler?
    
    private let videoDepthConverter = DepthToJETConverter()
    private let livenessPredictor = LivenessPredictor()
    
    init(
        faceDetector: FaceDetector,
        videoChunker: VideoChunker,
        depthLivenessCompletionHandler: DepthLivenessCompletionHandler? = nil
    ) {
        self.faceDetector = faceDetector
        self.videoChunker = videoChunker
        self.depthLivenessCompletionHandler = depthLivenessCompletionHandler
    }
    
    private func consumeAndDetectFace(from sampleBuffer: CMSampleBuffer) {
        videoChunker.consume(sampleBuffer)

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        faceDetector.detectFaces(from: imageBuffer)
    }
}

extension OutputSampleBufferCapturer: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        consumeAndDetectFace(from: sampleBuffer)
    }
}

extension OutputSampleBufferCapturer: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer, didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        guard
            let depthDataOutput, let videoDataOutput,
            let syncedDepthData: AVCaptureSynchronizedDepthData =
                synchronizedDataCollection.synchronizedData(for: depthDataOutput) as? AVCaptureSynchronizedDepthData,
            let syncedVideoData: AVCaptureSynchronizedSampleBufferData =
                synchronizedDataCollection.synchronizedData(for: videoDataOutput) as? AVCaptureSynchronizedSampleBufferData else {
            // only work on synced pairs
            return
        }
        
        if syncedDepthData.depthDataWasDropped || syncedVideoData.sampleBufferWasDropped {
            return
        }
        
        let sampleBuffer = syncedVideoData.sampleBuffer
        consumeAndDetectFace(from: sampleBuffer)
        
        
        // Get pixelbuffer data from all outputs
        let depthData = syncedDepthData.depthData
        let depthPixelBuffer = depthData.depthDataMap

        let _ = convertToJet(from: depthPixelBuffer)
    }
}

extension OutputSampleBufferCapturer: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let depthData = photo.depthData
        guard 
            let depthPixelBuffer = depthData?.depthDataMap,
            let jetPixelBuffer = convertToJet(from: depthPixelBuffer)
        else {
            return
        }
        
        guard let uiImage = UIImage(pixelBuffer: jetPixelBuffer) else { return }
        do {
            try self.livenessPredictor.makePrediction(for: uiImage, completionHandler: { result in
                let dataModel = DepthLivenessDataModel(liveness: result, depthUIImage: uiImage)
                self.depthLivenessCompletionHandler?(.success(dataModel))
            })
        } catch {
            self.depthLivenessCompletionHandler?(.failure(FaceLivenessDetectionError.visionPredictionError))
        }
    }
    
    private func convertToJet(from depthPixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        if !videoDepthConverter.isPrepared {
            var depthFormatDescription: CMFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                         imageBuffer: depthPixelBuffer,
                                                         formatDescriptionOut: &depthFormatDescription)
            videoDepthConverter.prepare(with: depthFormatDescription!, outputRetainedBufferCountHint: 2)
        }
        
        return videoDepthConverter.render(pixelBuffer: depthPixelBuffer)
    }
}
