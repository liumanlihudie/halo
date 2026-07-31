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
  private let ringback = AVAudioPlayerNode()
  private var capture: ((Data) -> Void)?
  private var prepared = false
  private var ringbackFormat: AVAudioFormat?
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
      prepare()
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

  /// Captures the microphone on the same engine that plays the call.
  ///
  /// Two components cannot own the input hardware at once: with playback
  /// running voice processing here and a separate recorder elsewhere, capture
  /// died the moment the expert first spoke and the call went one-sided.
  func startCapture(_ onAudio: @escaping (Data) -> Void) {
    stopCapture()
    // The session must be live before the input node is asked anything: an
    // inactive session reports a 0 Hz format, and installing a tap with that
    // raises rather than fails.
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .playAndRecord,
        mode: .voiceChat,
        options: [.defaultToSpeaker, .allowBluetooth]
      )
      try session.setActive(true)
    } catch {
      return
    }
    prepare()
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      return
    }
    guard
      let target = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
      ),
      let converter = AVAudioConverter(from: inputFormat, to: target)
    else { return }
    capture = onAudio
    input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) {
      [weak self] buffer, _ in
      guard let self, let sink = self.capture else { return }
      let ratio = target.sampleRate / inputFormat.sampleRate
      let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
      guard
        let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
      else { return }
      var supplied = false
      var error: NSError?
      converter.convert(to: converted, error: &error) { _, status in
        if supplied {
          status.pointee = .noDataNow
          return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
      }
      guard error == nil, converted.frameLength > 0,
            let channel = converted.int16ChannelData
      else { return }
      let bytes = Int(converted.frameLength) * 2
      sink(Data(bytes: channel[0], count: bytes))
    }
    if !engine.isRunning { try? engine.start() }
  }

  func stopCapture() {
    if capture != nil {
      engine.inputNode.removeTap(onBus: 0)
      capture = nil
    }
  }

  /// Starts the engine with echo cancellation, shared by capture and playback.
  private func prepare() {
    guard !prepared else { return }
    prepared = true
    // Apple's own echo cancellation, the same voice processing FaceTime uses.
    try? engine.inputNode.setVoiceProcessingEnabled(true)
    try? engine.outputNode.setVoiceProcessingEnabled(true)
  }

  /// The classic two-tone ringback, repeating until the call connects.
  func startRingback() {
    stopRingback()
    let rate: Double = 24000
    guard
      let toneFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: rate,
        channels: 1,
        interleaved: false
      )
    else { return }
    ringbackFormat = toneFormat
    engine.attach(ringback)
    engine.connect(ringback, to: engine.mainMixerNode, format: toneFormat)
    if !engine.isRunning { try? engine.start() }
    ringback.play()
    scheduleRingback()
  }

  private func scheduleRingback() {
    guard let toneFormat = ringbackFormat, ringback.isPlaying else { return }
    let rate = toneFormat.sampleRate
    // One second of tone, three of silence: the rhythm of a phone ringing.
    let frames = AVAudioFrameCount(rate * 4)
    guard
      let buffer = AVAudioPCMBuffer(pcmFormat: toneFormat, frameCapacity: frames)
    else { return }
    buffer.frameLength = frames
    guard let samples = buffer.floatChannelData?[0] else { return }
    for index in 0..<Int(frames) {
      let seconds = Double(index) / rate
      if seconds < 1.0 {
        let a = sin(2 * Double.pi * 440 * seconds)
        let b = sin(2 * Double.pi * 480 * seconds)
        samples[index] = Float((a + b) * 0.12)
      } else {
        samples[index] = 0
      }
    }
    ringback.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
      DispatchQueue.main.async { self?.scheduleRingback() }
    }
  }

  func stopRingback() {
    ringback.stop()
    ringbackFormat = nil
  }

  /// Drops anything still queued, so an interruption goes quiet at once.
  func stop() {
    stopRingback()
    stopCapture()
    node.stop()
    engine.stop()
    prepared = false
    // Voice processing holds the input hardware; leaving it on keeps the
    // microphone busy after the call has ended.
    try? engine.inputNode.setVoiceProcessingEnabled(false)
    try? engine.outputNode.setVoiceProcessingEnabled(false)
    engine.reset()
    format = nil
  }
}

final class OnDeviceSpeechRecognizer: NSObject, FlutterStreamHandler {
  private let output = CallAudioOutput()

  static let channelName = "halo.speech/on_device"

  static let micChannelName = "halo.speech/mic"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let instance = OnDeviceSpeechRecognizer()
    channel.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
    // The call's microphone arrives here rather than through a second
    // recorder, so nothing competes for the input hardware mid-call.
    FlutterEventChannel(
      name: micChannelName,
      binaryMessenger: registrar.messenger()
    ).setStreamHandler(instance)
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

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    output.startCapture { data in
      DispatchQueue.main.async { events(FlutterStandardTypedData(bytes: data)) }
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    output.stopCapture()
    return nil
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
    case "startRingback":
      // A synthesised ringback, so dialling sounds like dialling without
      // shipping an audio file.
      output.startRingback()
      result(true)
    case "stopRingback":
      output.stopRingback()
      result(true)
    case "prepareRecording":
      // Voice messages record through their own recorder, which needs the
      // session back in a plain record category after a call has held it.
      do {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        result(true)
      } catch {
        result(FlutterError(code: "audio_session_busy", message: nil, details: nil))
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
      // Hand the audio session back. A call leaves it active in playAndRecord
      // with voice processing, and the next recorder — a voice message — then
      // cannot start at all.
      UIDevice.current.isProximityMonitoringEnabled = false
      NotificationCenter.default.removeObserver(
        self,
        name: UIDevice.proximityStateDidChangeNotification,
        object: nil
      )
      try? AVAudioSession.sharedInstance().setActive(
        false,
        options: .notifyOthersOnDeactivation
      )
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
