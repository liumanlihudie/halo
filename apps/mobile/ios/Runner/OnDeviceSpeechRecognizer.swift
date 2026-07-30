import Flutter
import Speech

/// Transcribes a recorded voice message with Apple's on-device recogniser.
///
/// The Volcano recording-recognition contract was never verified against the
/// real service, so a voice message died in transcription with no way to see
/// why. This path has no third-party contract to guess at, needs no key, and
/// keeps the audio on the device.
final class OnDeviceSpeechRecognizer: NSObject {
  static let channelName = "halo.speech/on_device"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let instance = OnDeviceSpeechRecognizer()
    channel.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "transcribe":
      guard let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String
      else {
        result(FlutterError(code: "invalid_arguments", message: nil, details: nil))
        return
      }
      let locale = (arguments["locale"] as? String) ?? "zh-CN"
      transcribe(path: path, locale: locale, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func transcribe(
    path: String,
    locale: String,
    result: @escaping FlutterResult
  ) {
    SFSpeechRecognizer.requestAuthorization { status in
      DispatchQueue.main.async {
        guard status == .authorized else {
          result(
            FlutterError(code: "not_authorized", message: nil, details: nil)
          )
          return
        }
        guard
          let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
          recognizer.isAvailable
        else {
          result(
            FlutterError(code: "unavailable", message: nil, details: nil)
          )
          return
        }
        let request = SFSpeechURLRecognitionRequest(
          url: URL(fileURLWithPath: path)
        )
        // Keeping recognition on the device is the point: the recording never
        // leaves the phone, and it works without a network.
        if recognizer.supportsOnDeviceRecognition {
          request.requiresOnDeviceRecognition = true
        }
        request.shouldReportPartialResults = false
        var settled = false
        recognizer.recognitionTask(with: request) { response, error in
          guard !settled else { return }
          if let error = error {
            settled = true
            // The message is a category, never the underlying description:
            // upstream error text must not reach the UI.
            result(
              FlutterError(
                code: "recognition_failed",
                message: (error as NSError).domain,
                details: nil
              )
            )
            return
          }
          guard let response = response, response.isFinal else { return }
          settled = true
          result(response.bestTranscription.formattedString)
        }
      }
    }
  }
}
