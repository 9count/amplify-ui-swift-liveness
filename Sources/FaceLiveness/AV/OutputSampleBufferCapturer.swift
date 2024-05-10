//
// Copyright Amazon.com Inc. or its affiliates.
// All Rights Reserved.
//
// SPDX-License-Identifier: Apache-2.0
//

import AVFoundation
import CoreImage

class OutputSampleBufferCapturer: NSObject {
    let faceDetector: FaceDetector
    let videoChunker: VideoChunker
    var depthDataOutput: AVCaptureOutput?
    var videoDataOutput: AVCaptureOutput?

    init(faceDetector: FaceDetector, videoChunker: VideoChunker) {
        self.faceDetector = faceDetector
        self.videoChunker = videoChunker
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
    }
}
