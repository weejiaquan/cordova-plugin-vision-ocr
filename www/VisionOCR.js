var exec = require('cordova/exec');

var VisionOCR = function () {};

// options: { level: "fast"|"accurate", maxSize: 1920 }
VisionOCR.recognizeText = function (base64String, callback, failure, options) {
    return exec(callback, failure, "VisionOCR", "recognizeText", [base64String, options || {}]);
};

module.exports = VisionOCR;
