import AVFoundation
import AppKit
import ArgumentParser
import CoreMedia
import Darwin
import Dispatch
import FluidAudio
import Foundation
import os

@main
struct Tinyparakeet: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tinyparakeet",
    abstract: "Record from the mic, stream-transcribe with Parakeet, print + copy to clipboard."
  )

  @Option(
    name: .shortAndLong,
    help: "Input device name (substring match, case-insensitive). Defaults to system default input."
  )
  var device: String?

  @Flag(name: .long, help: "List available input devices and exit.")
  var listDevices: Bool = false

  @Flag(name: .long, help: "Print transcription only; don't copy to clipboard.")
  var noCopy: Bool = false

  mutating func run() async throws {
    if listDevices {
      let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
      for d in InputDevices.all() {
        print("\(d.localizedName)\(d.uniqueID == defaultID ? "  (default)" : "")")
      }
      return
    }

    try await ensureMicrophonePermission()

    Log.info("loading model...")
    let manager = StreamingModelVariant.parakeetEou160ms.createManager()
    try await manager.loadModels()

    await manager.setPartialTranscriptCallback { text in
      Log.partial(text)
    }

    let final = try await streamAndTranscribe(manager: manager, deviceQuery: device)
    let pipedStdout = isatty(STDOUT_FILENO) == 0
    Log.show(final: final, alsoEmitToStdout: pipedStdout)

    if final.isEmpty {
      Log.info("(no audio captured)")
    } else if !noCopy {
      let pb = NSPasteboard.general
      pb.clearContents()
      pb.setString(final, forType: .string)
      Log.info("copied to clipboard")
    }
  }
}

func ensureMicrophonePermission() async throws {
  guard await AVCaptureDevice.requestAccess(for: .audio) else {
    throw ValidationError(
      "microphone permission denied - enable your terminal/launcher in System Settings > Privacy & Security > Microphone"
    )
  }
}

final class AudioInputCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate,
  @unchecked Sendable
{
  struct Stats {
    var dropped = 0
    var copyErrors = 0
    var lastCopyError: OSStatus = noErr
    var runtimeError: String?
  }

  private let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "tinyparakeet.capture", qos: .userInteractive)
  private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
  private let stats = OSAllocatedUnfairLock(initialState: Stats())
  private var cachedFormat: (desc: CMFormatDescription, format: AVAudioFormat)?
  private var errorObserver: NSObjectProtocol?

  init(
    device: AVCaptureDevice,
    continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
  ) throws {
    self.continuation = continuation
    super.init()

    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else {
      throw ValidationError("cannot attach input device \"\(device.localizedName)\"")
    }
    session.addInput(input)

    let output = AVCaptureAudioDataOutput()
    output.setSampleBufferDelegate(self, queue: queue)
    guard session.canAddOutput(output) else {
      throw ValidationError("cannot attach audio capture output")
    }
    session.addOutput(output)

    errorObserver = NotificationCenter.default.addObserver(
      forName: AVCaptureSession.runtimeErrorNotification,
      object: session,
      queue: nil
    ) { [weak self] note in
      let message =
        (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
        ?? "unknown capture session error"
      self?.stats.withLock { $0.runtimeError = message }
    }
  }

  deinit {
    stop()
    if let errorObserver {
      NotificationCenter.default.removeObserver(errorObserver)
    }
  }

  func start() {
    session.startRunning()
  }

  func stop() {
    if session.isRunning {
      session.stopRunning()
    }
    queue.sync {}
  }

  func captureStats() -> Stats {
    stats.withLock { $0 }
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
    let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
    guard frameCount > 0 else { return }

    guard let format = resolvedFormat(for: formatDesc) else {
      stats.withLock { $0.dropped += 1 }
      return
    }
    guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
      stats.withLock { $0.dropped += 1 }
      return
    }
    pcm.frameLength = frameCount

    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
      sampleBuffer,
      at: 0,
      frameCount: Int32(frameCount),
      into: pcm.mutableAudioBufferList
    )
    guard status == noErr else {
      stats.withLock {
        $0.copyErrors += 1
        $0.lastCopyError = status
      }
      return
    }
    continuation.yield(pcm)
  }

  private func resolvedFormat(for formatDesc: CMFormatDescription) -> AVAudioFormat? {
    if let cached = cachedFormat, cached.desc == formatDesc {
      return cached.format
    }
    guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
      return nil
    }
    let channels = asbdPtr.pointee.mChannelsPerFrame
    let format: AVAudioFormat?
    if channels > 2 {
      let layout =
        CMAudioFormatDescriptionGetChannelLayout(formatDesc, sizeOut: nil).map {
          AVAudioChannelLayout(layout: $0)
        }
        ?? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)
      format = layout.flatMap { AVAudioFormat(streamDescription: asbdPtr, channelLayout: $0) }
    } else {
      format = AVAudioFormat(streamDescription: asbdPtr)
    }
    cachedFormat = format.map { (formatDesc, $0) }
    return format
  }
}

/// Stateful converter to 16 kHz mono Float32 non-interleaved so FluidAudio hits
/// its fast path without resetting a Mastering FIR filter on every capture slice.
final class StreamingResampler {
  private static let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16_000,
    channels: 1,
    interleaved: false
  )!

  private enum Mode {
    case passthrough
    case convert(AVAudioConverter)
  }

  private var state: (format: AVAudioFormat, mode: Mode)?

  func process(_ buffer: AVAudioPCMBuffer) throws -> [AVAudioPCMBuffer] {
    var outputs: [AVAudioPCMBuffer] = []
    if let current = state, current.format != buffer.format {
      outputs.append(contentsOf: try flush())
      state = nil
    }
    let mode: Mode
    if let current = state {
      mode = current.mode
    } else {
      let created = try makeMode(for: buffer.format)
      state = (buffer.format, created)
      mode = created
    }

    switch mode {
    case .passthrough:
      outputs.append(buffer)
    case .convert(let converter):
      if let out = try convertStreaming(buffer, using: converter) {
        outputs.append(out)
      }
    }
    return outputs
  }

  func flush() throws -> [AVAudioPCMBuffer] {
    guard case .convert(let converter) = state?.mode else { return [] }
    var buffers: [AVAudioPCMBuffer] = []
    while let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 4096) {
      var err: NSError?
      let status = converter.convert(to: out, error: &err) { _, outStatus in
        outStatus.pointee = .endOfStream
        return nil
      }
      if status == .error {
        throw err ?? ValidationError("audio conversion failed")
      }
      if out.frameLength > 0 { buffers.append(out) }
      if status != .haveData { break }
    }
    return buffers
  }

  private func makeMode(for format: AVAudioFormat) throws -> Mode {
    if format == Self.targetFormat {
      return .passthrough
    }
    guard let converter = AVAudioConverter(from: format, to: Self.targetFormat) else {
      throw ValidationError(
        "failed to create audio converter from \(format) to \(Self.targetFormat)")
    }
    if format.channelCount == 2 && converter.channelMap != [-1] {
      converter.downmix = true
    } else if format.channelCount > 1 {
      converter.channelMap = [0]
    }
    converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
    converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
    return .convert(converter)
  }

  private func convertStreaming(
    _ input: AVAudioPCMBuffer,
    using converter: AVAudioConverter
  ) throws -> AVAudioPCMBuffer? {
    let ratio = converter.outputFormat.sampleRate / input.format.sampleRate
    let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 32
    guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity)
    else { return nil }
    var fed = false
    var err: NSError?
    let status = converter.convert(to: out, error: &err) { _, outStatus in
      if !fed {
        fed = true
        outStatus.pointee = .haveData
        return input
      }
      outStatus.pointee = .noDataNow
      return nil
    }
    if status == .error {
      throw err ?? ValidationError("audio conversion failed")
    }
    return out.frameLength > 0 ? out : nil
  }
}

func streamAndTranscribe(manager: any StreamingAsrManager, deviceQuery: String?) async throws
  -> String
{
  let selected: AVCaptureDevice
  if let q = deviceQuery {
    guard let match = InputDevices.find(matching: q) else {
      throw ValidationError("no input device matches \"\(q)\"")
    }
    selected = match
    Log.info("input: \(selected.localizedName)")
  } else {
    guard let def = AVCaptureDevice.default(for: .audio) else {
      throw ValidationError("no default input device available")
    }
    selected = def
    Log.info("input: \(selected.localizedName)  (default)")
  }

  // Unbounded buffering: capture callbacks must never block. Drain is awaited
  // per buffer, so if the model falls behind memory grows until stop.
  let (stream, continuation) = AsyncStream.makeStream(
    of: AVAudioPCMBuffer.self,
    bufferingPolicy: .unbounded
  )

  let capture = try AudioInputCapture(device: selected, continuation: continuation)
  let resampler = StreamingResampler()
  capture.start()
  Log.info("recording - press Enter or Ctrl-C to stop")

  let stopWaiter = Task { await StopSignal.wait() }
  let drainTask: Task<Void, Error> = Task {
    func feed(_ chunks: [AVAudioPCMBuffer]) async throws {
      for chunk in chunks {
        try await manager.appendAudio(chunk)
        try await manager.processBufferedAudio()
      }
    }
    do {
      for await buf in stream {
        try await feed(try resampler.process(buf))
      }
      try await feed(try resampler.flush())
    } catch {
      stopWaiter.cancel()
      throw error
    }
  }

  defer {
    stopWaiter.cancel()
    capture.stop()
    continuation.finish()
  }

  await stopWaiter.value
  capture.stop()
  continuation.finish()
  try await drainTask.value

  let stats = capture.captureStats()
  if stats.dropped > 0 {
    Log.info("warning: dropped \(stats.dropped) audio buffer(s)")
  }
  if stats.copyErrors > 0 {
    Log.info(
      "warning: \(stats.copyErrors) audio copy error(s) (last status \(stats.lastCopyError))"
    )
  }
  if let runtimeError = stats.runtimeError {
    Log.info("warning: capture session error: \(runtimeError)")
  }

  return try await manager.finish()
}

/// Wait for either Return on stdin or SIGINT, suppressing tty echo (`ECHO`,
/// `ECHONL`, `ECHOCTL`) while waiting so neither Return nor Ctrl-C shifts the
/// cursor off the live partial line. Restores both termios and SIGINT on exit.
enum StopSignal {
  private enum State {
    case pending
    case waiting(CheckedContinuation<Void, Never>)
    case done
  }

  static func wait() async {
    var savedTermios = termios()
    let restoreTermios = isatty(STDIN_FILENO) != 0 && tcgetattr(STDIN_FILENO, &savedTermios) == 0
    if restoreTermios {
      var quiet = savedTermios
      quiet.c_lflag &= ~tcflag_t(ECHO | ECHONL | ECHOCTL)
      tcsetattr(STDIN_FILENO, TCSANOW, &quiet)
    }

    // SIG_IGN suppresses the default action so the DispatchSource handler can fire.
    signal(SIGINT, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    let state = OSAllocatedUnfairLock(initialState: State.pending)
    let resumeOnce: @Sendable () -> Void = {
      let cont = state.withLock { current -> CheckedContinuation<Void, Never>? in
        switch current {
        case .pending:
          current = .done
          return nil
        case .waiting(let c):
          current = .done
          return c
        case .done:
          return nil
        }
      }
      cont?.resume()
    }
    src.setEventHandler { resumeOnce() }
    src.resume()
    defer {
      src.cancel()
      signal(SIGINT, SIG_DFL)
      if restoreTermios {
        tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
      }
    }

    await withTaskCancellationHandler {
      await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        let immediate = state.withLock { current -> Bool in
          switch current {
          case .pending:
            current = .waiting(cont)
            return false
          case .waiting, .done:
            return true
          }
        }
        if immediate {
          cont.resume()
        } else {
          Task.detached {
            _ = readLine()
            resumeOnce()
          }
        }
      }
    } onCancel: {
      resumeOnce()
    }
  }
}

enum Log {
  private static let lock = NSLock()
  private static var partialActive = false

  private static let stderrTty: Bool = isatty(STDERR_FILENO) != 0
  private static let stamper: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
  }()
  private static func currentCols() -> Int {
    var ws = winsize()
    _ = ioctl(STDERR_FILENO, TIOCGWINSZ, &ws)
    let c = Int(ws.ws_col)
    return c > 10 ? c : 80
  }

  private enum Ansi {
    static let reset = "\u{1B}[0m"
    static let dim = "\u{1B}[2m"
    static let clearLine = "\u{1B}[2K"
  }

  static func info(_ s: String) {
    write {
      dropPartial()
      let line = "[\(stamper.string(from: Date()))] \(s)"
      if stderrTty {
        writeRaw("\(Ansi.dim)\(line)\(Ansi.reset)\n")
      } else {
        writeRaw(line + "\n")
      }
    }
  }

  /// Live transcript preview. On a tty the partial is redrawn in place on a
  /// single line: carriage-return to column 0, clear the line, write the tail
  /// that fits. Staying on one line is the whole trick - `\r` + clear-line is
  /// the one redraw every terminal does identically, so there's no cursor math
  /// to get wrong across wrapping, scrolling, or resize.
  static func partial(_ s: String) {
    let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    write {
      if stderrTty {
        writeRaw("\r\(Ansi.clearLine)\(clip(text))")
        partialActive = true
      } else {
        writeRaw(text + "\n")
      }
    }
  }

  /// Replace the live partial line with the authoritative final text.
  /// If stdout is piped, also emit the final to stdout.
  static func show(final: String, alsoEmitToStdout: Bool) {
    write {
      dropPartial()
      if !final.isEmpty {
        writeRaw(final + "\n")
      }
    }
    if alsoEmitToStdout && !final.isEmpty {
      FileHandle.standardOutput.write(Data((final + "\n").utf8))
    }
  }

  private static func write(_ body: () -> Void) {
    lock.lock()
    defer { lock.unlock() }
    body()
  }

  private static func dropPartial() {
    if partialActive {
      writeRaw("\r\(Ansi.clearLine)")
      partialActive = false
    }
  }

  private static func clip(_ s: String) -> String {
    let maxLen = currentCols() - 1
    if s.count <= maxLen { return s }
    return String(s.suffix(maxLen))
  }

  private static func writeRaw(_ s: String) {
    FileHandle.standardError.write(Data(s.utf8))
  }
}

enum InputDevices {
  static func all() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
      deviceTypes: [.microphone, .external],
      mediaType: .audio,
      position: .unspecified
    ).devices
  }

  static func find(matching query: String) -> AVCaptureDevice? {
    all().first { $0.localizedName.localizedCaseInsensitiveContains(query) }
  }
}
