//
// Copyright Amazon.com Inc. or its affiliates.
// All Rights Reserved.
//
// SPDX-License-Identifier: Apache-2.0
//

import AVFoundation

struct LivenessCaptureDevice {
    let avCaptureDevice: AVCaptureDevice?
    var preset: AVCaptureSession.Preset = .vga640x480
    var fps: Double = 30
    var exposure: AVCaptureDevice.ExposureMode = .continuousAutoExposure
    var whiteBalance: AVCaptureDevice.WhiteBalanceMode = .continuousAutoWhiteBalance
    var focus: AVCaptureDevice.FocusMode = .continuousAutoFocus

    func configure() throws {
        guard let avCaptureDevice else { throw LivenessCaptureSessionError.cameraUnavailable }
        try avCaptureDevice.lockForConfiguration()
        defer { avCaptureDevice.unlockForConfiguration() }

        let fps = CMTimeScale(fps)
        let frameDuration = CMTime(value: 1, timescale: fps)
        avCaptureDevice.activeVideoMinFrameDuration = frameDuration
        avCaptureDevice.activeVideoMaxFrameDuration = frameDuration
        if avCaptureDevice.isExposureModeSupported(exposure) {
            avCaptureDevice.exposureMode = exposure
        }

        if avCaptureDevice.isFocusModeSupported(focus) {
            avCaptureDevice.focusMode = focus
        }

        if avCaptureDevice.isWhiteBalanceModeSupported(whiteBalance) {
            avCaptureDevice.whiteBalanceMode = whiteBalance
        }
    }
}

struct DepthLivenessCaptureDevice {
    let avCaptureDevice: AVCaptureDevice?
    var preset: AVCaptureSession.Preset = .vga640x480
    
    func configure() throws {
        guard let avCaptureDevice else { throw LivenessCaptureSessionError.cameraUnavailable }
        try avCaptureDevice.lockForConfiguration()
        defer { avCaptureDevice.unlockForConfiguration() }
        let depthFormats = avCaptureDevice.activeFormat.supportedDepthDataFormats
        let filtered = depthFormats.filter { CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat16 }
        let selectedFormat = filtered.max(by: { first, second in
            CMVideoFormatDescriptionGetDimensions(first.formatDescription).width < CMVideoFormatDescriptionGetDimensions(second.formatDescription).width
        })
        
        avCaptureDevice.activeDepthDataFormat = selectedFormat
    }
}
