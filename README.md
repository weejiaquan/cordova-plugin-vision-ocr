# cordova-plugin-vision-ocr

Cordova plugin for **on-device OCR text recognition** with a live camera preview. Works on both **iOS** and **Android** — no cloud services, no API keys, no internet required.

Uses Apple Vision framework on iOS and Google ML Kit on Android.

The plugin has two camera UI modes:

1. **Native Overlay** — a built-in full-screen camera UI with buttons, gestures, and controls. Zero HTML/CSS needed.
2. **Behind-Webview** — camera preview behind a transparent webview so you build 100% custom UI in HTML/JS.

Both modes share the same camera controls and OCR API.

---

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Camera UI Modes](#camera-ui-modes)
- [API Reference](#api-reference)
  - [OCR](#ocr)
  - [Native Overlay Methods](#native-overlay-methods)
  - [Behind-Webview Methods](#behind-webview-methods)
  - [Shared Controls](#shared-controls)
- [Full Examples](#full-examples)
- [Performance Guide](#performance-guide)
- [Platform Notes](#platform-notes)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Installation

### From a local path (most common during development)

```bash
cordova plugin add /path/to/cordova-plugin-vision-ocr
```

### From npm (if published)

```bash
cordova plugin add cordova-plugin-vision-ocr
```

### What happens when you install

The plugin automatically:

- **iOS:** Links `Vision.framework` and `AVFoundation.framework`, installs Swift support.
- **Android:** Adds CameraX and ML Kit Text Recognition via Gradle. No Firebase setup needed.

You do **not** need to manually edit any Gradle files, Podfiles, or framework references.

### Requirements

| Platform | Minimum Version | Notes |
|----------|----------------|-------|
| iOS | 13.0+ | Uses Apple Vision framework |
| Android | API 21 (Android 5.0+) | Uses CameraX + ML Kit |
| Cordova | 10.0+ | |
| cordova-ios | 6.0+ | |
| cordova-android | 10.0+ | |

### Permissions

The plugin declares `CAMERA` permission in its `plugin.xml`. You do **not** need to add it yourself.

- **iOS:** Add a camera usage description to your `config.xml` (required by Apple):

```xml
<platform name="ios">
    <edit-config target="NSCameraUsageDescription" file="*-Info.plist" mode="merge">
        <string>This app uses the camera to scan and read text.</string>
    </edit-config>
</platform>
```

- **Android:** The plugin requests camera permission at runtime automatically. The user will see Android's standard permission dialog the first time a camera method is called. If they deny it, the failure callback receives `"Camera permission denied"`.

---

## Quick Start

The fastest way to get OCR working — just 3 lines:

```javascript
// 1. Open the built-in camera overlay
VisionOCR.capturePhoto(function(base64) {

    // 2. Run OCR on the captured photo
    VisionOCR.recognizeText(base64, function(result) {

        // 3. Use the results
        result.blocks.forEach(function(block) {
            console.log(block.text);  // "Hello World"
        });

    }, function(err) {
        alert('OCR failed: ' + err);
    });

}, function(err) {
    // User tapped Cancel, or camera error
    console.log(err);
});
```

That's it. The plugin handles all camera setup, permissions, UI, and cleanup.

---

## Camera UI Modes

### Mode 1: Native Overlay

The plugin creates its own full-screen camera view on top of the webview with native buttons and controls. Good for quick integration — zero HTML/CSS required.

**Includes out of the box:**
- Live camera preview (full screen)
- Capture / Cancel buttons (manual mode)
- Scanning status label + Cancel (auto mode)
- Camera switch button (if multiple cameras)
- Torch toggle button (if device has flash)
- Tap-to-focus with visual ring animation
- Pinch-to-zoom

**When to use:** You just want a working camera screen without custom design.

### Mode 2: Behind-Webview

The camera preview is placed behind a transparent webview. Your app controls all UI through HTML/JS/CSS. Use this when you need custom buttons, branding, overlays, or complex UI like switching between OCR and QR scanning.

**You provide:**
- All visible UI (buttons, status text, layout) as HTML
- CSS to hide your page content and make backgrounds transparent

**The plugin provides:**
- Camera preview behind the webview
- JS methods for torch, camera switch, zoom, focus, and frame capture

**When to use:** You need full control over the camera UI design.

---

## API Reference

All methods are available on the global `VisionOCR` object (or `window.VisionOCR`).

Every method follows the pattern:

```javascript
VisionOCR.methodName(arg1, arg2, successCallback, failureCallback);
```

- **Success callback** — called with the result on success
- **Failure callback** — called with an error string on failure

### OCR

#### `VisionOCR.recognizeText(base64String, success, failure, options)`

Performs OCR on a base64-encoded image. This is the core method — everything else is just getting an image to pass to this.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `base64String` | `string` | Yes | Base64-encoded JPEG or PNG (no `data:image/...;base64,` prefix!) |
| `success` | `function` | Yes | Receives the OCR result object |
| `failure` | `function` | Yes | Receives an error string |
| `options` | `object` | No | See options table below |

**Options:**

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `level` | `string` | `"accurate"` | `"fast"` or `"accurate"`. On iOS this maps directly to Apple Vision recognition levels. On Android, ML Kit has only one mode (equivalent to "accurate") — use `maxSize` to improve speed instead. |
| `maxSize` | `number` | `0` (no limit) | Downscale the image so its longest edge is at most this many pixels before OCR. **This is the single biggest performance lever.** Set to `1080` for fast scanning on older devices. |

**Success result:**

```javascript
{
  imageWidth: 3024,       // Width of the processed image in pixels
  imageHeight: 4032,      // Height of the processed image in pixels
  blocks: [
    {
      text: "Hello World",  // The recognized text
      confidence: 0.98,     // 0.0 to 1.0 (1.0 = very confident)
      x: 0.12,             // Left edge (0-1, normalized)
      y: 0.34,             // Top edge (0-1, normalized)
      width: 0.45,         // Width (0-1, normalized)
      height: 0.03         // Height (0-1, normalized)
    }
  ]
}
```

**About bounding box coordinates:**
- All coordinates are normalized from 0 to 1 (not pixel values)
- Origin is **top-left** of the image
- To convert to pixels: `pixelX = x * imageWidth`, `pixelY = y * imageHeight`
- Consistent across iOS and Android

**Common errors:**
- `"No image data provided"` — you passed an empty string
- `"Invalid image data"` — the base64 string couldn't be decoded into an image

---

### Native Overlay Methods

These methods open the plugin's built-in camera screen.

#### `VisionOCR.capturePhoto(success, failure)`

Opens the camera in **manual mode**. The user sees a live preview with a Capture button and a Cancel button. When they tap Capture, the callback fires with the photo.

```javascript
VisionOCR.capturePhoto(function(base64) {
    // base64 is a JPEG string (no data: prefix)
    // Display it:
    var img = document.createElement('img');
    img.src = 'data:image/jpeg;base64,' + base64;
    document.body.appendChild(img);

    // Or run OCR on it:
    VisionOCR.recognizeText(base64, handleResult, handleError);

}, function(err) {
    if (err === 'User cancelled') {
        // User tapped Cancel — totally normal
    } else {
        alert('Camera error: ' + err);
    }
});
```

#### `VisionOCR.openCamera(success, failure)`

Opens the camera in **auto/continuous mode**. The camera stays open and you repeatedly call `captureFrame()` to grab frames for OCR. The success callback fires once immediately when the camera opens (with `keepCallback` — the camera stays open).

```javascript
VisionOCR.openCamera(function() {
    // Camera is now open — start your scan loop
    startScanning();
}, function(err) {
    // "User cancelled" or camera error
    console.log(err);
});
```

#### `VisionOCR.closeCamera(success, failure)`

Closes the native camera overlay and stops the camera session. Call this when you're done scanning.

```javascript
VisionOCR.closeCamera(function() {
    console.log('Camera closed');
});
```

#### `VisionOCR.updateStatus(text, success, failure)`

Updates the green status label text shown on the auto-mode overlay. Use this to give the user feedback about what's happening.

```javascript
VisionOCR.updateStatus('Scanning...');
VisionOCR.updateStatus('Found: 1234-5678');
VisionOCR.updateStatus('No match — keep trying');
```

---

### Behind-Webview Methods

These methods show the camera behind your webview for fully custom UI.

#### `VisionOCR.showPreview(success, failure)`

Starts the camera and places the preview behind the webview. Makes the webview transparent so the camera shows through any transparent areas of your HTML.

Returns a **capabilities object** so you can conditionally show/hide controls.

```javascript
VisionOCR.showPreview(function(caps) {
    console.log(caps);
    // {
    //   hasTorch: true,           // Can this camera use the flash as a torch?
    //   hasMultipleCameras: true,  // Does the device have front + back cameras?
    //   position: "back",          // Currently using "back" or "front" camera
    //   minZoom: 1.0,              // Minimum zoom level
    //   maxZoom: 10.0              // Maximum zoom level (capped at 10x)
    // }
}, function(err) {
    alert('Camera error: ' + err);
});
```

**Important:** You **must** make your HTML backgrounds transparent for the camera to show through. Add this CSS:

```css
html.camera-active,
html.camera-active body {
    background: transparent !important;
}
/* Hide everything except your camera overlay */
html.camera-active body > *:not(#camera-overlay):not(script):not(style):not(link) {
    display: none !important;
}
```

Then toggle the class when opening/closing the camera:

```javascript
// When opening:
document.documentElement.classList.add('camera-active');

// When closing:
document.documentElement.classList.remove('camera-active');
```

#### `VisionOCR.hidePreview(success, failure)`

Stops the camera and restores the webview to its original opaque state.

```javascript
VisionOCR.hidePreview(function() {
    document.documentElement.classList.remove('camera-active');
});
```

---

### Shared Controls

These methods work in **both** Native Overlay and Behind-Webview modes. You must have an active camera session (via `openCamera`, `capturePhoto`, or `showPreview`) before calling these.

#### `VisionOCR.captureFrame(success, failure)`

Grabs the latest frame from the running camera as a base64 JPEG string. This is how you get images for OCR during continuous scanning.

```javascript
VisionOCR.captureFrame(function(base64) {
    // Got a frame — run OCR on it
    VisionOCR.recognizeText(base64, onResult, onError, { level: 'fast', maxSize: 1080 });
}, function(err) {
    // "No frame available" — camera may still be starting up, just retry
    console.log(err);
});
```

#### `VisionOCR.switchCamera(success, failure)`

Toggles between front and back cameras. Automatically turns off the torch before switching. Returns updated capabilities (the front camera usually has no torch).

```javascript
VisionOCR.switchCamera(function(caps) {
    console.log('Now using:', caps.position);  // "front" or "back"
    // Update your UI based on new capabilities
    document.getElementById('torch-btn').style.display = caps.hasTorch ? '' : 'none';
});
```

#### `VisionOCR.setTorch(on, success, failure)`

Turns the torch (flashlight) on or off. Only works on cameras with a flash (typically the rear camera). Silently does nothing if the camera has no torch.

```javascript
// Turn on
VisionOCR.setTorch(true, function(isOn) {
    console.log('Torch is now:', isOn);  // true
});

// Turn off
VisionOCR.setTorch(false, function(isOn) {
    console.log('Torch is now:', isOn);  // false
});
```

#### `VisionOCR.setZoom(factor, success, failure)`

Sets the camera zoom level. The factor is automatically clamped between the device's minimum and maximum zoom (capped at 10x).

```javascript
VisionOCR.setZoom(2.5, function(result) {
    console.log(result);
    // { zoom: 2.5, minZoom: 1.0, maxZoom: 10.0 }
});

// Zoom all the way out
VisionOCR.setZoom(1.0, function(result) {});

// Zoom all the way in (will be capped at device max, up to 10x)
VisionOCR.setZoom(99, function(result) {
    console.log('Actual zoom:', result.zoom);  // e.g. 10.0
});
```

#### `VisionOCR.focusAtPoint(x, y, success, failure)`

Triggers autofocus and auto-exposure at a specific point. Coordinates are normalized (0-1 range), origin at top-left.

```javascript
// Focus at center
VisionOCR.focusAtPoint(0.5, 0.5, function(supported) {
    console.log('Focus supported:', supported);  // true on most devices
});

// Focus where user tapped (behind-webview mode)
myOverlay.addEventListener('click', function(e) {
    var rect = myOverlay.getBoundingClientRect();
    var x = (e.clientX - rect.left) / rect.width;
    var y = (e.clientY - rect.top) / rect.height;
    VisionOCR.focusAtPoint(x, y);
});
```

---

## Full Examples

### Example 1: One-Shot Photo + OCR

The simplest possible use. Open camera, take photo, run OCR, done.

```javascript
function scanDocument() {
    VisionOCR.capturePhoto(function(base64) {
        VisionOCR.recognizeText(base64, function(result) {
            if (result.blocks.length === 0) {
                alert('No text found in the image');
                return;
            }

            // Combine all text
            var allText = result.blocks.map(function(b) { return b.text; }).join('\n');
            alert('Found text:\n' + allText);

        }, function(err) {
            alert('OCR error: ' + err);
        }, { level: 'accurate', maxSize: 1920 });
    }, function(err) {
        if (err !== 'User cancelled') {
            alert('Camera error: ' + err);
        }
    });
}
```

### Example 2: Auto-Scan Loop (Search for a Pattern)

Continuously scan until you find text matching a pattern (e.g. a gift card code).

```javascript
var scanning = false;

function startAutoScan() {
    scanning = true;

    VisionOCR.openCamera(function() {
        scanLoop();
    }, function(err) {
        scanning = false;
        alert('Camera error: ' + err);
    });
}

function scanLoop() {
    if (!scanning) return;

    VisionOCR.captureFrame(function(base64) {
        VisionOCR.recognizeText(base64, function(result) {

            // Look for a gift card pattern: XXXX-XXXX-XXXX-XXXX
            var match = result.blocks.find(function(b) {
                return /^\d{4}-\d{4}-\d{4}-\d{4}$/.test(b.text.trim());
            });

            if (match) {
                // Found it! Stop scanning
                scanning = false;
                VisionOCR.closeCamera();
                alert('Found code: ' + match.text);
            } else {
                // No match yet — update status and try again
                VisionOCR.updateStatus('Scanning... point at the code');
                setTimeout(scanLoop, 500);  // Scan twice per second
            }

        }, function() {
            setTimeout(scanLoop, 500);
        }, { level: 'fast', maxSize: 1080 });
    }, function() {
        // No frame yet — camera still starting up
        setTimeout(scanLoop, 500);
    });
}

function stopAutoScan() {
    scanning = false;
    VisionOCR.closeCamera();
}
```

### Example 3: Custom HTML Camera UI (Behind-Webview)

Build your own camera screen with HTML buttons.

```html
<style>
    html.camera-active,
    html.camera-active body {
        background: transparent !important;
    }
    html.camera-active body > *:not(#camera-overlay):not(script):not(style):not(link) {
        display: none !important;
    }
    #camera-overlay {
        position: fixed;
        top: 0; left: 0; right: 0; bottom: 0;
        z-index: 9999;
        display: flex;
        flex-direction: column;
    }
    #camera-overlay .viewfinder {
        flex: 1;
        background: transparent;
    }
    #camera-overlay .toolbar {
        background: rgba(0,0,0,0.85);
        padding: 15px;
        display: flex;
        gap: 8px;
        justify-content: center;
    }
    #camera-overlay .toolbar button {
        padding: 12px 20px;
        border: none;
        border-radius: 8px;
        color: white;
        font-size: 16px;
        cursor: pointer;
    }
    #camera-overlay .toolbar button.primary { background: #4a8fd9; }
    #camera-overlay .toolbar button.secondary { background: #555; }
</style>
```

```javascript
function openCustomCamera() {
    VisionOCR.showPreview(function(caps) {
        // Make webview transparent
        document.documentElement.classList.add('camera-active');

        // Build overlay
        var overlay = document.createElement('div');
        overlay.id = 'camera-overlay';
        overlay.innerHTML =
            '<div class="viewfinder"></div>' +
            '<div class="toolbar">' +
                '<button class="primary" id="btn-capture">Capture</button>' +
                (caps.hasMultipleCameras ? '<button class="secondary" id="btn-switch">Flip</button>' : '') +
                (caps.hasTorch ? '<button class="secondary" id="btn-torch">Torch</button>' : '') +
                '<button class="secondary" id="btn-close">Close</button>' +
            '</div>';
        document.body.appendChild(overlay);

        // Capture button
        document.getElementById('btn-capture').onclick = function() {
            VisionOCR.captureFrame(function(base64) {
                closeCustomCamera();
                VisionOCR.recognizeText(base64, function(result) {
                    alert('Found ' + result.blocks.length + ' text blocks');
                }, function(err) {
                    alert('OCR error: ' + err);
                });
            });
        };

        // Switch camera button
        var switchBtn = document.getElementById('btn-switch');
        if (switchBtn) {
            switchBtn.onclick = function() {
                VisionOCR.switchCamera(function(newCaps) {
                    var torchBtn = document.getElementById('btn-torch');
                    if (torchBtn) torchBtn.style.display = newCaps.hasTorch ? '' : 'none';
                });
            };
        }

        // Torch button
        var torchBtn = document.getElementById('btn-torch');
        if (torchBtn) {
            var torchOn = false;
            torchBtn.onclick = function() {
                torchOn = !torchOn;
                VisionOCR.setTorch(torchOn);
                torchBtn.style.background = torchOn ? '#e6a800' : '#555';
            };
        }

        // Close button
        document.getElementById('btn-close').onclick = closeCustomCamera;

        // Tap to focus on the viewfinder area
        overlay.querySelector('.viewfinder').addEventListener('click', function(e) {
            var rect = this.getBoundingClientRect();
            var x = (e.clientX - rect.left) / rect.width;
            var y = (e.clientY - rect.top) / rect.height;
            VisionOCR.focusAtPoint(x, y);
        });

    }, function(err) {
        alert('Camera error: ' + err);
    });
}

function closeCustomCamera() {
    VisionOCR.hidePreview();
    document.documentElement.classList.remove('camera-active');
    var overlay = document.getElementById('camera-overlay');
    if (overlay) overlay.remove();
}
```

---

## Performance Guide

### The `maxSize` Option

This is the most important setting for performance. It downscales the image before OCR, which dramatically reduces processing time on slower devices.

| `maxSize` | Good for | Trade-off |
|-----------|----------|-----------|
| `0` (default) | Full quality OCR on powerful devices | Slowest, most accurate |
| `1920` | General use on modern phones | Good balance |
| `1080` | Fast scanning / continuous mode | Slightly lower accuracy on small text |
| `720` | Very old / slow devices | May miss small or thin text |

### iOS Performance

| Device | Chip | Recommended Settings |
|--------|------|---------------------|
| iPhone 12+ | A14+ | `level: "accurate"`, no maxSize limit |
| iPhone X / 8 | A11 | `level: "accurate"`, `maxSize: 1920` |
| iPad Mini 4, iPad Air 2 | A8/A8X | `level: "fast"`, `maxSize: 1080` |

iOS has two recognition levels:
- `"accurate"` — slower, better accuracy (default)
- `"fast"` — faster, good for continuous scanning

### Android Performance

| Device Category | Recommended Settings |
|----------------|---------------------|
| Flagship (2020+) | `maxSize: 1920` or no limit |
| Mid-range | `maxSize: 1080` |
| Budget / old devices | `maxSize: 720` |

Android ML Kit has only one recognition quality level (roughly equivalent to iOS "accurate"). **Use `maxSize` to control speed.** For continuous scanning on any Android device, `maxSize: 1080` is recommended.

### Continuous Scanning Tips

For auto-scan loops (polling `captureFrame` + `recognizeText` repeatedly):

```javascript
// Good settings for continuous scanning on any device
var scanOptions = { level: 'fast', maxSize: 1080 };

// Poll every 500ms (2 scans per second) — a good default
setTimeout(scanLoop, 500);

// On powerful devices you can poll every 200-300ms
// On old devices, stick with 500-1000ms
```

---

## Platform Notes

### iOS

- Uses **Apple Vision framework** (`VNRecognizeTextRequest`)
- Supports `level: "fast"` and `level: "accurate"` natively
- Camera uses `AVCaptureSession` with `AVCaptureVideoPreviewLayer`
- Requires iOS 13.0+
- EXIF orientation is automatically normalized before OCR

### Android

- Uses **Google ML Kit Text Recognition** (on-device, no Firebase or cloud needed)
- Uses **CameraX** for camera management (handles lifecycle, rotation, and orientation automatically)
- Only one recognition quality level (always "accurate"). Use `maxSize` for speed control.
- Camera permission is requested at runtime automatically
- Minimum API 21 (Android 5.0 Lollipop)
- No `google-services.json` or Firebase setup required

### Differences Between Platforms

| Feature | iOS | Android |
|---------|-----|---------|
| OCR engine | Apple Vision | Google ML Kit |
| `level: "fast"` | Distinct fast mode | Same as accurate (use `maxSize` instead) |
| Camera API | AVFoundation | CameraX |
| Min version | iOS 13 | API 21 (Android 5.0) |
| Orientation handling | Manual EXIF normalization | Automatic via CameraX |
| Permissions | `NSCameraUsageDescription` plist | Runtime permission dialog |

**The API is identical across platforms.** Your JavaScript code does not need any `if (iOS)` / `if (Android)` branching. The same calls, same parameters, same result shapes work on both.

---

## Troubleshooting

### "Camera not available"
- The device has no camera, or another app is using it.
- On Android, this can happen if the activity was destroyed and recreated. Try again.

### "Camera permission denied"
- Android only. The user denied the permission dialog.
- You can prompt them to go to Settings: `cordova.plugins.settings.open()` or direct them manually.
- The plugin will ask again next time a camera method is called.

### Camera preview is black
- **Behind-webview mode:** Make sure your HTML/CSS backgrounds are `transparent`. The camera is behind the webview — if any element has a solid background, it will cover the camera.
- Check that you added the `camera-active` CSS class (see examples above).

### OCR returns empty blocks array
- The image may not contain readable text.
- Try with `maxSize: 0` (full resolution) to rule out downscaling issues.
- Ensure the text is in focus and well-lit. Blurry or dark images produce poor results.

### OCR is slow
- Set `maxSize: 1080` (or even `720` on very old devices).
- On iOS, use `level: "fast"` for continuous scanning.
- Avoid running OCR on full-resolution camera images (3024x4032 = 12MP). Downscale first.

### "No frame available"
- `captureFrame()` was called before the camera had time to produce a frame.
- Add a small delay (200-500ms) after opening the camera before capturing the first frame, or just retry in your loop.

### Webview not transparent (Android)
- Some CSS frameworks set `background: white` on `html` or `body`. Override with `!important`:
  ```css
  html.camera-active, html.camera-active body { background: transparent !important; }
  ```

### Build errors after installation

- **Android "Cannot resolve symbol":** Run `cordova clean` then rebuild. The Gradle cache may be stale.
- **iOS "No such module Vision":** Ensure your deployment target is iOS 13.0+ in Xcode.

---

## License

ISC
