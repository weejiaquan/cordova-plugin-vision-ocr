# cordova-plugin-vision-ocr

Cordova plugin for on-device OCR text recognition using Apple's Vision framework (iOS). Includes a live camera preview with two UI modes — a built-in native overlay or a transparent behind-webview mode for fully custom HTML controls.

## Installation

```bash
cordova plugin add cordova-plugin-vision-ocr
```

Or from a local path:

```bash
cordova plugin add /path/to/cordova-plugin-vision-ocr
```

### Requirements

- iOS 13.0+
- Cordova iOS platform
- Automatically installs `cordova-plugin-add-swift-support` and links `Vision.framework`

## Camera UI Modes

The plugin supports two ways to display the live camera feed. Both share the same camera controls and frame capture API.

### Mode 1: Native Overlay

The plugin creates its own full-screen UIView overlay on top of the webview with native buttons and controls. Good for quick integration — zero HTML/CSS required.

**Includes out of the box:**
- Live camera preview (full screen)
- Capture / Cancel buttons (manual mode)
- Scanning status label + Cancel (auto mode)
- Camera switch button (if multiple cameras)
- Torch toggle button (if device has flash)
- Tap-to-focus with visual ring
- Pinch-to-zoom

### Mode 2: Web UI (behind-webview)

The camera preview is placed behind a transparent WKWebView. Your app controls all UI through HTML/JS. Use this when you need custom buttons, branding, or mode-switching (e.g. toggling between OCR and QR scanning).

**You provide:**
- All visible UI (buttons, status text, layout)
- You must hide your page content and set transparent backgrounds so the camera shows through

**The plugin provides:**
- Camera preview behind the webview
- JS methods for torch, camera switch, zoom, focus, and frame capture

## API Reference

### OCR

#### `VisionOCR.recognizeText(base64String, success, failure, options)`

Performs OCR on a base64-encoded image.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `base64String` | `string` | Yes | Base64-encoded image data (no `data:` prefix) |
| `success` | `function` | Yes | Receives result object |
| `failure` | `function` | Yes | Receives error string |
| `options` | `object` | No | `{ level: "fast"\|"accurate", maxSize: number }` |

**Result:**

```javascript
{
  imageWidth: 3024,
  imageHeight: 4032,
  blocks: [
    { text: "Hello", confidence: 0.98, x: 0.12, y: 0.34, width: 0.45, height: 0.03 }
  ]
}
```

Coordinates are normalized (0-1), origin at top-left.

---

### Native Overlay Methods

#### `VisionOCR.capturePhoto(success, failure)`

Opens the native camera overlay in manual mode. User taps Capture to take a photo or Cancel to dismiss.

```javascript
VisionOCR.capturePhoto(function(base64) {
  // base64 JPEG string (no data: prefix)
  var dataUrl = 'data:image/jpeg;base64,' + base64;
}, function(err) {
  // "User cancelled" or camera error
});
```

#### `VisionOCR.openCamera(success, failure)`

Opens the native camera overlay in auto/continuous mode. Returns immediately via `keepCallback` — the camera stays open for repeated frame capture.

```javascript
VisionOCR.openCamera(function() {
  // Camera is open — start polling with captureFrame()
  pollLoop();
}, function(err) {
  // "User cancelled" or camera error
});
```

#### `VisionOCR.closeCamera(success, failure)`

Closes the native camera overlay and stops the session.

```javascript
VisionOCR.closeCamera();
```

#### `VisionOCR.updateStatus(text, success, failure)`

Updates the status label text on the native auto-mode overlay.

```javascript
VisionOCR.updateStatus('Scanning...');
VisionOCR.updateStatus('Match: 1234-5678');
```

---

### Web UI (Behind-Webview) Methods

#### `VisionOCR.showPreview(success, failure)`

Starts the camera and places the preview layer behind the webview. Makes the webview transparent so the camera is visible through any transparent areas of your HTML.

Returns device capabilities so you can conditionally show controls.

```javascript
VisionOCR.showPreview(function(caps) {
  // caps = {
  //   hasTorch: true,
  //   hasMultipleCameras: true,
  //   position: "back",
  //   minZoom: 1.0,
  //   maxZoom: 10.0
  // }

  // Hide your page content and make backgrounds transparent
  document.documentElement.classList.add('camera-active');

  // Build your HTML overlay...
}, function(err) {
  console.error('Camera error:', err);
});
```

**Important:** You must hide your existing page content and set transparent backgrounds on `<html>` and `<body>` for the camera to be visible. Example CSS:

```css
html.camera-active,
html.camera-active body {
  background: transparent !important;
}
html.camera-active body > *:not(#my-camera-overlay):not(script):not(style):not(link) {
  display: none !important;
}
```

#### `VisionOCR.hidePreview(success, failure)`

Stops the camera and restores the webview to its original opaque state.

```javascript
VisionOCR.hidePreview(function() {
  document.documentElement.classList.remove('camera-active');
  document.getElementById('my-camera-overlay').remove();
});
```

---

### Shared Controls

These methods work in both Native Overlay and Web UI modes.

#### `VisionOCR.captureFrame(success, failure)`

Grabs the latest frame from the running camera session as a base64 JPEG.

```javascript
VisionOCR.captureFrame(function(base64) {
  // Process the frame (OCR, display, etc.)
  VisionOCR.recognizeText(base64, onResult, onError, { level: 'fast' });
}, function(err) {
  // "No frame available" — camera may not be ready yet
});
```

#### `VisionOCR.switchCamera(success, failure)`

Toggles between front and back cameras. Turns off torch before switching. Returns updated capabilities.

```javascript
VisionOCR.switchCamera(function(caps) {
  // caps.position is now "front" or "back"
  // caps.hasTorch reflects the new camera's capabilities
  torchButton.style.display = caps.hasTorch ? '' : 'none';
});
```

#### `VisionOCR.setTorch(on, success, failure)`

Turns the torch (flashlight) on or off. Only works on cameras that have a torch (typically rear-facing).

```javascript
VisionOCR.setTorch(true, function(isOn) {
  // isOn = true
});

VisionOCR.setTorch(false, function(isOn) {
  // isOn = false
});
```

#### `VisionOCR.setZoom(factor, success, failure)`

Sets the camera zoom level. Factor is clamped between the device's min and max (capped at 10x).

```javascript
VisionOCR.setZoom(2.5, function(result) {
  // result = { zoom: 2.5, minZoom: 1.0, maxZoom: 10.0 }
});
```

#### `VisionOCR.focusAtPoint(x, y, success, failure)`

Triggers autofocus and auto-exposure at a normalized point (0-1 range, origin top-left).

```javascript
// Focus at center of frame
VisionOCR.focusAtPoint(0.5, 0.5, function(applied) {
  // applied = true if device supports focus point of interest
});

// Focus where user tapped (convert from screen coords)
element.addEventListener('click', function(e) {
  var rect = element.getBoundingClientRect();
  var x = (e.clientX - rect.left) / rect.width;
  var y = (e.clientY - rect.top) / rect.height;
  VisionOCR.focusAtPoint(x, y);
});
```

---

## Usage Examples

### Native Overlay — Manual Capture + OCR

```javascript
VisionOCR.capturePhoto(function(base64) {
  VisionOCR.recognizeText(base64, function(result) {
    result.blocks.forEach(function(block) {
      console.log(block.text, block.confidence);
    });
  }, function(err) {
    console.error('OCR failed:', err);
  }, { level: 'accurate', maxSize: 1920 });
}, function(err) {
  // User cancelled
});
```

### Native Overlay — Auto-Scan Loop

```javascript
var scanning = true;

VisionOCR.openCamera(function() {
  pollForText();
}, function(err) {
  scanning = false;
});

function pollForText() {
  if (!scanning) return;

  VisionOCR.captureFrame(function(base64) {
    VisionOCR.recognizeText(base64, function(result) {
      var match = result.blocks.find(function(b) {
        return /^\d{4}-\d{4}$/.test(b.text);  // example: match gift card pattern
      });
      if (match) {
        scanning = false;
        VisionOCR.closeCamera();
        console.log('Found:', match.text);
      } else {
        VisionOCR.updateStatus('No match — scanning...');
        setTimeout(pollForText, 500);
      }
    }, function() {
      setTimeout(pollForText, 500);
    }, { level: 'fast', maxSize: 1080 });
  }, function() {
    setTimeout(pollForText, 500);
  });
}
```

### Web UI — Custom HTML Camera Screen

```javascript
VisionOCR.showPreview(function(caps) {
  // 1. Hide page content
  document.documentElement.classList.add('camera-active');

  // 2. Build HTML overlay
  var overlay = document.createElement('div');
  overlay.id = 'my-camera-overlay';
  overlay.style.cssText = 'position:fixed;top:0;left:0;right:0;bottom:0;z-index:9999;display:flex;flex-direction:column;';
  overlay.innerHTML =
    '<div style="flex:1;background:transparent;"></div>' +
    '<div style="background:rgba(0,0,0,0.85);padding:15px;display:flex;gap:8px;justify-content:center;">' +
      '<button id="cam-capture">Capture</button>' +
      (caps.hasMultipleCameras ? '<button id="cam-switch">Switch</button>' : '') +
      (caps.hasTorch ? '<button id="cam-torch">Torch</button>' : '') +
      '<button id="cam-cancel">Cancel</button>' +
    '</div>';
  document.body.appendChild(overlay);

  // 3. Wire up buttons
  document.getElementById('cam-capture').onclick = function() {
    VisionOCR.captureFrame(function(base64) {
      closeCamera();
      processImage(base64);
    });
  };

  if (caps.hasMultipleCameras) {
    document.getElementById('cam-switch').onclick = function() {
      VisionOCR.switchCamera(function(newCaps) {
        var torchBtn = document.getElementById('cam-torch');
        if (torchBtn) torchBtn.style.display = newCaps.hasTorch ? '' : 'none';
      });
    };
  }

  if (caps.hasTorch) {
    var torchOn = false;
    document.getElementById('cam-torch').onclick = function() {
      torchOn = !torchOn;
      VisionOCR.setTorch(torchOn);
      this.style.background = torchOn ? '#e6a800' : '';
    };
  }

  document.getElementById('cam-cancel').onclick = closeCamera;

  function closeCamera() {
    VisionOCR.hidePreview();
    document.documentElement.classList.remove('camera-active');
    overlay.remove();
  }
});
```

Required CSS for the example above:

```css
html.camera-active,
html.camera-active body {
  background: transparent !important;
}
html.camera-active body > *:not(#my-camera-overlay):not(script):not(style):not(link) {
  display: none !important;
}
```

## Performance Guide

| Device | Chip | Neural Engine | Recommended Settings |
|--------|------|---------------|---------------------|
| iPhone 14 Pro Max | A16 | 16-core | `accurate`, no maxSize limit |
| iPhone X / 8 | A11 | 2-core | `accurate`, `maxSize: 1920` |
| iPad Mini 4 | A8 | None | `fast`, `maxSize: 1080` |
| iPad Air 2 | A8X | None | `fast`, `maxSize: 1080` |

Devices without a Neural Engine (A8-A10) run OCR on the CPU only. Using `fast` mode + `maxSize: 1080` reduces processing from ~20s to ~2-3s on these devices.

## Image Orientation

The plugin automatically normalizes EXIF orientation before processing. Portrait photos taken on iOS cameras store pixel data in landscape orientation with an EXIF flag — the plugin re-draws the image with correct orientation baked into the pixel data so bounding box coordinates match what browsers display.

## Cross-Platform Notes

This plugin is iOS-only. For a cross-platform OCR solution, pair with a companion Android plugin that returns the same response shape:

```javascript
if (window.VisionOCR) {
  VisionOCR.recognizeText(base64, success, failure, opts);
} else if (window.AndroidOCR) {
  AndroidOCR.recognizeText(base64, success, failure, opts);
}
```

## License

ISC
