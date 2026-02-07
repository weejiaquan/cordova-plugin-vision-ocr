# cordova-plugin-vision-ocr

Cordova plugin for on-device OCR text recognition using Apple's Vision framework (iOS). Returns recognized text with bounding box coordinates for each detected text block.

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

## API

### `VisionOCR.recognizeText(base64String, success, failure, options)`

Performs OCR on a base64-encoded image and returns detected text blocks with their positions.

#### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `base64String` | `string` | Yes | Base64-encoded image data (no `data:` prefix) |
| `success` | `function` | Yes | Success callback receiving the result object |
| `failure` | `function` | Yes | Error callback receiving an error string |
| `options` | `object` | No | Processing options (see below) |

#### Options

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `level` | `string` | `"accurate"` | Recognition level: `"fast"` or `"accurate"`. Fast is significantly quicker on older devices (A8/A9 chips) but less precise. |
| `maxSize` | `number` | `0` (no limit) | Maximum image dimension in pixels. The longest edge is scaled down to this value before processing. Set to `1080` or `1920` to improve speed on slow hardware. `0` disables downscaling. |

#### Result Object

```javascript
{
  "imageWidth": 3024,       // Processed image width in px
  "imageHeight": 4032,      // Processed image height in px
  "blocks": [
    {
      "text": "Hello World",    // Recognized text
      "confidence": 0.98,       // 0.0 - 1.0
      "x": 0.12,               // Normalized left (0-1)
      "y": 0.34,               // Normalized top (0-1)
      "width": 0.45,           // Normalized width (0-1)
      "height": 0.03           // Normalized height (0-1)
    }
  ]
}
```

Coordinates are normalized (0-1) with origin at top-left, matching CSS/web coordinate systems. Multiply by the displayed image dimensions to position overlay elements.

## Usage

### Basic

```javascript
VisionOCR.recognizeText(base64Image,
  function(result) {
    result.blocks.forEach(function(block) {
      console.log(block.text, block.confidence);
    });
  },
  function(error) {
    console.error('OCR failed:', error);
  }
);
```

### With Options

```javascript
// Fast mode with image downscaling — recommended for older devices
VisionOCR.recognizeText(base64Image,
  function(result) {
    console.log('Found ' + result.blocks.length + ' text blocks');
  },
  function(error) {
    console.error(error);
  },
  { level: 'fast', maxSize: 1080 }
);
```

### Drawing Bounding Boxes

```javascript
VisionOCR.recognizeText(base64Image, function(result) {
  var img = document.getElementById('preview');
  var imgW = img.offsetWidth;
  var imgH = img.offsetHeight;

  result.blocks.forEach(function(block) {
    var box = document.createElement('div');
    box.style.position = 'absolute';
    box.style.left   = (block.x * imgW) + 'px';
    box.style.top    = (block.y * imgH) + 'px';
    box.style.width  = (block.width * imgW) + 'px';
    box.style.height = (block.height * imgH) + 'px';
    box.style.border = '2px solid green';
    box.textContent  = block.text;
    img.parentElement.appendChild(box);
  });
}, function(err) { console.error(err); });
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
// Platform routing example
if (window.VisionOCR) {
  VisionOCR.recognizeText(base64, success, failure, opts);
} else if (window.AndroidOCR) {
  AndroidOCR.recognizeText(base64, success, failure, opts);
}
```

The Android companion plugin (`cordova-plugin-android-ocr`) uses Google ML Kit Text Recognition and implements the identical `{ imageWidth, imageHeight, blocks: [{text, confidence, x, y, width, height}] }` response contract.

## License

ISC
