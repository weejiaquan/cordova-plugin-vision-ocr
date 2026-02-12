cordova.define("cordova-plugin-vision-ocr.VisionOCR", function(require, exports, module) {
var exec = require('cordova/exec');

var VisionOCR = function () {};

// ---- Mode 1: Native Overlay ----
// Plugin builds its own native UIView overlay with buttons and controls.

// Manual mode: opens native camera overlay, returns base64 JPEG on capture.
VisionOCR.capturePhoto = function (callback, failure) {
    return exec(callback, failure, "VisionOCR", "capturePhoto", []);
};

// Auto mode: opens native camera overlay, returns immediately (keepCallback).
VisionOCR.openCamera = function (callback, failure) {
    return exec(callback, failure, "VisionOCR", "openCamera", []);
};

// Close native camera overlay and stop session.
VisionOCR.closeCamera = function (callback, failure) {
    return exec(callback, failure, "VisionOCR", "closeCamera", []);
};

// Update status label text on native auto mode overlay.
VisionOCR.updateStatus = function (text, callback, failure) {
    return exec(callback, failure, "VisionOCR", "updateStatus", [text]);
};

// ---- Mode 2: Web UI (behind-webview) ----
// Camera preview behind a transparent WKWebView; all UI is HTML/JS.

// Start camera preview behind webview (webview becomes transparent).
// Callback receives capabilities: { hasTorch, hasMultipleCameras, position, minZoom, maxZoom }
VisionOCR.showPreview = function (callback, failure) {
    return exec(callback, failure, "VisionOCR", "showPreview", []);
};

// Stop camera preview and restore webview opacity.
VisionOCR.hidePreview = function (callback, failure) {
    return exec(callback, failure, "VisionOCR", "hidePreview", []);
};

// ---- Shared Controls (work in both modes) ----

// Switch between front/back camera. Returns updated capabilities.
VisionOCR.switchCamera = function (callback, failure) {
    return exec(callback, failure, "VisionOCR", "switchCamera", []);
};

// Toggle torch on/off. Returns current torch state (bool).
VisionOCR.setTorch = function (on, callback, failure) {
    return exec(callback, failure, "VisionOCR", "setTorch", [on]);
};

// Set zoom factor. Returns { zoom, minZoom, maxZoom }.
VisionOCR.setZoom = function (factor, callback, failure) {
    return exec(callback, failure, "VisionOCR", "setZoom", [factor]);
};

// Focus at normalized point (0-1). Returns bool (focus applied).
VisionOCR.focusAtPoint = function (x, y, callback, failure) {
    return exec(callback, failure, "VisionOCR", "focusAtPoint", [x, y]);
};

// Grab latest frame as base64 JPEG from running camera session.
VisionOCR.captureFrame = function (callback, failure) {
    return exec(callback, failure, "VisionOCR", "captureFrame", []);
};

// ---- OCR ----

// options: { level: "fast"|"accurate", maxSize: 1920 }
VisionOCR.recognizeText = function (base64String, callback, failure, options) {
    return exec(callback, failure, "VisionOCR", "recognizeText", [base64String, options || {}]);
};

module.exports = VisionOCR;
});
