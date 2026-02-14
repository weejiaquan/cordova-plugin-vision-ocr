//
//  VisionOCR.swift
//
//  Supports two camera UI modes:
//    1. Native overlay — capturePhoto / openCamera / closeCamera
//       Plugin builds its own UIView overlay with buttons and controls.
//    2. Web UI (behind-webview) — showPreview / hidePreview
//       Camera preview behind a transparent WKWebView; all UI is HTML/JS.
//  Both modes share: switchCamera, setTorch, setZoom, focusAtPoint, captureFrame.
//

import Foundation
import UIKit
import Vision
import AVFoundation

@objc(VisionOCR) class VisionOCR : CDVPlugin, AVCaptureVideoDataOutputSampleBufferDelegate {

    // Camera UI mode
    private enum UIMode { case none, nativeOverlay, behindWebview }
    private var uiMode: UIMode = .none

    // Shared camera state
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var latestFrame: UIImage?
    private var currentCameraPosition: AVCaptureDevice.Position = .back
    private var isTorchOn: Bool = false
    private var lastZoomFactor: CGFloat = 1.0
    private let cameraSessionQueue = DispatchQueue(label: "com.auphansoftware.visionocr.session")
    private let ciContext = CIContext()
    private let frameLock = NSLock()

    // Native overlay state
    private var cameraOverlay: UIView?
    private var statusLabel: UILabel?
    private var switchCameraBtn: UIButton?
    private var torchBtn: UIButton?
    private var focusRingView: UIView?
    private var cameraMode: String = ""  // "manual" or "auto"

    // Native overlay callbacks
    private var openCameraCallbackId: String?
    private var openCameraErrorCallbackId: String?
    private var capturePhotoCallbackId: String?
    private var capturePhotoErrorCallbackId: String?

    // Web UI (behind-webview) state
    private var savedWebViewOpaque: Bool = true
    private var savedWebViewBgColor: UIColor?
    private var savedScrollViewBgColor: UIColor?

    // MARK: - Orientation observer

    private var orientationWorkItem: DispatchWorkItem?

    private func _startOrientationObserver() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(_onOrientationChanged),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    private func _stopOrientationObserver() {
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        orientationWorkItem?.cancel()
        orientationWorkItem = nil
    }

    @objc private func _onOrientationChanged() {
        // Cancel any pending orientation update
        orientationWorkItem?.cancel()

        // Debounce: wait for UI rotation animation to complete before syncing camera.
        // UIDevice.orientationDidChangeNotification fires from the accelerometer
        // BEFORE the interface actually rotates, causing the camera to flip early.
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let orientation = self._currentVideoOrientation()

            DispatchQueue.main.async {
                if let connection = self.previewLayer?.connection, connection.isVideoOrientationSupported {
                    connection.videoOrientation = orientation
                }
                if let previewLayer = self.previewLayer, let superLayer = previewLayer.superlayer {
                    previewLayer.frame = superLayer.bounds
                }
            }

            self._syncOutputOrientation()
        }
        orientationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    // MARK: - Image helpers

    private func normalizeOrientation(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up { return image }
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let normalized = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return normalized
    }

    private func downscaleImage(_ image: UIImage, maxSize: CGFloat) -> UIImage {
        let longestEdge = max(image.size.width, image.size.height)
        if longestEdge <= maxSize { return image }

        let scale = maxSize / longestEdge
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let scaled = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return scaled
    }

    private func imageToBase64(_ image: UIImage) -> String? {
        return image.jpegData(compressionQuality: 0.85)?.base64EncodedString()
    }

    // MARK: - Shared camera setup

    private func _currentVideoOrientation() -> AVCaptureVideoOrientation {
        switch UIDevice.current.orientation {
        case .portrait:            return .portrait
        case .portraitUpsideDown:   return .portraitUpsideDown
        case .landscapeLeft:        return .landscapeRight
        case .landscapeRight:       return .landscapeLeft
        default:
            // Device orientation is .unknown/.faceUp/.faceDown (common at launch).
            // Fall back to the window scene's interface orientation.
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                switch scene.interfaceOrientation {
                case .landscapeLeft:        return .landscapeRight
                case .landscapeRight:       return .landscapeLeft
                case .portraitUpsideDown:   return .portraitUpsideDown
                default:                    return .portrait
                }
            }
            return .portrait
        }
    }

    private func _syncOutputOrientation() {
        guard let session = self.captureSession else { return }
        let orientation = _currentVideoOrientation()
        for output in session.outputs {
            if let connection = output.connection(with: .video), connection.isVideoOrientationSupported {
                connection.videoOrientation = orientation
            }
        }
    }

    private func _currentCaptureDevice() -> AVCaptureDevice? {
        guard let input = self.captureSession?.inputs.first as? AVCaptureDeviceInput else { return nil }
        return input.device
    }

    private func _capabilities() -> [String: Any] {
        let device = _currentCaptureDevice()
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        return [
            "hasTorch": device?.hasTorch ?? false,
            "hasMultipleCameras": discoverySession.devices.count > 1,
            "position": currentCameraPosition == .back ? "back" : "front",
            "minZoom": device?.minAvailableVideoZoomFactor ?? 1.0,
            "maxZoom": min(device?.maxAvailableVideoZoomFactor ?? 1.0, 10.0)
        ]
    }

    private func _setupCamera() -> Bool {
        // Stop any existing session before creating a new one
        if let oldSession = self.captureSession {
            self.captureSession = nil
            cameraSessionQueue.sync {
                oldSession.stopRunning()
            }
        }

        let session = AVCaptureSession()
        session.sessionPreset = .hd1920x1080

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: self.currentCameraPosition),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return false
        }

        if session.canAddInput(input) {
            session.addInput(input)
        } else {
            return false
        }

        // Reset zoom to 1x — prevents the system from using a telephoto crop
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = device.minAvailableVideoZoomFactor
            device.unlockForConfiguration()
        } catch { }
        self.lastZoomFactor = device.minAvailableVideoZoomFactor

        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "cameraFrameQueue"))
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true

        if session.canAddOutput(output) {
            session.addOutput(output)
        } else {
            return false
        }

        if let connection = output.connection(with: .video) {
            connection.videoOrientation = _currentVideoOrientation()
        }

        self.captureSession = session
        return true
    }

    private func _teardownCamera() {
        _stopOrientationObserver()

        let session = self.captureSession
        let savedUiMode = self.uiMode

        // Clear references immediately so no new work starts
        self.captureSession = nil
        frameLock.lock()
        self.latestFrame = nil
        frameLock.unlock()
        self.isTorchOn = false
        self.lastZoomFactor = 1.0
        self.currentCameraPosition = .back
        self.cameraMode = ""
        self.uiMode = .none

        // Remove UI overlay immediately on main thread (don't wait for session stop)
        DispatchQueue.main.async {
            self.previewLayer?.removeFromSuperlayer()
            self.previewLayer = nil

            if savedUiMode == .nativeOverlay {
                self.cameraOverlay?.removeFromSuperview()
                self.cameraOverlay = nil
                self.statusLabel = nil
                self.switchCameraBtn = nil
                self.torchBtn = nil
                self.focusRingView?.removeFromSuperview()
                self.focusRingView = nil
            } else if savedUiMode == .behindWebview {
                if let wv = self.webView {
                    wv.isOpaque = self.savedWebViewOpaque
                    wv.backgroundColor = self.savedWebViewBgColor
                    wv.scrollView.backgroundColor = self.savedScrollViewBgColor
                }
            }
        }

        // Stop session synchronously to prevent races with beginConfiguration
        if let session = session {
            cameraSessionQueue.sync {
                // Turn off torch before stopping
                if let input = session.inputs.first as? AVCaptureDeviceInput, input.device.hasTorch {
                    do {
                        try input.device.lockForConfiguration()
                        input.device.torchMode = .off
                        input.device.unlockForConfiguration()
                    } catch { }
                }
                session.stopRunning()
            }
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        let frame = UIImage(cgImage: cgImage)
        frameLock.lock()
        self.latestFrame = frame
        frameLock.unlock()
    }

    // =====================================================================
    // MARK: - MODE 1: Native Overlay (capturePhoto / openCamera / closeCamera)
    // =====================================================================

    private func _startNativeCamera(mode: String) {
        self.cameraMode = mode
        self.uiMode = .nativeOverlay
        self.latestFrame = nil

        guard let session = self.captureSession else { return }

        DispatchQueue.main.async {
            guard let webView = self.webView, let parentView = webView.superview else { return }

            // Create overlay
            let overlay = UIView(frame: parentView.bounds)
            overlay.backgroundColor = .black
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]

            // Preview layer
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = overlay.bounds
            if let conn = preview.connection, conn.isVideoOrientationSupported {
                conn.videoOrientation = self._currentVideoOrientation()
            }
            overlay.layer.addSublayer(preview)
            self.previewLayer = preview

            // Bottom bar
            let barHeight: CGFloat = 80
            let safeBottom: CGFloat = parentView.safeAreaInsets.bottom
            let bar = UIView(frame: CGRect(x: 0, y: overlay.bounds.height - barHeight - safeBottom, width: overlay.bounds.width, height: barHeight + safeBottom))
            bar.backgroundColor = UIColor.black.withAlphaComponent(0.7)
            bar.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
            overlay.addSubview(bar)

            if mode == "manual" {
                let captureBtn = UIButton(type: .system)
                captureBtn.setTitle("Capture", for: .normal)
                captureBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 18)
                captureBtn.setTitleColor(.white, for: .normal)
                captureBtn.backgroundColor = UIColor(red: 0.29, green: 0.56, blue: 0.85, alpha: 1.0)
                captureBtn.layer.cornerRadius = 4
                captureBtn.frame = CGRect(x: bar.bounds.width / 2 - 160, y: 15, width: 150, height: 50)
                captureBtn.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin]
                captureBtn.addTarget(self, action: #selector(self.onCaptureTapped), for: .touchUpInside)
                bar.addSubview(captureBtn)

                let cancelBtn = UIButton(type: .system)
                cancelBtn.setTitle("Cancel", for: .normal)
                cancelBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 18)
                cancelBtn.setTitleColor(.white, for: .normal)
                cancelBtn.backgroundColor = UIColor.gray
                cancelBtn.layer.cornerRadius = 4
                cancelBtn.frame = CGRect(x: bar.bounds.width / 2 + 10, y: 15, width: 150, height: 50)
                cancelBtn.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin]
                cancelBtn.addTarget(self, action: #selector(self.onCancelTapped), for: .touchUpInside)
                bar.addSubview(cancelBtn)
            } else {
                let label = UILabel(frame: CGRect(x: 20, y: 10, width: bar.bounds.width - 180, height: 30))
                label.text = "Scanning..."
                label.textColor = UIColor.green
                label.font = UIFont.systemFont(ofSize: 16)
                label.autoresizingMask = [.flexibleWidth]
                bar.addSubview(label)
                self.statusLabel = label

                let cancelBtn = UIButton(type: .system)
                cancelBtn.setTitle("Cancel", for: .normal)
                cancelBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 18)
                cancelBtn.setTitleColor(.white, for: .normal)
                cancelBtn.backgroundColor = UIColor.gray
                cancelBtn.layer.cornerRadius = 4
                cancelBtn.frame = CGRect(x: bar.bounds.width - 160, y: 10, width: 140, height: 50)
                cancelBtn.autoresizingMask = [.flexibleLeftMargin]
                cancelBtn.addTarget(self, action: #selector(self.onCancelTapped), for: .touchUpInside)
                bar.addSubview(cancelBtn)
            }

            // --- Camera controls (top-right floating buttons) ---
            let safeTop: CGFloat = parentView.safeAreaInsets.top
            let btnSize: CGFloat = 44
            let controlX: CGFloat = overlay.bounds.width - btnSize - 16
            var controlY: CGFloat = safeTop + 12

            let discoverySession = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera],
                mediaType: .video,
                position: .unspecified
            )
            if discoverySession.devices.count > 1 {
                let switchBtn = UIButton(type: .system)
                if #available(iOS 13.0, *) {
                    switchBtn.setImage(UIImage(systemName: "camera.rotate"), for: .normal)
                    switchBtn.tintColor = .white
                } else {
                    switchBtn.setTitle("\u{21BB}", for: .normal)
                    switchBtn.titleLabel?.font = UIFont.systemFont(ofSize: 24)
                    switchBtn.setTitleColor(.white, for: .normal)
                }
                switchBtn.backgroundColor = UIColor(white: 0.2, alpha: 0.7)
                switchBtn.layer.cornerRadius = btnSize / 2
                switchBtn.frame = CGRect(x: controlX, y: controlY, width: btnSize, height: btnSize)
                switchBtn.autoresizingMask = [.flexibleLeftMargin, .flexibleBottomMargin]
                switchBtn.addTarget(self, action: #selector(self.onNativeSwitchCameraTapped), for: .touchUpInside)
                overlay.addSubview(switchBtn)
                self.switchCameraBtn = switchBtn
                controlY += btnSize + 12
            }

            if let device = self._currentCaptureDevice(), device.hasTorch {
                let torchBtnView = UIButton(type: .system)
                if #available(iOS 13.0, *) {
                    torchBtnView.setImage(UIImage(systemName: "bolt.slash.fill"), for: .normal)
                    torchBtnView.tintColor = .white
                } else {
                    torchBtnView.setTitle("\u{26A1}", for: .normal)
                    torchBtnView.titleLabel?.font = UIFont.systemFont(ofSize: 20)
                    torchBtnView.setTitleColor(.white, for: .normal)
                }
                torchBtnView.backgroundColor = UIColor(white: 0.2, alpha: 0.7)
                torchBtnView.layer.cornerRadius = btnSize / 2
                torchBtnView.frame = CGRect(x: controlX, y: controlY, width: btnSize, height: btnSize)
                torchBtnView.autoresizingMask = [.flexibleLeftMargin, .flexibleBottomMargin]
                torchBtnView.addTarget(self, action: #selector(self.onNativeTorchTapped), for: .touchUpInside)
                overlay.addSubview(torchBtnView)
                self.torchBtn = torchBtnView
            }

            // Tap-to-focus gesture
            let tapGesture = UITapGestureRecognizer(target: self, action: #selector(self.onNativeOverlayTapped(_:)))
            overlay.addGestureRecognizer(tapGesture)

            // Pinch-to-zoom gesture
            let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(self.onNativePinchGesture(_:)))
            overlay.addGestureRecognizer(pinchGesture)

            parentView.addSubview(overlay)
            self.cameraOverlay = overlay

            self._startOrientationObserver()

            self.cameraSessionQueue.async {
                session.startRunning()
            }
        }
    }

    // MARK: Native overlay button handlers

    @objc private func onCaptureTapped() {
        _syncOutputOrientation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let callbackId = self.capturePhotoCallbackId else { return }

            self.frameLock.lock()
            let frame = self.latestFrame
            self.frameLock.unlock()

            guard let image = frame else {
                self._teardownCamera()
                let result = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "No frame captured")
                self.commandDelegate!.send(result, callbackId: callbackId)
                self.capturePhotoCallbackId = nil
                self.capturePhotoErrorCallbackId = nil
                return
            }
            self._teardownCamera()
            self.commandDelegate!.run(inBackground: {
                if let base64 = self.imageToBase64(image) {
                    let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: base64)
                    self.commandDelegate!.send(result, callbackId: callbackId)
                } else {
                    let result = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "Failed to encode image")
                    self.commandDelegate!.send(result, callbackId: callbackId)
                }
                self.capturePhotoCallbackId = nil
                self.capturePhotoErrorCallbackId = nil
            })
        }
    }

    @objc private func onCancelTapped() {
        if cameraMode == "manual" {
            let callbackId = self.capturePhotoErrorCallbackId
            _teardownCamera()
            if let cbId = callbackId {
                let result = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "User cancelled")
                self.commandDelegate!.send(result, callbackId: cbId)
            }
            self.capturePhotoCallbackId = nil
            self.capturePhotoErrorCallbackId = nil
        } else {
            let callbackId = self.openCameraErrorCallbackId
            _teardownCamera()
            if let cbId = callbackId {
                let result = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "User cancelled")
                self.commandDelegate!.send(result, callbackId: cbId)
            }
            self.openCameraCallbackId = nil
            self.openCameraErrorCallbackId = nil
        }
    }

    @objc private func onNativeOverlayTapped(_ gesture: UITapGestureRecognizer) {
        guard let overlay = self.cameraOverlay else { return }
        let tapPoint = gesture.location(in: overlay)
        let hitView = overlay.hitTest(tapPoint, with: nil)
        if hitView is UIButton { return }

        guard let previewLayer = self.previewLayer else { return }
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: tapPoint)
        _focusAtDevicePoint(devicePoint)
        _showFocusRing(at: tapPoint, in: overlay)
    }

    @objc private func onNativePinchGesture(_ gesture: UIPinchGestureRecognizer) {
        guard let device = _currentCaptureDevice() else { return }
        let minZoom = device.minAvailableVideoZoomFactor
        let maxZoom = min(device.maxAvailableVideoZoomFactor, 10.0)

        switch gesture.state {
        case .began:
            lastZoomFactor = device.videoZoomFactor
        case .changed:
            let newZoom = max(minZoom, min(lastZoomFactor * gesture.scale, maxZoom))
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = newZoom
                device.unlockForConfiguration()
            } catch { }
        case .ended, .cancelled:
            // Persist final zoom so the next gesture starts from here
            lastZoomFactor = device.videoZoomFactor
        default:
            break
        }
    }

    @objc private func onNativeSwitchCameraTapped() {
        _switchCameraInternal()
        DispatchQueue.main.async {
            guard let device = self._currentCaptureDevice() else { return }
            self.torchBtn?.isHidden = !device.hasTorch
        }
    }

    @objc private func onNativeTorchTapped() {
        _setTorchInternal(on: !isTorchOn)
        _updateNativeTorchIcon()
    }

    private func _updateNativeTorchIcon() {
        DispatchQueue.main.async {
            guard let btn = self.torchBtn else { return }
            if #available(iOS 13.0, *) {
                let iconName = self.isTorchOn ? "bolt.fill" : "bolt.slash.fill"
                btn.setImage(UIImage(systemName: iconName), for: .normal)
                btn.tintColor = self.isTorchOn ? .yellow : .white
            }
            btn.backgroundColor = self.isTorchOn
                ? UIColor(red: 0.9, green: 0.66, blue: 0, alpha: 0.8)
                : UIColor(white: 0.2, alpha: 0.7)
        }
    }

    private func _showFocusRing(at point: CGPoint, in parent: UIView) {
        focusRingView?.removeFromSuperview()

        let size: CGFloat = 80
        let ring = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        ring.center = point
        ring.layer.borderColor = UIColor.white.cgColor
        ring.layer.borderWidth = 2
        ring.layer.cornerRadius = size / 2
        ring.alpha = 1.0
        ring.isUserInteractionEnabled = false
        parent.addSubview(ring)
        self.focusRingView = ring

        UIView.animate(withDuration: 0.3, animations: {
            ring.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        }) { _ in
            UIView.animate(withDuration: 0.4, delay: 0.5, options: [], animations: {
                ring.alpha = 0
            }) { _ in
                ring.removeFromSuperview()
                if self.focusRingView === ring { self.focusRingView = nil }
            }
        }
    }

    // MARK: Native overlay plugin methods

    @objc(capturePhoto:)
    func capturePhoto(_ command: CDVInvokedUrlCommand) {
        self.capturePhotoCallbackId = command.callbackId
        self.capturePhotoErrorCallbackId = command.callbackId

        if !_setupCamera() {
            let result = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "Camera not available")
            self.commandDelegate!.send(result, callbackId: command.callbackId)
            self.capturePhotoCallbackId = nil
            self.capturePhotoErrorCallbackId = nil
            return
        }

        _startNativeCamera(mode: "manual")
    }

    @objc(openCamera:)
    func openCamera(_ command: CDVInvokedUrlCommand) {
        self.openCameraCallbackId = command.callbackId
        self.openCameraErrorCallbackId = command.callbackId

        if !_setupCamera() {
            let result = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "Camera not available")
            self.commandDelegate!.send(result, callbackId: command.callbackId)
            self.openCameraCallbackId = nil
            self.openCameraErrorCallbackId = nil
            return
        }

        _startNativeCamera(mode: "auto")

        let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: "Camera opened")
        result?.keepCallback = true
        self.commandDelegate!.send(result, callbackId: command.callbackId)
    }

    @objc(closeCamera:)
    func closeCamera(_ command: CDVInvokedUrlCommand) {
        _teardownCamera()
        self.openCameraCallbackId = nil
        self.openCameraErrorCallbackId = nil
        self.capturePhotoCallbackId = nil
        self.capturePhotoErrorCallbackId = nil

        let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: "Camera closed")
        self.commandDelegate!.send(result, callbackId: command.callbackId)
    }

    @objc(updateStatus:)
    func updateStatus(_ command: CDVInvokedUrlCommand) {
        let text = command.arguments[0] as? String ?? ""
        DispatchQueue.main.async {
            self.statusLabel?.text = text
        }
        let result = CDVPluginResult(status: CDVCommandStatus_OK)
        self.commandDelegate!.send(result, callbackId: command.callbackId)
    }

    // =====================================================================
    // MARK: - MODE 2: Web UI / Behind-Webview (showPreview / hidePreview)
    // =====================================================================

    @objc(showPreview:)
    func showPreview(_ command: CDVInvokedUrlCommand) {
        if !_setupCamera() {
            let result = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "Camera not available")
            self.commandDelegate!.send(result, callbackId: command.callbackId)
            return
        }

        self.uiMode = .behindWebview
        self.latestFrame = nil

        guard let session = self.captureSession else { return }

        DispatchQueue.main.async {
            guard let webView = self.webView, let parentView = webView.superview else { return }

            // Save webview state
            self.savedWebViewOpaque = webView.isOpaque
            self.savedWebViewBgColor = webView.backgroundColor
            self.savedScrollViewBgColor = webView.scrollView.backgroundColor

            // Make webview transparent so camera shows through
            webView.isOpaque = false
            webView.backgroundColor = UIColor.clear
            webView.scrollView.backgroundColor = UIColor.clear

            // Add preview layer BEHIND the webview
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = parentView.bounds
            if let conn = preview.connection, conn.isVideoOrientationSupported {
                conn.videoOrientation = self._currentVideoOrientation()
            }
            parentView.layer.insertSublayer(preview, at: 0)
            self.previewLayer = preview

            self._startOrientationObserver()

            self.cameraSessionQueue.async {
                session.startRunning()

                DispatchQueue.main.async {
                    let caps = self._capabilities()
                    let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: caps)
                    self.commandDelegate!.send(result, callbackId: command.callbackId)
                }
            }
        }
    }

    @objc(hidePreview:)
    func hidePreview(_ command: CDVInvokedUrlCommand) {
        _teardownCamera()
        let result = CDVPluginResult(status: CDVCommandStatus_OK)
        self.commandDelegate!.send(result, callbackId: command.callbackId)
    }

    // =====================================================================
    // MARK: - Shared Camera Controls (work in both modes)
    // =====================================================================

    private func _focusAtDevicePoint(_ point: CGPoint) {
        guard let device = _currentCaptureDevice() else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                device.exposureMode = .autoExpose
            }
            device.unlockForConfiguration()
        } catch { }
    }

    private func _setTorchInternal(on: Bool) {
        guard let device = _currentCaptureDevice(), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
            isTorchOn = on
        } catch { }
    }

    private func _switchCameraInternal() {
        guard let session = self.captureSession else { return }

        if isTorchOn { _setTorchInternal(on: false) }

        let newPosition: AVCaptureDevice.Position = (currentCameraPosition == .back) ? .front : .back

        guard let newDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
              let newInput = try? AVCaptureDeviceInput(device: newDevice) else { return }

        cameraSessionQueue.sync {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            if let currentInput = session.inputs.first as? AVCaptureDeviceInput {
                session.removeInput(currentInput)
            }
            if session.canAddInput(newInput) {
                session.addInput(newInput)
            }
            for output in session.outputs {
                if let connection = output.connection(with: .video), connection.isVideoOrientationSupported {
                    connection.videoOrientation = self._currentVideoOrientation()
                }
            }
        }
        currentCameraPosition = newPosition

        // Reset zoom to 1x
        do {
            try newDevice.lockForConfiguration()
            newDevice.videoZoomFactor = newDevice.minAvailableVideoZoomFactor
            newDevice.unlockForConfiguration()
        } catch { }
        self.lastZoomFactor = newDevice.minAvailableVideoZoomFactor
    }

    // MARK: Shared control plugin methods

    @objc(switchCamera:)
    func switchCamera(_ command: CDVInvokedUrlCommand) {
        guard self.captureSession != nil else {
            let result = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "No active session")
            self.commandDelegate!.send(result, callbackId: command.callbackId)
            return
        }

        _switchCameraInternal()

        let caps = _capabilities()
        let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: caps)
        self.commandDelegate!.send(result, callbackId: command.callbackId)
    }

    @objc(setTorch:)
    func setTorch(_ command: CDVInvokedUrlCommand) {
        let on = command.arguments[0] as? Bool ?? false
        _setTorchInternal(on: on)
        let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: isTorchOn)
        self.commandDelegate!.send(result, callbackId: command.callbackId)
    }

    @objc(setZoom:)
    func setZoom(_ command: CDVInvokedUrlCommand) {
        let factor = command.arguments[0] as? Double ?? 1.0
        guard let device = _currentCaptureDevice() else {
            let result = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "No active camera")
            self.commandDelegate!.send(result, callbackId: command.callbackId)
            return
        }

        let minZoom = device.minAvailableVideoZoomFactor
        let maxZoom = min(device.maxAvailableVideoZoomFactor, 10.0)
        let clampedZoom = max(minZoom, min(CGFloat(factor), maxZoom))

        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clampedZoom
            device.unlockForConfiguration()
            lastZoomFactor = clampedZoom
        } catch { }

        let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: [
            "zoom": clampedZoom,
            "minZoom": minZoom,
            "maxZoom": maxZoom
        ])
        self.commandDelegate!.send(result, callbackId: command.callbackId)
    }

    @objc(focusAtPoint:)
    func focusAtPoint(_ command: CDVInvokedUrlCommand) {
        let x = command.arguments[0] as? Double ?? 0.5
        let y = command.arguments[1] as? Double ?? 0.5

        _focusAtDevicePoint(CGPoint(x: CGFloat(x), y: CGFloat(y)))

        let focusSupported = _currentCaptureDevice()?.isFocusPointOfInterestSupported ?? false
        let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: focusSupported)
        self.commandDelegate!.send(result, callbackId: command.callbackId)
    }

    // =====================================================================
    // MARK: - Frame Capture & OCR (shared)
    // =====================================================================

    @objc(captureFrame:)
    func captureFrame(_ command: CDVInvokedUrlCommand) {
        _syncOutputOrientation()
        self.commandDelegate!.run(inBackground: {
            self.frameLock.lock()
            let currentFrame = self.latestFrame
            self.frameLock.unlock()

            guard let frame = currentFrame else {
                let result = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "No frame available")
                self.commandDelegate!.send(result, callbackId: command.callbackId)
                return
            }

            if let base64 = self.imageToBase64(frame) {
                let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: base64)
                self.commandDelegate!.send(result, callbackId: command.callbackId)
            } else {
                let result = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: "Failed to encode frame")
                self.commandDelegate!.send(result, callbackId: command.callbackId)
            }
        })
    }

    @objc(recognizeText:)
    func recognizeText(_ command: CDVInvokedUrlCommand) {
        let base64String = command.arguments[0] as? String ?? ""
        let options = command.arguments.count > 1 ? command.arguments[1] as? [String: Any] ?? [:] : [:]

        let levelStr = options["level"] as? String ?? "accurate"
        let maxSize = options["maxSize"] as? CGFloat ?? 0
        let minConfidence = options["minConfidence"] as? Float ?? 0.5

        if base64String.isEmpty {
            let pluginResult = CDVPluginResult(
                status: CDVCommandStatus_ERROR,
                messageAs: "No image data provided"
            )
            self.commandDelegate!.send(pluginResult, callbackId: command.callbackId)
            return
        }

        guard let imageData = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters),
              let uiImage = UIImage(data: imageData) else {
            let pluginResult = CDVPluginResult(
                status: CDVCommandStatus_ERROR,
                messageAs: "Invalid image data"
            )
            self.commandDelegate!.send(pluginResult, callbackId: command.callbackId)
            return
        }

        var processedImage = normalizeOrientation(uiImage)
        if maxSize > 0 {
            processedImage = downscaleImage(processedImage, maxSize: maxSize)
        }

        guard let cgImage = processedImage.cgImage else {
            let pluginResult = CDVPluginResult(
                status: CDVCommandStatus_ERROR,
                messageAs: "Failed to process image"
            )
            self.commandDelegate!.send(pluginResult, callbackId: command.callbackId)
            return
        }

        self.commandDelegate!.run(inBackground: {
            let request = VNRecognizeTextRequest { (request, error) in
                if let error = error {
                    let pluginResult = CDVPluginResult(
                        status: CDVCommandStatus_ERROR,
                        messageAs: error.localizedDescription
                    )
                    self.commandDelegate!.send(pluginResult, callbackId: command.callbackId)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    let pluginResult = CDVPluginResult(
                        status: CDVCommandStatus_ERROR,
                        messageAs: "No text observations found"
                    )
                    self.commandDelegate!.send(pluginResult, callbackId: command.callbackId)
                    return
                }

                var blocks: [[String: Any]] = []
                for observation in observations {
                    if let topCandidate = observation.topCandidates(1).first, topCandidate.confidence >= minConfidence {
                        let box = observation.boundingBox
                        blocks.append([
                            "text": topCandidate.string,
                            "confidence": topCandidate.confidence,
                            "x": box.origin.x,
                            "y": 1.0 - box.origin.y - box.size.height,
                            "width": box.size.width,
                            "height": box.size.height
                        ])
                    }
                }

                let result: [String: Any] = [
                    "imageWidth": cgImage.width,
                    "imageHeight": cgImage.height,
                    "blocks": blocks
                ]

                let pluginResult = CDVPluginResult(
                    status: CDVCommandStatus_OK,
                    messageAs: result
                )
                self.commandDelegate!.send(pluginResult, callbackId: command.callbackId)
            }

            request.recognitionLevel = levelStr == "fast" ? .fast : .accurate

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                let pluginResult = CDVPluginResult(
                    status: CDVCommandStatus_ERROR,
                    messageAs: error.localizedDescription
                )
                self.commandDelegate!.send(pluginResult, callbackId: command.callbackId)
            }
        })
    }
}
