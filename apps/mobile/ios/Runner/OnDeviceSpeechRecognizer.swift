import AVFoundation
import Flutter
import UIKit
import Speech

/// Transcribes a recorded voice message with Apple's on-device recogniser.
///
/// The Volcano recording-recognition contract was never verified against the
/// real service, so a voice message died in transcription with no way to see
/// why. This path has no third-party contract to guess at, needs no key, and
/// keeps the audio on the device.
/// Gapless PCM playback for a live call.
///
/// One engine stays running for the whole call and every arriving chunk is
/// scheduled onto it, so audio plays continuously instead of one clip
/// interrupting the next.
final class CallAudioOutput {
  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private var format: AVAudioFormat?

  func enqueue(_ pcm: Data) {
    let rate: Double = 24000
    if format == nil {
      guard
        let sourceFormat = AVAudioFormat(
          commonFormat: .pcmFormatFloat32,
          sampleRate: rate,
          channels: 1,
          interleaved: false
        )
      else { return }
      format = sourceFormat
      engine.attach(node)
      engine.connect(node, to: engine.mainMixerNode, format: sourceFormat)
      try? engine.start()
      node.play()
    }
    guard let format = format else { return }
    let sampleCount = pcm.count / 2
    guard
      sampleCount > 0,
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(sampleCount)
      )
    else { return }
    buffer.frameLength = AVAudioFrameCount(sampleCount)
    pcm.withUnsafeBytes { raw in
      guard let source = raw.bindMemory(to: Int16.self).baseAddress,
            let target = buffer.floatChannelData?[0]
      else { return }
      for index in 0..<sampleCount {
        // 16-bit little endian to float, the format the engine mixes in.
        target[index] = Float(Int16(littleEndian: source[index])) / 32768.0
      }
    }
    node.scheduleBuffer(buffer, completionHandler: nil)
  }

  /// Drops anything still queued, so an interruption goes quiet at once.
  func stop() {
    node.stop()
    engine.stop()
    format = nil
  }
}

final class OnDeviceSpeechRecognizer: NSObject {
  private let output = CallAudioOutput()

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

  @objc private func proximityChanged() {
    let nearEar = UIDevice.current.proximityState
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: nearEar ? [.allowBluetooth] : [.defaultToSpeaker, .allowBluetooth]
    )
    try? session.overrideOutputAudioPort(nearEar ? .none : .speaker)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setAudioRoute":
      // A call must come out of the loudspeaker unless the user asks for the
      // earpiece; playAndRecord defaults to the receiver, which sounds broken.
      let speaker = (call.arguments as? [String: Any])?["speaker"] as? Bool ?? true
      do {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
          .playAndRecord,
          mode: .voiceChat,
          options: speaker ? [.defaultToSpeaker, .allowBluetooth] : [.allowBluetooth]
        )
        try session.setActive(true)
        try session.overrideOutputAudioPort(speaker ? .speaker : .none)
        result(true)
      } catch {
        result(FlutterError(code: "audio_route_failed", message: nil, details: nil))
      }
    case "playPcm":
      // Continuous playback:每块 PCM 直接排进播放队列，而不是每几百毫秒起一个
      // 新播放器——后者会打断上一段，正是通话断续的原因。
      guard let data = (call.arguments as? [String: Any])?["pcm"] as? FlutterStandardTypedData
      else {
        result(FlutterError(code: "invalid_arguments", message: nil, details: nil))
        return
      }
      output.enqueue(data.data)
      result(true)
    case "stopPcm":
      output.stop()
      result(true)
    case "setProximityRouting":
      // Holding the phone to your ear should switch to the earpiece the way a
      // phone call does, and taking it away should go back to the loudspeaker.
      let on = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
      let device = UIDevice.current
      NotificationCenter.default.removeObserver(
        self,
        name: UIDevice.proximityStateDidChangeNotification,
        object: nil
      )
      device.isProximityMonitoringEnabled = on
      if on {
        NotificationCenter.default.addObserver(
          self,
          selector: #selector(proximityChanged),
          name: UIDevice.proximityStateDidChangeNotification,
          object: nil
        )
      }
      result(true)
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
