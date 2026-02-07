//
//  VisionOCR.swift
//

import Foundation
import UIKit
import Vision

@objc(VisionOCR) class VisionOCR : CDVPlugin {

    private func normalizeOrientation(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up { return image }
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let normalized = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return normalized
    }

    // Downscale image so longest edge <= maxSize. Returns original if already small enough.
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

    @objc(recognizeText:)
    func recognizeText(_ command: CDVInvokedUrlCommand) {
        let base64String = command.arguments[0] as? String ?? ""
        let options = command.arguments.count > 1 ? command.arguments[1] as? [String: Any] ?? [:] : [:]

        // Options: "level" = "fast" | "accurate" (default), "maxSize" = max longest edge in px (default 0 = no limit)
        let levelStr = options["level"] as? String ?? "accurate"
        let maxSize = options["maxSize"] as? CGFloat ?? 0

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
                    if let topCandidate = observation.topCandidates(1).first {
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
