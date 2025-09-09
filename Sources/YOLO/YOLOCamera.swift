// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

//  This file is part of the Ultralytics YOLO Package, providing real-time camera-based object detection.
//  Licensed under AGPL-3.0. For commercial use, refer to Ultralytics licensing: https://ultralytics.com/license
//  Access the source code: https://github.com/ultralytics/yolo-ios-app
//
//  The YOLOCamera component provides a SwiftUI view for real-time object detection using device cameras.
//  It wraps the underlying YOLOView component to provide a clean SwiftUI interface for camera feed processing,
//  model inference, and result display. The component automatically handles camera setup, frame capture,
//  model loading, and inference processing, making it simple to add real-time object detection capabilities
//  to SwiftUI applications with minimal code. Results are exposed through a callback for custom handling
//  of detection results.

import AVFoundation
import SwiftUI

/// A SwiftUI view that provides real-time camera-based object detection using YOLO models.
public struct YOLOCamera: View {
  public let modelPathOrName: String
  public let task: YOLOTask
  public let cameraPosition: AVCaptureDevice.Position
  let onDetection: ((YOLOResult) -> Void)?

  public init(
    modelPathOrName: String,
    task: YOLOTask = .detect,
    cameraPosition: AVCaptureDevice.Position = .back,
    onDetection: ((YOLOResult) -> Void)? = nil
  ) {
    self.modelPathOrName = modelPathOrName
    self.task = task
    self.cameraPosition = cameraPosition
    self.onDetection = onDetection
  }

  public var body: some View {
    YOLOViewRepresentable(
      modelPathOrName: modelPathOrName,
      task: task,
      cameraPosition: cameraPosition
    ) { result in
      onDetection?(result)
    }
  }
}

struct YOLOViewRepresentable: UIViewRepresentable {
  let modelPathOrName: String
  let task: YOLOTask
  let cameraPosition: AVCaptureDevice.Position
  let onDetection: ((YOLOResult) -> Void)?

  func makeUIView(context: Context) -> YOLOView {
    let yoloView = YOLOView(
      frame: .zero,
      modelPathOrName: modelPathOrName,
      task: task,
      cameraPosition: cameraPosition

    )
    return yoloView
  }

  func updateUIView(_ uiView: YOLOView, context: Context) {
    uiView.onDetection = onDetection
  }
}

struct YOLOViewRepresentableWithBinding: UIViewRepresentable {
    let modelPathOrName: String
    let task: YOLOTask
    let cameraPosition: AVCaptureDevice.Position
    @Binding var shouldCapture: Bool
    @Binding var shouldCameraPause: Bool
    let onDetection: ((YOLOResult) -> Void)?
    let onPhotoCaptured: ((UIImage?) -> Void)?
    
    func makeUIView(context: Context) -> YOLOView {
        let yoloView = YOLOView(
            frame: .zero,
            modelPathOrName: modelPathOrName,
            task: task,
            cameraPosition: cameraPosition
        )
        yoloView.hideControls(hiden: true)
        return yoloView
    }
    
    func updateUIView(_ uiView: YOLOView, context: Context) {
        uiView.onDetection = onDetection
        uiView.hideControls(hiden: true)
        if shouldCapture {
            DispatchQueue.main.async {
                shouldCapture = false
            }
        
            
            uiView.capturePhoto { photo in
                DispatchQueue.main.async {
                    onPhotoCaptured?(photo)
                }
            }
        }
        
        if shouldCameraPause {
            DispatchQueue.main.async {
                uiView.stop()
            }
           
        }else{
            DispatchQueue.main.async {
                if !uiView.isRunning(){
                    uiView.resume()
                }
                
            }
        }
    }
}

// Alternative approach using @Binding for more control
public struct YOLOCameraWithBinding: View {
    public let modelPathOrName: String
    public let task: YOLOTask
    public let cameraPosition: AVCaptureDevice.Position
    let onDetection: ((YOLOResult) -> Void)?
    let onPhotoCaptured: ((UIImage?) -> Void)?
    
    @Binding var shouldCapture: Bool
    @Binding var shouldCameraPause: Bool
    @State var hideControls: Bool = false
    
    public init(
        modelPathOrName: String,
        task: YOLOTask = .detect,
        cameraPosition: AVCaptureDevice.Position = .back,
        shouldCapture: Binding<Bool>,
        shouldCameraPause: Binding<Bool>,
        onDetection: ((YOLOResult) -> Void)? = nil,
        onPhotoCaptured: ((UIImage?) -> Void)? = nil
    ) {
        self.modelPathOrName = modelPathOrName
        self.task = task
        self.cameraPosition = cameraPosition
        self._shouldCapture = shouldCapture
        self.onDetection = onDetection
        self.onPhotoCaptured = onPhotoCaptured
        self._shouldCameraPause = shouldCameraPause
    }
    
    public var body: some View {
        YOLOViewRepresentableWithBinding(
            modelPathOrName: modelPathOrName,
            task: task,
            cameraPosition: cameraPosition,
            shouldCapture: $shouldCapture,
            shouldCameraPause: $shouldCameraPause,
            onDetection: onDetection,
            onPhotoCaptured: onPhotoCaptured
        )
    }
}
