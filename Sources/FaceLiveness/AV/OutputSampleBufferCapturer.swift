//
// Copyright Amazon.com Inc. or its affiliates.
// All Rights Reserved.
//
// SPDX-License-Identifier: Apache-2.0
//

import AVFoundation
import CoreImage
import UIKit
import PhotosUI

class OutputSampleBufferCapturer: NSObject {
    let faceDetector: FaceDetector
    let videoChunker: VideoChunker
    // Violates SOLID
    var depthDataOutput: AVCaptureOutput?
    var videoDataOutput: AVCaptureOutput?
    private let videoDepthConverter = DepthToJETConverter()
    private let livenessPredictor = LivenessPredictor()
    
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
        
        #if DEBUG
            Task {
                await save(from: jetPixelBuffer)
            }
        #endif
        
        guard let uiImage = UIImage(pixelBuffer: jetPixelBuffer) else { return }
        do {
            try self.livenessPredictor.makePrediction(for: uiImage, completionHandler: { liveness in
                print(liveness.rawValue)
            })
        } catch {
            print("Fail predicting")
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
    
    var isPhotoLibraryReadWriteAccessGranted: Bool {
        get async {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            var isAuthorized = status == .authorized
            
            if status == .notDetermined {
                isAuthorized = await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized
            }
            
            return isAuthorized
        }
    }
    
    func save(from cvPixelBuffer: CVPixelBuffer) async {
        // Confirm the user granted read/write access.
        guard await isPhotoLibraryReadWriteAccessGranted else { return }
        guard let cgImage = CGImage.convert(from: cvPixelBuffer) else {
            return
        }
        
        // Create a data representation of the photo and its attachments.
        if let photoData = UIImage(cgImage: cgImage).pngData() {
            PHPhotoLibrary.shared().performChanges {
                // Save the photo data.
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .photo, data: photoData, options: nil)
            } completionHandler: { success, error in
                if let error {
                    print("Error saving photo: \(error.localizedDescription)")
                    return
                }
            }
        }
    }
}
