// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

//  This file is part of the Ultralytics YOLO Package, managing camera capture for real-time inference.
//  Licensed under AGPL-3.0. For commercial use, refer to Ultralytics licensing: https://ultralytics.com/license
//  Access the source code: https://github.com/ultralytics/yolo-ios-app
//
//  The VideoCapture component manages the camera and video processing pipeline for real-time
//  object detection. It handles setting up the AVCaptureSession, managing camera devices,
//  configuring camera properties like focus and exposure, and processing video frames for
//  model inference. The class delivers capture frames to the predictor component for real-time
//  analysis and returns results through delegate callbacks. It also supports camera controls
//  such as switching between front and back cameras, zooming, and capturing still photos.

import AVFoundation
import CoreVideo
import UIKit
import Vision

/// Protocol for receiving video capture frame processing results.
@MainActor
protocol VideoCaptureDelegate: AnyObject {
  func onPredict(result: YOLOResult)
  func onInferenceTime(speed: Double, fps: Double)
}

func bestCaptureDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice {
  // print("USE TELEPHOTO: ")
  // print(UserDefaults.standard.bool(forKey: "use_telephoto"))

  if UserDefaults.standard.bool(forKey: "use_telephoto"),
    let device = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: position)
  {
    return device
  } else if let device = AVCaptureDevice.default(
    .builtInDualCamera, for: .video, position: position)
  {
    return device
  } else if let device = AVCaptureDevice.default(
    .builtInWideAngleCamera, for: .video, position: position)
  {
    return device
  } else {
    fatalError("Missing expected back camera device.")
  }
}

class VideoCapture: NSObject, @unchecked Sendable {
  var predictor: Predictor!
  var previewLayer: AVCaptureVideoPreviewLayer?
  weak var delegate: VideoCaptureDelegate?
  var captureDevice: AVCaptureDevice?
  let captureSession = AVCaptureSession()
  var videoInput: AVCaptureDeviceInput? = nil
  let videoOutput = AVCaptureVideoDataOutput()
  var photoOutput = AVCapturePhotoOutput()
  let cameraQueue = DispatchQueue(label: "camera-queue")
  var lastCapturedPhoto: UIImage? = nil
  var inferenceOK = true
  var longSide: CGFloat = 3
  var shortSide: CGFloat = 4
  var frameSizeCaptured = false
  
  // Add session state tracking
  private var isSessionConfigured = false
  private var currentBuffer: CVPixelBuffer?

  func setUp(
    sessionPreset: AVCaptureSession.Preset = .hd1280x720,
    position: AVCaptureDevice.Position,
    orientation: UIDeviceOrientation,
    completion: @escaping (Bool) -> Void
  ) {
    cameraQueue.async {
      let success = self.setUpCamera(
        sessionPreset: sessionPreset, position: position, orientation: orientation)
      DispatchQueue.main.async {
        completion(success)
      }
    }
  }

  func setUpCamera(
    sessionPreset: AVCaptureSession.Preset, position: AVCaptureDevice.Position,
    orientation: UIDeviceOrientation
  ) -> Bool {
    captureSession.beginConfiguration()
    captureSession.sessionPreset = sessionPreset

    captureDevice = bestCaptureDevice(position: position)
    videoInput = try! AVCaptureDeviceInput(device: captureDevice!)

    if captureSession.canAddInput(videoInput!) {
      captureSession.addInput(videoInput!)
    }
    var videoOrientaion = AVCaptureVideoOrientation.portrait
    switch orientation {
    case .portrait:
      videoOrientaion = .portrait
    case .landscapeLeft:
      videoOrientaion = .landscapeRight
    case .landscapeRight:
      videoOrientaion = .landscapeLeft
    default:
      videoOrientaion = .portrait
    }
    let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
    previewLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
    previewLayer.connection?.videoOrientation = videoOrientaion
    self.previewLayer = previewLayer

    let settings: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)
    ]

    videoOutput.videoSettings = settings
    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.setSampleBufferDelegate(self, queue: cameraQueue)
    if captureSession.canAddOutput(videoOutput) {
      captureSession.addOutput(videoOutput)
    }
    if captureSession.canAddOutput(photoOutput) {
      captureSession.addOutput(photoOutput)
      photoOutput.isHighResolutionCaptureEnabled = true
      //            photoOutput.isLivePhotoCaptureEnabled = photoOutput.isLivePhotoCaptureSupported
    }

    // We want the buffers to be in portrait orientation otherwise they are
    // rotated by 90 degrees. Need to set this _after_ addOutput()!
    // let curDeviceOrientation = UIDevice.current.orientation
    let connection = videoOutput.connection(with: AVMediaType.video)
    connection?.videoOrientation = videoOrientaion
    if position == .front {
      connection?.isVideoMirrored = true
    }

    // Configure captureDevice
    do {
      try captureDevice!.lockForConfiguration()
    } catch {
      print("device configuration not working")
    }
    // captureDevice.setFocusModeLocked(lensPosition: 1.0, completionHandler: { (time) -> Void in })
    if captureDevice!.isFocusModeSupported(AVCaptureDevice.FocusMode.continuousAutoFocus),
      captureDevice!.isFocusPointOfInterestSupported
    {
      captureDevice!.focusMode = AVCaptureDevice.FocusMode.continuousAutoFocus
      captureDevice!.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
    }
    captureDevice!.exposureMode = AVCaptureDevice.ExposureMode.continuousAutoExposure
    captureDevice!.unlockForConfiguration()

    captureSession.commitConfiguration()
    isSessionConfigured = true
    return true
  }

  // FIXED: Use consistent queue and proper state management
  func start() {
    cameraQueue.async {
      guard self.isSessionConfigured else {
        debugPrint("Session not configured, cannot start")
        return
      }
      
      if !self.captureSession.isRunning {
        debugPrint("Starting capture session")
        self.captureSession.startRunning()
        
        // Ensure preview layer connection is maintained
        DispatchQueue.main.async {
          if let previewLayer = self.previewLayer,
             let connection = previewLayer.connection {
            if !connection.isEnabled {
              connection.isEnabled = true
            }
          }
        }
      } else {
        debugPrint("Capture session already running")
      }
    }
  }

  // FIXED: Use consistent queue
  func stop() {
    debugPrint("Stopping capture session - isRunning: \(captureSession.isRunning)")
    cameraQueue.async {
      if self.captureSession.isRunning {
        debugPrint("Actually stopping capture session")
        self.captureSession.stopRunning()
      }
    }
  }
  
  // NEW: Reset internal state
  func reset() {
    cameraQueue.async {
      self.currentBuffer = nil
      self.inferenceOK = true
      self.frameSizeCaptured = false
      debugPrint("VideoCapture state reset")
    }
  }
  
  // NEW: Restart method with proper sequencing
  func restart() {
    debugPrint("Restarting VideoCapture")
    stop()
    reset()
    
    // Add a small delay to ensure stop completes
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      self.start()
    }
  }
  
  // NEW: Check if session is properly configured
  func ensureSessionIsReady() -> Bool {
    guard isSessionConfigured else {
      debugPrint("Session not configured")
      return false
    }
    
    guard captureSession.inputs.count > 0 && captureSession.outputs.count > 0 else {
      debugPrint("Session missing inputs or outputs")
      return false
    }
    
    return true
  }
  
  // NEW: Force cleanup method
  func cleanup() {
    cameraQueue.async {
      if self.captureSession.isRunning {
        self.captureSession.stopRunning()
      }
      
      // Remove all inputs and outputs
      for input in self.captureSession.inputs {
        self.captureSession.removeInput(input)
      }
      
      for output in self.captureSession.outputs {
        self.captureSession.removeOutput(output)
      }
      
      self.videoInput = nil
      self.captureDevice = nil
      self.currentBuffer = nil
      self.isSessionConfigured = false
      
      DispatchQueue.main.async {
        self.previewLayer?.removeFromSuperlayer()
        self.previewLayer = nil
      }
      
      debugPrint("VideoCapture cleaned up")
    }
  }

  func setZoomRatio(ratio: CGFloat) {
    cameraQueue.async {
      guard let captureDevice = self.captureDevice else { return }
      
      do {
        try captureDevice.lockForConfiguration()
        defer {
          captureDevice.unlockForConfiguration()
        }
        captureDevice.videoZoomFactor = ratio
      } catch {
        debugPrint("Failed to set zoom ratio: \(error)")
      }
    }
  }

  private func predictOnFrame(sampleBuffer: CMSampleBuffer) {
    guard let predictor = predictor else {
      print("predictor is nil")
      return
    }
    
    // FIXED: Better buffer management
    guard currentBuffer == nil else {
      // Skip frame if still processing previous one
      return
    }
    
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      print("Failed to get pixel buffer")
      return
    }
    
    currentBuffer = pixelBuffer
    
    if !frameSizeCaptured {
      let frameWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
      let frameHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
      longSide = max(frameWidth, frameHeight)
      shortSide = min(frameWidth, frameHeight)
      frameSizeCaptured = true
      debugPrint("Frame size captured: \(frameWidth) x \(frameHeight)")
    }

    /// - Tag: MappingOrientation
    // The frame is always oriented based on the camera sensor,
    // so in most cases Vision needs to rotate it for the model to work as expected.
    var imageOrientation: CGImagePropertyOrientation = .up
    //            switch UIDevice.current.orientation {
    //            case .portrait:
    //                imageOrientation = .up
    //            case .portraitUpsideDown:
    //                imageOrientation = .down
    //            case .landscapeLeft:
    //                imageOrientation = .up
    //            case .landscapeRight:
    //                imageOrientation = .up
    //            case .unknown:
    //                imageOrientation = .up
    //
    //            default:
    //                imageOrientation = .up
    //            }

    predictor.predict(sampleBuffer: sampleBuffer, onResultsListener: self, onInferenceTime: self)
    currentBuffer = nil
  }

  func updateVideoOrientation(orientation: AVCaptureVideoOrientation) {
    cameraQueue.async {
      guard let connection = self.videoOutput.connection(with: .video) else { return }

      connection.videoOrientation = orientation
      let currentInput = self.captureSession.inputs.first as? AVCaptureDeviceInput
      if currentInput?.device.position == .front {
        connection.isVideoMirrored = true
      } else {
        connection.isVideoMirrored = false
      }
      
      DispatchQueue.main.async {
        self.previewLayer?.connection?.videoOrientation = connection.videoOrientation
      }
    }
  }
}

extension VideoCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard inferenceOK else { return }
    guard ensureSessionIsReady() else { return }
    predictOnFrame(sampleBuffer: sampleBuffer)
  }
}

extension VideoCapture: AVCapturePhotoCaptureDelegate {
  @available(iOS 11.0, *)
  func photoOutput(
    _ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?
  ) {
    guard let data = photo.fileDataRepresentation(),
      let image = UIImage(data: data)
    else {
      return
    }

    self.lastCapturedPhoto = image
  }
}

extension VideoCapture: ResultsListener, InferenceTimeListener {
  func on(inferenceTime: Double, fpsRate: Double) {
    DispatchQueue.main.async {
      self.delegate?.onInferenceTime(speed: inferenceTime, fps: fpsRate)
    }
  }

  func on(result: YOLOResult) {
    DispatchQueue.main.async {
      self.delegate?.onPredict(result: result)
    }
  }
}
