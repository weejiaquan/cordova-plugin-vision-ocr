package com.auphansoftware.cordova.visionocr;

import android.Manifest;
import android.animation.AnimatorSet;
import android.animation.ObjectAnimator;
import android.app.Activity;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.ImageFormat;
import android.graphics.Matrix;
import android.graphics.Rect;
import android.graphics.YuvImage;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.util.Base64;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.OrientationEventListener;
import android.view.ScaleGestureDetector;
import android.view.Surface;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.TextView;

import androidx.camera.core.AspectRatio;
import androidx.camera.core.Camera;
import androidx.camera.core.CameraInfo;
import androidx.camera.core.CameraInfoUnavailableException;
import androidx.camera.core.CameraSelector;
import androidx.camera.core.FocusMeteringAction;
import androidx.camera.core.ImageAnalysis;
import androidx.camera.core.ImageProxy;
import androidx.camera.core.MeteringPoint;
import androidx.camera.core.MeteringPointFactory;
import androidx.camera.core.Preview;
import androidx.camera.core.ZoomState;
import androidx.camera.lifecycle.ProcessCameraProvider;
import androidx.camera.view.PreviewView;
import androidx.core.content.ContextCompat;
import androidx.lifecycle.LifecycleOwner;

import com.google.common.util.concurrent.ListenableFuture;
import com.google.mlkit.vision.common.InputImage;
import com.google.mlkit.vision.text.Text;
import com.google.mlkit.vision.text.TextRecognition;
import com.google.mlkit.vision.text.TextRecognizer;
import com.google.mlkit.vision.text.latin.TextRecognizerOptions;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.PermissionHelper;
import org.apache.cordova.PluginResult;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

public class VisionOCR extends CordovaPlugin {

    private static final String TAG = "VisionOCR";
    private static final int CAMERA_PERMISSION_REQUEST = 100;
    private static final int JPEG_QUALITY = 85;
    private static final int CAMERA_WARMUP_MS = 1500;

    // Camera UI mode
    private enum UIMode { NONE, NATIVE_OVERLAY, BEHIND_WEBVIEW }
    private UIMode uiMode = UIMode.NONE;

    // Shared camera state
    private ProcessCameraProvider cameraProvider;
    private Preview preview;
    private ImageAnalysis imageAnalysis;
    private PreviewView previewView;
    private CameraSelector cameraSelector;
    private Camera camera;
    private volatile Bitmap latestFrame;
    private volatile boolean cameraWarmedUp = false;
    private boolean isFrontCamera = false;
    private boolean isTorchOn = false;
    private float lastZoomRatio = 1.0f;
    private ExecutorService analysisExecutor;
    private OrientationEventListener orientationListener;
    private int currentDisplayRotation = Surface.ROTATION_0;

    // Native overlay state
    private FrameLayout overlayContainer;
    private TextView statusLabel;
    private Button switchCameraBtn;
    private Button torchBtn;
    private View focusRingView;
    private String cameraMode = "";

    // Native overlay callbacks
    private CallbackContext capturePhotoCallback;
    private CallbackContext openCameraCallback;

    // Behind-webview saved state
    private int savedWebViewBgColor = Color.WHITE;

    // Pending permission state
    private CallbackContext pendingCallbackContext;
    private String pendingAction;
    private JSONArray pendingArgs;

    // =====================================================================
    // Action dispatch
    // =====================================================================

    @Override
    public boolean execute(String action, JSONArray args, CallbackContext callbackContext) throws JSONException {
        switch (action) {
            case "capturePhoto":   capturePhoto(callbackContext); return true;
            case "openCamera":     openCamera(callbackContext); return true;
            case "closeCamera":    closeCamera(callbackContext); return true;
            case "updateStatus":   updateStatus(args, callbackContext); return true;
            case "showPreview":    showPreview(callbackContext); return true;
            case "hidePreview":    hidePreview(callbackContext); return true;
            case "switchCamera":   switchCamera(callbackContext); return true;
            case "setTorch":       setTorch(args, callbackContext); return true;
            case "setZoom":        setZoom(args, callbackContext); return true;
            case "focusAtPoint":   focusAtPoint(args, callbackContext); return true;
            case "captureFrame":   captureFrame(callbackContext); return true;
            case "recognizeText":  recognizeText(args, callbackContext); return true;
            default: return false;
        }
    }

    // =====================================================================
    // Permission handling
    // =====================================================================

    private boolean ensureCameraPermission(String action, JSONArray args, CallbackContext callbackContext) {
        if (PermissionHelper.hasPermission(this, Manifest.permission.CAMERA)) {
            return true;
        }
        pendingCallbackContext = callbackContext;
        pendingAction = action;
        pendingArgs = args;
        PermissionHelper.requestPermission(this, CAMERA_PERMISSION_REQUEST, Manifest.permission.CAMERA);
        return false;
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        if (requestCode == CAMERA_PERMISSION_REQUEST) {
            if (grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                try {
                    execute(pendingAction, pendingArgs, pendingCallbackContext);
                } catch (JSONException e) {
                    pendingCallbackContext.error("Permission granted but action failed: " + e.getMessage());
                }
            } else {
                pendingCallbackContext.error("Camera permission denied");
            }
            pendingCallbackContext = null;
            pendingAction = null;
            pendingArgs = null;
        }
    }

    // =====================================================================
    // Camera setup / teardown
    // =====================================================================

    private interface CameraReadyCallback {
        void onReady();
    }

    private void setupCamera(final CameraReadyCallback onReady, final CallbackContext callbackContext) {
        final Activity activity = cordova.getActivity();
        ListenableFuture<ProcessCameraProvider> future = ProcessCameraProvider.getInstance(activity);
        future.addListener(() -> {
            try {
                cameraProvider = future.get();

                // Get current display rotation for correct frame orientation
                int displayRotation = activity.getWindowManager().getDefaultDisplay().getRotation();
                currentDisplayRotation = displayRotation;

                // Use aspect ratio instead of target resolution —
                // setTargetResolution is interpreted relative to targetRotation
                // which breaks when starting in landscape. AspectRatio is
                // rotation-agnostic so CameraX handles orientation internally.
                preview = new Preview.Builder()
                        .setTargetAspectRatio(AspectRatio.RATIO_4_3)
                        .setTargetRotation(displayRotation)
                        .build();

                imageAnalysis = new ImageAnalysis.Builder()
                        .setTargetAspectRatio(AspectRatio.RATIO_4_3)
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
                        .setTargetRotation(displayRotation)
                        .build();

                // Clear stale frame before starting new session
                latestFrame = null;
                cameraWarmedUp = false;

                analysisExecutor = Executors.newSingleThreadExecutor();
                imageAnalysis.setAnalyzer(analysisExecutor, imageProxy -> {
                    // Skip frames until camera has warmed up to avoid stale ISP buffer
                    if (cameraWarmedUp) {
                        latestFrame = imageProxyToBitmap(imageProxy);
                    }
                    imageProxy.close();
                });

                cameraSelector = new CameraSelector.Builder()
                        .requireLensFacing(isFrontCamera ? CameraSelector.LENS_FACING_FRONT : CameraSelector.LENS_FACING_BACK)
                        .build();

                activity.runOnUiThread(() -> {
                    previewView = new PreviewView(activity);
                    previewView.setImplementationMode(PreviewView.ImplementationMode.PERFORMANCE);
                    previewView.setLayoutParams(new FrameLayout.LayoutParams(
                            FrameLayout.LayoutParams.MATCH_PARENT,
                            FrameLayout.LayoutParams.MATCH_PARENT));

                    cameraProvider.unbindAll();
                    camera = cameraProvider.bindToLifecycle(
                            (LifecycleOwner) activity,
                            cameraSelector,
                            preview,
                            imageAnalysis
                    );
                    preview.setSurfaceProvider(previewView.getSurfaceProvider());

                    camera.getCameraControl().setLinearZoom(0f);
                    lastZoomRatio = 1.0f;

                    // Allow frames after warm-up to flush stale hardware buffers
                    previewView.postDelayed(() -> cameraWarmedUp = true, CAMERA_WARMUP_MS);

                    // Listen for device orientation changes and update targetRotation
                    // so CameraX delivers correctly-rotated frames after rotation
                    orientationListener = new OrientationEventListener(activity) {
                        @Override
                        public void onOrientationChanged(int orientation) {
                            if (orientation == OrientationEventListener.ORIENTATION_UNKNOWN) return;
                            int rotation = activity.getWindowManager().getDefaultDisplay().getRotation();
                            if (rotation != currentDisplayRotation) {
                                currentDisplayRotation = rotation;
                                if (imageAnalysis != null) imageAnalysis.setTargetRotation(rotation);
                                if (preview != null) preview.setTargetRotation(rotation);
                            }
                        }
                    };
                    orientationListener.enable();

                    if (onReady != null) onReady.onReady();
                });
            } catch (Exception e) {
                callbackContext.error("Camera not available");
            }
        }, ContextCompat.getMainExecutor(activity));
    }

    private void teardownCamera() {
        if (isTorchOn && camera != null) {
            camera.getCameraControl().enableTorch(false);
        }

        cordova.getActivity().runOnUiThread(() -> {
            if (cameraProvider != null) {
                cameraProvider.unbindAll();
            }

            if (uiMode == UIMode.NATIVE_OVERLAY) {
                if (overlayContainer != null) {
                    ViewGroup parent = (ViewGroup) overlayContainer.getParent();
                    if (parent != null) parent.removeView(overlayContainer);
                    overlayContainer = null;
                }
                statusLabel = null;
                switchCameraBtn = null;
                torchBtn = null;
                if (focusRingView != null) {
                    ViewGroup parent = (ViewGroup) focusRingView.getParent();
                    if (parent != null) parent.removeView(focusRingView);
                    focusRingView = null;
                }
            } else if (uiMode == UIMode.BEHIND_WEBVIEW) {
                webView.getView().setBackgroundColor(savedWebViewBgColor);
                if (previewView != null) {
                    ViewGroup parent = (ViewGroup) previewView.getParent();
                    if (parent != null) parent.removeView(previewView);
                }
            }

            previewView = null;
        });

        if (orientationListener != null) {
            orientationListener.disable();
            orientationListener = null;
        }

        if (analysisExecutor != null) {
            analysisExecutor.shutdown();
            analysisExecutor = null;
        }

        camera = null;
        latestFrame = null;
        cameraWarmedUp = false;
        isTorchOn = false;
        lastZoomRatio = 1.0f;
        isFrontCamera = false;
        cameraMode = "";
        uiMode = UIMode.NONE;
    }

    private void rebindCamera() {
        cordova.getActivity().runOnUiThread(() -> {
            if (cameraProvider == null) return;
            cameraProvider.unbindAll();
            cameraSelector = new CameraSelector.Builder()
                    .requireLensFacing(isFrontCamera ? CameraSelector.LENS_FACING_FRONT : CameraSelector.LENS_FACING_BACK)
                    .build();
            camera = cameraProvider.bindToLifecycle(
                    (LifecycleOwner) cordova.getActivity(),
                    cameraSelector,
                    preview,
                    imageAnalysis
            );
            preview.setSurfaceProvider(previewView.getSurfaceProvider());

            camera.getCameraControl().setLinearZoom(0f);
            lastZoomRatio = 1.0f;
        });
    }

    // =====================================================================
    // Image helpers
    // =====================================================================

    private Bitmap imageProxyToBitmap(ImageProxy imageProxy) {
        try {
            ImageProxy.PlaneProxy[] planes = imageProxy.getPlanes();
            ByteBuffer yBuffer = planes[0].getBuffer();
            ByteBuffer uBuffer = planes[1].getBuffer();
            ByteBuffer vBuffer = planes[2].getBuffer();

            int ySize = yBuffer.remaining();
            int uSize = uBuffer.remaining();
            int vSize = vBuffer.remaining();

            byte[] nv21 = new byte[ySize + uSize + vSize];
            yBuffer.get(nv21, 0, ySize);
            vBuffer.get(nv21, ySize, vSize);
            uBuffer.get(nv21, ySize + vSize, uSize);

            YuvImage yuvImage = new YuvImage(nv21, ImageFormat.NV21,
                    imageProxy.getWidth(), imageProxy.getHeight(), null);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            yuvImage.compressToJpeg(new Rect(0, 0, imageProxy.getWidth(), imageProxy.getHeight()), JPEG_QUALITY, out);

            byte[] jpegBytes = out.toByteArray();
            Bitmap bitmap = BitmapFactory.decodeByteArray(jpegBytes, 0, jpegBytes.length);

            int rotation = imageProxy.getImageInfo().getRotationDegrees();
            if (rotation != 0) {
                Matrix matrix = new Matrix();
                matrix.postRotate(rotation);
                bitmap = Bitmap.createBitmap(bitmap, 0, 0, bitmap.getWidth(), bitmap.getHeight(), matrix, true);
            }

            return bitmap;
        } catch (Exception e) {
            return null;
        }
    }

    private String bitmapToBase64(Bitmap bitmap) {
        if (bitmap == null) return null;
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, baos);
        return Base64.encodeToString(baos.toByteArray(), Base64.NO_WRAP);
    }

    private Bitmap downscaleBitmap(Bitmap bitmap, int maxSize) {
        int longestEdge = Math.max(bitmap.getWidth(), bitmap.getHeight());
        if (longestEdge <= maxSize) return bitmap;

        float scale = (float) maxSize / longestEdge;
        int newWidth = Math.round(bitmap.getWidth() * scale);
        int newHeight = Math.round(bitmap.getHeight() * scale);
        return Bitmap.createScaledBitmap(bitmap, newWidth, newHeight, true);
    }

    // =====================================================================
    // Capabilities helper (matches iOS return structure exactly)
    // =====================================================================

    private JSONObject getCapabilities() throws JSONException {
        JSONObject caps = new JSONObject();
        boolean hasTorch = false;
        boolean hasMultiple = false;
        float minZoom = 1.0f;
        float maxZoom = 1.0f;

        if (camera != null) {
            CameraInfo cameraInfo = camera.getCameraInfo();
            hasTorch = cameraInfo.hasFlashUnit();
            ZoomState zoomState = cameraInfo.getZoomState().getValue();
            if (zoomState != null) {
                minZoom = zoomState.getMinZoomRatio();
                maxZoom = Math.min(zoomState.getMaxZoomRatio(), 10.0f);
            }
        }

        try {
            if (cameraProvider != null) {
                hasMultiple = cameraProvider.hasCamera(CameraSelector.DEFAULT_FRONT_CAMERA)
                        && cameraProvider.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA);
            }
        } catch (CameraInfoUnavailableException e) { /* leave false */ }

        caps.put("hasTorch", hasTorch);
        caps.put("hasMultipleCameras", hasMultiple);
        caps.put("position", isFrontCamera ? "front" : "back");
        caps.put("minZoom", (double) minZoom);
        caps.put("maxZoom", (double) maxZoom);
        return caps;
    }

    // =====================================================================
    // MODE 1: Native Overlay
    // =====================================================================

    private void capturePhoto(final CallbackContext callbackContext) {
        if (!ensureCameraPermission("capturePhoto", new JSONArray(), callbackContext)) return;

        capturePhotoCallback = callbackContext;
        cameraMode = "manual";
        uiMode = UIMode.NATIVE_OVERLAY;

        setupCamera(() -> buildNativeOverlay("manual"), callbackContext);
    }

    private void openCamera(final CallbackContext callbackContext) {
        if (!ensureCameraPermission("openCamera", new JSONArray(), callbackContext)) return;

        openCameraCallback = callbackContext;
        cameraMode = "auto";
        uiMode = UIMode.NATIVE_OVERLAY;

        setupCamera(() -> {
            buildNativeOverlay("auto");
            PluginResult result = new PluginResult(PluginResult.Status.OK, "Camera opened");
            result.setKeepCallback(true);
            callbackContext.sendPluginResult(result);
        }, callbackContext);
    }

    private void closeCamera(final CallbackContext callbackContext) {
        teardownCamera();
        openCameraCallback = null;
        capturePhotoCallback = null;
        callbackContext.success("Camera closed");
    }

    private void updateStatus(JSONArray args, CallbackContext callbackContext) throws JSONException {
        final String text = args.optString(0, "");
        cordova.getActivity().runOnUiThread(() -> {
            if (statusLabel != null) {
                statusLabel.setText(text);
            }
        });
        callbackContext.success();
    }

    // =====================================================================
    // Native overlay UI construction
    // =====================================================================

    private int dpToPx(int dp) {
        return Math.round(TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP, dp,
                cordova.getActivity().getResources().getDisplayMetrics()));
    }

    private void buildNativeOverlay(String mode) {
        Activity activity = cordova.getActivity();
        activity.runOnUiThread(() -> {
            ViewGroup parentView = (ViewGroup) webView.getView().getParent();

            overlayContainer = new FrameLayout(activity);
            overlayContainer.setLayoutParams(new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT));
            overlayContainer.setBackgroundColor(Color.BLACK);

            // Add PreviewView
            overlayContainer.addView(previewView);

            // Bottom bar
            int barHeight = dpToPx(80);
            FrameLayout bar = new FrameLayout(activity);
            FrameLayout.LayoutParams barParams = new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT, barHeight);
            barParams.gravity = Gravity.BOTTOM;
            bar.setLayoutParams(barParams);
            bar.setBackgroundColor(Color.argb(179, 0, 0, 0)); // 70% black

            if ("manual".equals(mode)) {
                // Capture button
                Button captureBtn = new Button(activity);
                captureBtn.setText("Capture");
                captureBtn.setTextColor(Color.WHITE);
                captureBtn.setTextSize(18);
                captureBtn.setTypeface(null, Typeface.BOLD);
                captureBtn.setAllCaps(false);
                GradientDrawable capBg = new GradientDrawable();
                capBg.setColor(Color.rgb(74, 143, 217));
                capBg.setCornerRadius(dpToPx(4));
                captureBtn.setBackground(capBg);
                captureBtn.setPadding(0, 0, 0, 0);
                captureBtn.setMinHeight(0);
                captureBtn.setMinimumHeight(0);
                FrameLayout.LayoutParams capParams = new FrameLayout.LayoutParams(dpToPx(150), dpToPx(50));
                capParams.gravity = Gravity.CENTER;
                capParams.rightMargin = dpToPx(80);
                captureBtn.setLayoutParams(capParams);
                captureBtn.setOnClickListener(v -> onCaptureTapped());
                bar.addView(captureBtn);

                // Cancel button
                Button cancelBtn = new Button(activity);
                cancelBtn.setText("Cancel");
                cancelBtn.setTextColor(Color.WHITE);
                cancelBtn.setTextSize(18);
                cancelBtn.setTypeface(null, Typeface.BOLD);
                cancelBtn.setAllCaps(false);
                GradientDrawable canBg = new GradientDrawable();
                canBg.setColor(Color.GRAY);
                canBg.setCornerRadius(dpToPx(4));
                cancelBtn.setBackground(canBg);
                cancelBtn.setPadding(0, 0, 0, 0);
                cancelBtn.setMinHeight(0);
                cancelBtn.setMinimumHeight(0);
                FrameLayout.LayoutParams canParams = new FrameLayout.LayoutParams(dpToPx(150), dpToPx(50));
                canParams.gravity = Gravity.CENTER;
                canParams.leftMargin = dpToPx(80);
                cancelBtn.setLayoutParams(canParams);
                cancelBtn.setOnClickListener(v -> onCancelTapped());
                bar.addView(cancelBtn);
            } else {
                // Status label
                statusLabel = new TextView(activity);
                statusLabel.setText("Scanning...");
                statusLabel.setTextColor(Color.GREEN);
                statusLabel.setTextSize(16);
                FrameLayout.LayoutParams labelParams = new FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT);
                labelParams.gravity = Gravity.CENTER_VERTICAL | Gravity.START;
                labelParams.leftMargin = dpToPx(20);
                statusLabel.setLayoutParams(labelParams);
                bar.addView(statusLabel);

                // Cancel button
                Button cancelBtn = new Button(activity);
                cancelBtn.setText("Cancel");
                cancelBtn.setTextColor(Color.WHITE);
                cancelBtn.setTextSize(18);
                cancelBtn.setTypeface(null, Typeface.BOLD);
                cancelBtn.setAllCaps(false);
                GradientDrawable canBg = new GradientDrawable();
                canBg.setColor(Color.GRAY);
                canBg.setCornerRadius(dpToPx(4));
                cancelBtn.setBackground(canBg);
                cancelBtn.setPadding(0, 0, 0, 0);
                cancelBtn.setMinHeight(0);
                cancelBtn.setMinimumHeight(0);
                FrameLayout.LayoutParams canParams = new FrameLayout.LayoutParams(dpToPx(140), dpToPx(50));
                canParams.gravity = Gravity.CENTER_VERTICAL | Gravity.END;
                canParams.rightMargin = dpToPx(16);
                cancelBtn.setLayoutParams(canParams);
                cancelBtn.setOnClickListener(v -> onCancelTapped());
                bar.addView(cancelBtn);
            }

            overlayContainer.addView(bar);

            // --- Top-right floating controls ---
            int btnSize = dpToPx(44);
            int margin = dpToPx(16);
            int spacing = dpToPx(12);
            int topOffset = dpToPx(12);
            int currentY = topOffset;

            // Switch camera button
            boolean hasMultiple = false;
            try {
                if (cameraProvider != null) {
                    hasMultiple = cameraProvider.hasCamera(CameraSelector.DEFAULT_FRONT_CAMERA)
                            && cameraProvider.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA);
                }
            } catch (CameraInfoUnavailableException e) { /* ignore */ }

            if (hasMultiple) {
                switchCameraBtn = new Button(activity);
                switchCameraBtn.setText("\u21BB"); // ↻
                switchCameraBtn.setTextColor(Color.WHITE);
                switchCameraBtn.setTextSize(20);
                switchCameraBtn.setPadding(0, 0, 0, 0);
                switchCameraBtn.setAllCaps(false);

                GradientDrawable switchBg = new GradientDrawable();
                switchBg.setShape(GradientDrawable.OVAL);
                switchBg.setColor(Color.argb(179, 51, 51, 51));
                switchCameraBtn.setBackground(switchBg);

                FrameLayout.LayoutParams switchParams = new FrameLayout.LayoutParams(btnSize, btnSize);
                switchParams.gravity = Gravity.TOP | Gravity.END;
                switchParams.rightMargin = margin;
                switchParams.topMargin = currentY;
                switchCameraBtn.setLayoutParams(switchParams);
                switchCameraBtn.setOnClickListener(v -> onNativeSwitchCameraTapped());
                overlayContainer.addView(switchCameraBtn);
                currentY += btnSize + spacing;
            }

            // Torch button
            if (camera != null && camera.getCameraInfo().hasFlashUnit()) {
                torchBtn = new Button(activity);
                torchBtn.setText("\u26A1"); // ⚡
                torchBtn.setTextColor(Color.WHITE);
                torchBtn.setTextSize(18);
                torchBtn.setPadding(0, 0, 0, 0);
                torchBtn.setAllCaps(false);

                GradientDrawable torchBg = new GradientDrawable();
                torchBg.setShape(GradientDrawable.OVAL);
                torchBg.setColor(Color.argb(179, 51, 51, 51));
                torchBtn.setBackground(torchBg);

                FrameLayout.LayoutParams torchParams = new FrameLayout.LayoutParams(btnSize, btnSize);
                torchParams.gravity = Gravity.TOP | Gravity.END;
                torchParams.rightMargin = margin;
                torchParams.topMargin = currentY;
                torchBtn.setLayoutParams(torchParams);
                torchBtn.setOnClickListener(v -> onNativeTorchTapped());
                overlayContainer.addView(torchBtn);
            }

            // Gesture handling
            final ScaleGestureDetector scaleDetector = new ScaleGestureDetector(activity,
                    new ScaleGestureDetector.SimpleOnScaleGestureListener() {
                        @Override
                        public boolean onScaleBegin(ScaleGestureDetector detector) {
                            if (camera != null) {
                                ZoomState zoomState = camera.getCameraInfo().getZoomState().getValue();
                                if (zoomState != null) {
                                    lastZoomRatio = zoomState.getZoomRatio();
                                }
                            }
                            return true;
                        }

                        @Override
                        public boolean onScale(ScaleGestureDetector detector) {
                            if (camera == null) return true;
                            ZoomState zoomState = camera.getCameraInfo().getZoomState().getValue();
                            if (zoomState == null) return true;

                            float newRatio = lastZoomRatio * detector.getScaleFactor();
                            float minZoom = zoomState.getMinZoomRatio();
                            float maxZoom = Math.min(zoomState.getMaxZoomRatio(), 10.0f);
                            newRatio = Math.max(minZoom, Math.min(newRatio, maxZoom));
                            camera.getCameraControl().setZoomRatio(newRatio);
                            return true;
                        }

                        @Override
                        public void onScaleEnd(ScaleGestureDetector detector) {
                            if (camera != null) {
                                ZoomState zoomState = camera.getCameraInfo().getZoomState().getValue();
                                if (zoomState != null) {
                                    lastZoomRatio = zoomState.getZoomRatio();
                                }
                            }
                        }
                    });

            overlayContainer.setOnTouchListener((v, event) -> {
                scaleDetector.onTouchEvent(event);

                // Tap-to-focus (only on single tap, not during scale gesture)
                if (event.getAction() == MotionEvent.ACTION_UP && !scaleDetector.isInProgress()) {
                    float tapX = event.getX();
                    float tapY = event.getY();

                    // Don't focus if tap was on a button
                    if (isTapOnButton(tapX, tapY)) return true;

                    focusAtViewPoint(tapX, tapY);
                    showFocusRing(tapX, tapY);
                }
                return true;
            });

            parentView.addView(overlayContainer);
        });
    }

    private boolean isTapOnButton(float x, float y) {
        View[] buttons = { switchCameraBtn, torchBtn };
        for (View btn : buttons) {
            if (btn != null && btn.getVisibility() == View.VISIBLE) {
                int[] loc = new int[2];
                btn.getLocationInWindow(loc);
                if (x >= loc[0] && x <= loc[0] + btn.getWidth()
                        && y >= loc[1] && y <= loc[1] + btn.getHeight()) {
                    return true;
                }
            }
        }
        return false;
    }

    // =====================================================================
    // Native overlay button handlers
    // =====================================================================

    private void onCaptureTapped() {
        // Small delay for frame stabilization, matching iOS 150ms
        cordova.getActivity().getWindow().getDecorView().postDelayed(() -> {
            Bitmap frame = latestFrame;
            if (frame == null || capturePhotoCallback == null) return;

            final CallbackContext callback = capturePhotoCallback;
            teardownCamera();

            cordova.getThreadPool().execute(() -> {
                String base64 = bitmapToBase64(frame);
                if (base64 != null) {
                    callback.success(base64);
                } else {
                    callback.error("Failed to encode image");
                }
                capturePhotoCallback = null;
            });
        }, 150);
    }

    private void onCancelTapped() {
        if ("manual".equals(cameraMode)) {
            CallbackContext callback = capturePhotoCallback;
            teardownCamera();
            if (callback != null) {
                callback.error("User cancelled");
            }
            capturePhotoCallback = null;
        } else {
            CallbackContext callback = openCameraCallback;
            teardownCamera();
            if (callback != null) {
                callback.error("User cancelled");
            }
            openCameraCallback = null;
        }
    }

    private void onNativeSwitchCameraTapped() {
        switchCameraInternal();
        cordova.getActivity().runOnUiThread(() -> {
            if (torchBtn != null && camera != null) {
                torchBtn.setVisibility(camera.getCameraInfo().hasFlashUnit() ? View.VISIBLE : View.GONE);
            }
        });
    }

    private void onNativeTorchTapped() {
        setTorchInternal(!isTorchOn);
        updateNativeTorchIcon();
    }

    private void updateNativeTorchIcon() {
        cordova.getActivity().runOnUiThread(() -> {
            if (torchBtn == null) return;
            torchBtn.setTextColor(isTorchOn ? Color.YELLOW : Color.WHITE);
            GradientDrawable bg = new GradientDrawable();
            bg.setShape(GradientDrawable.OVAL);
            if (isTorchOn) {
                bg.setColor(Color.argb(204, 230, 168, 0)); // yellow-orange
            } else {
                bg.setColor(Color.argb(179, 51, 51, 51)); // dark gray
            }
            torchBtn.setBackground(bg);
        });
    }

    private void showFocusRing(float x, float y) {
        Activity activity = cordova.getActivity();
        if (overlayContainer == null) return;

        activity.runOnUiThread(() -> {
            if (focusRingView != null) {
                ViewGroup parent = (ViewGroup) focusRingView.getParent();
                if (parent != null) parent.removeView(focusRingView);
            }

            int size = dpToPx(80);
            View ring = new View(activity);
            GradientDrawable ringDrawable = new GradientDrawable();
            ringDrawable.setShape(GradientDrawable.OVAL);
            ringDrawable.setStroke(dpToPx(2), Color.WHITE);
            ringDrawable.setColor(Color.TRANSPARENT);
            ring.setBackground(ringDrawable);

            FrameLayout.LayoutParams params = new FrameLayout.LayoutParams(size, size);
            params.leftMargin = (int) (x - size / 2);
            params.topMargin = (int) (y - size / 2);
            ring.setLayoutParams(params);
            overlayContainer.addView(ring);
            focusRingView = ring;

            // Animate: scale 1.0 → 0.7, then fade out
            ObjectAnimator scaleX = ObjectAnimator.ofFloat(ring, "scaleX", 1.0f, 0.7f);
            ObjectAnimator scaleY = ObjectAnimator.ofFloat(ring, "scaleY", 1.0f, 0.7f);
            scaleX.setDuration(300);
            scaleY.setDuration(300);

            ObjectAnimator fade = ObjectAnimator.ofFloat(ring, "alpha", 1.0f, 0.0f);
            fade.setStartDelay(800); // 300ms scale + 500ms hold
            fade.setDuration(400);

            AnimatorSet animSet = new AnimatorSet();
            animSet.playTogether(scaleX, scaleY, fade);
            animSet.start();

            // Remove after animation
            ring.postDelayed(() -> {
                ViewGroup parent = (ViewGroup) ring.getParent();
                if (parent != null) parent.removeView(ring);
                if (focusRingView == ring) focusRingView = null;
            }, 1500);
        });
    }

    // =====================================================================
    // MODE 2: Behind-Webview
    // =====================================================================

    private void showPreview(final CallbackContext callbackContext) {
        if (!ensureCameraPermission("showPreview", new JSONArray(), callbackContext)) return;

        uiMode = UIMode.BEHIND_WEBVIEW;

        setupCamera(() -> {
            Activity activity = cordova.getActivity();
            activity.runOnUiThread(() -> {
                View webViewView = webView.getView();
                ViewGroup parentView = (ViewGroup) webViewView.getParent();

                savedWebViewBgColor = Color.WHITE;

                // Add PreviewView BEHIND the webview, then make webview transparent
                parentView.addView(previewView, 0);
                webViewView.bringToFront();
                webViewView.setBackgroundColor(Color.TRANSPARENT);

                try {
                    JSONObject caps = getCapabilities();
                    callbackContext.success(caps);
                } catch (JSONException e) {
                    callbackContext.error("Failed to get capabilities");
                }
            });
        }, callbackContext);
    }

    private void hidePreview(final CallbackContext callbackContext) {
        teardownCamera();
        callbackContext.success();
    }

    // =====================================================================
    // Shared camera controls
    // =====================================================================

    private void switchCameraInternal() {
        if (isTorchOn) setTorchInternal(false);
        isFrontCamera = !isFrontCamera;
        rebindCamera();
    }

    private void setTorchInternal(boolean on) {
        if (camera != null && camera.getCameraInfo().hasFlashUnit()) {
            camera.getCameraControl().enableTorch(on);
            isTorchOn = on;
        }
    }

    private void focusAtViewPoint(float viewX, float viewY) {
        if (camera == null || previewView == null) return;
        MeteringPointFactory factory = previewView.getMeteringPointFactory();
        MeteringPoint point = factory.createPoint(viewX, viewY);
        FocusMeteringAction action = new FocusMeteringAction.Builder(point,
                FocusMeteringAction.FLAG_AF | FocusMeteringAction.FLAG_AE)
                .setAutoCancelDuration(3, TimeUnit.SECONDS)
                .build();
        camera.getCameraControl().startFocusAndMetering(action);
    }

    // Shared control plugin methods

    private void switchCamera(final CallbackContext callbackContext) {
        if (camera == null) {
            callbackContext.error("No active session");
            return;
        }
        switchCameraInternal();

        // Wait for rebind to complete on UI thread before returning capabilities
        cordova.getActivity().runOnUiThread(() -> {
            // Post again to ensure rebindCamera's runOnUiThread has completed
            cordova.getActivity().getWindow().getDecorView().post(() -> {
                try {
                    callbackContext.success(getCapabilities());
                } catch (JSONException e) {
                    callbackContext.error("Failed to get capabilities");
                }
            });
        });
    }

    private void setTorch(JSONArray args, CallbackContext callbackContext) throws JSONException {
        boolean on = args.optBoolean(0, false);
        setTorchInternal(on);
        PluginResult result = new PluginResult(PluginResult.Status.OK, isTorchOn);
        callbackContext.sendPluginResult(result);
    }

    private void setZoom(JSONArray args, CallbackContext callbackContext) throws JSONException {
        float factor = (float) args.optDouble(0, 1.0);
        if (camera == null) {
            callbackContext.error("No active camera");
            return;
        }

        ZoomState zoomState = camera.getCameraInfo().getZoomState().getValue();
        if (zoomState == null) {
            callbackContext.error("No active camera");
            return;
        }

        float minZoom = zoomState.getMinZoomRatio();
        float maxZoom = Math.min(zoomState.getMaxZoomRatio(), 10.0f);
        float clamped = Math.max(minZoom, Math.min(factor, maxZoom));

        camera.getCameraControl().setZoomRatio(clamped);
        lastZoomRatio = clamped;

        JSONObject result = new JSONObject();
        result.put("zoom", (double) clamped);
        result.put("minZoom", (double) minZoom);
        result.put("maxZoom", (double) maxZoom);
        callbackContext.success(result);
    }

    private void focusAtPoint(JSONArray args, CallbackContext callbackContext) throws JSONException {
        float x = (float) args.optDouble(0, 0.5);
        float y = (float) args.optDouble(1, 0.5);

        boolean focusSupported = false;
        if (camera != null && previewView != null) {
            // Convert normalized (0-1) coords to view coordinates
            float viewX = x * previewView.getWidth();
            float viewY = y * previewView.getHeight();
            focusAtViewPoint(viewX, viewY);
            focusSupported = true;
        }

        PluginResult result = new PluginResult(PluginResult.Status.OK, focusSupported);
        callbackContext.sendPluginResult(result);
    }

    // =====================================================================
    // Frame capture
    // =====================================================================

    private void captureFrame(final CallbackContext callbackContext) {
        cordova.getThreadPool().execute(() -> {
            Bitmap frame = latestFrame;
            if (frame == null) {
                callbackContext.error("No frame available");
                return;
            }
            String base64 = bitmapToBase64(frame);
            if (base64 != null) {
                callbackContext.success(base64);
            } else {
                callbackContext.error("Failed to encode frame");
            }
        });
    }

    // =====================================================================
    // OCR — recognizeText
    // =====================================================================

    private void recognizeText(JSONArray args, final CallbackContext callbackContext) throws JSONException {
        String base64String = args.optString(0, "");
        JSONObject options = args.optJSONObject(1);
        if (options == null) options = new JSONObject();

        final int maxSize = options.optInt("maxSize", 0);
        final double minConfidence = options.optDouble("minConfidence", 0.5);

        if (base64String.isEmpty()) {
            callbackContext.error("No image data provided");
            return;
        }

        final byte[] imageBytes;
        try {
            imageBytes = Base64.decode(base64String, Base64.DEFAULT);
        } catch (IllegalArgumentException e) {
            callbackContext.error("Invalid image data");
            return;
        }

        cordova.getThreadPool().execute(() -> {
            Bitmap bitmap = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.length);
            if (bitmap == null) {
                callbackContext.error("Invalid image data");
                return;
            }

            if (maxSize > 0) {
                bitmap = downscaleBitmap(bitmap, maxSize);
            }

            final int imageWidth = bitmap.getWidth();
            final int imageHeight = bitmap.getHeight();

            InputImage inputImage = InputImage.fromBitmap(bitmap, 0);
            TextRecognizer recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS);

            recognizer.process(inputImage)
                    .addOnSuccessListener(text -> {
                        try {
                            JSONArray blocks = new JSONArray();
                            for (Text.TextBlock block : text.getTextBlocks()) {
                                for (Text.Line line : block.getLines()) {
                                    Float conf = line.getConfidence();
                                    if (conf != null && conf < minConfidence) continue;
                                    JSONObject lineObj = new JSONObject();
                                    lineObj.put("text", line.getText());
                                    lineObj.put("confidence",
                                            (double) line.getConfidence());

                                    Rect boundingBox = line.getBoundingBox();
                                    if (boundingBox != null) {
                                        lineObj.put("x", (double) boundingBox.left / imageWidth);
                                        lineObj.put("y", (double) boundingBox.top / imageHeight);
                                        lineObj.put("width", (double) boundingBox.width() / imageWidth);
                                        lineObj.put("height", (double) boundingBox.height() / imageHeight);
                                    } else {
                                        lineObj.put("x", 0);
                                        lineObj.put("y", 0);
                                        lineObj.put("width", 0);
                                        lineObj.put("height", 0);
                                    }

                                    blocks.put(lineObj);
                                }
                            }

                            JSONObject result = new JSONObject();
                            result.put("imageWidth", imageWidth);
                            result.put("imageHeight", imageHeight);
                            result.put("blocks", blocks);
                            callbackContext.success(result);
                        } catch (JSONException e) {
                            callbackContext.error("Failed to build result: " + e.getMessage());
                        }
                    })
                    .addOnFailureListener(e -> {
                        callbackContext.error(e.getLocalizedMessage());
                    });
        });
    }

    // =====================================================================
    // Lifecycle
    // =====================================================================

    @Override
    public void onDestroy() {
        teardownCamera();
    }
}
