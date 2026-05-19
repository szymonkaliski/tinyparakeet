import AVFoundation
import AppKit
import ArgumentParser
import CoreAudio
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
      for d in InputDevices.all() {
        print("\(d.name)\(d.isDefault ? "  (default)" : "")")
      }
      return
    }

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

func streamAndTranscribe(manager: any StreamingAsrManager, deviceQuery: String?) async throws
  -> String
{
  let engine = AVAudioEngine()
  let input = engine.inputNode

  if let q = deviceQuery {
    guard let match = InputDevices.find(matching: q) else {
      throw ValidationError("no input device matches \"\(q)\"")
    }
    try InputDevices.set(deviceID: match.id, on: input)
    Log.info("input: \(match.name)")
  } else if let def = InputDevices.defaultDevice() {
    Log.info("input: \(def.name)  (default)")
  }

  let format = input.outputFormat(forBus: 0)
  guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
    throw ValidationError("unexpected input format: \(format)")
  }

  // Unbounded buffering: realtime audio must never block. Drain is awaited per-buffer,
  // so if the model falls behind memory grows until the user stops the session. Fine
  // for a CLI that runs until Enter/Ctrl-C.
  let (stream, continuation) = AsyncStream.makeStream(
    of: AVAudioPCMBuffer.self,
    bufferingPolicy: .unbounded
  )

  let dropped = OSAllocatedUnfairLock(initialState: 0)

  input.installTap(onBus: 0, bufferSize: 4096, format: format) { buf, _ in
    guard let copy = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: buf.frameLength) else {
      dropped.withLock { $0 += 1 }
      return
    }
    copy.frameLength = buf.frameLength
    let channels = Int(buf.format.channelCount)
    if let src = buf.floatChannelData, let dst = copy.floatChannelData {
      for c in 0..<channels {
        memcpy(dst[c], src[c], Int(buf.frameLength) * MemoryLayout<Float>.size)
      }
    }
    continuation.yield(copy)
  }

  try engine.start()
  Log.info("recording - press Enter or Ctrl-C to stop")

  let drainTask: Task<Void, Error> = Task {
    for await buf in stream {
      try await manager.appendAudio(buf)
      try await manager.processBufferedAudio()
    }
  }

  await StopSignal.wait()

  engine.stop()
  input.removeTap(onBus: 0)
  continuation.finish()
  try await drainTask.value

  let drops = dropped.withLock { $0 }
  if drops > 0 {
    Log.info("warning: dropped \(drops) audio buffer(s) under memory pressure")
  }

  return try await manager.finish()
}

/// Wait for either Enter on stdin or SIGINT. Whichever fires first resolves.
/// SIGINT default handling is restored on exit so callers downstream still die on Ctrl-C.
enum StopSignal {
  static func wait() async {
    // SIG_IGN suppresses the default action so the DispatchSource handler can fire.
    signal(SIGINT, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    defer {
      src.cancel()
      signal(SIGINT, SIG_DFL)
    }

    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      let resolved = OSAllocatedUnfairLock(initialState: false)
      let resumeOnce: @Sendable () -> Void = {
        let should = resolved.withLock { state -> Bool in
          guard !state else { return false }
          state = true
          return true
        }
        if should { cont.resume() }
      }

      src.setEventHandler { resumeOnce() }
      src.resume()

      Task.detached {
        _ = readLine()
        resumeOnce()
      }
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
    static let cursorUp = "\u{1B}[A"
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
      if stderrTty {
        if partialActive {
          // After readLine, the cursor sits one row below the partial; step back up.
          writeRaw("\(Ansi.cursorUp)\r\(Ansi.clearLine)\(final)\n")
          partialActive = false
        } else if !final.isEmpty {
          writeRaw(final + "\n")
        }
      } else if !final.isEmpty {
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
    let max = currentCols() - 1
    if s.count <= max { return s }
    return String(s.suffix(max))
  }

  private static func writeRaw(_ s: String) {
    FileHandle.standardError.write(Data(s.utf8))
  }
}

struct InputDevice {
  let id: AudioDeviceID
  let name: String
  let isDefault: Bool
}

enum InputDevices {
  static func all() -> [InputDevice] {
    let defID = defaultDeviceID()
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        == noErr
    else {
      return []
    }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
    else {
      return []
    }
    return ids.compactMap { id -> InputDevice? in
      guard hasInputStreams(id) else { return nil }
      guard let name = name(of: id) else { return nil }
      return InputDevice(id: id, name: name, isDefault: id == defID)
    }
  }

  static func defaultDevice() -> InputDevice? {
    let id = defaultDeviceID()
    guard id != 0, let name = name(of: id) else { return nil }
    return InputDevice(id: id, name: name, isDefault: true)
  }

  static func find(matching query: String) -> InputDevice? {
    let q = query.lowercased()
    return all().first { $0.name.lowercased().contains(q) }
  }

  static func set(deviceID: AudioDeviceID, on input: AVAudioInputNode) throws {
    guard let unit = input.audioUnit else {
      throw ValidationError("input has no audio unit")
    }
    var id = deviceID
    let status = AudioUnitSetProperty(
      unit,
      kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global,
      0,
      &id,
      UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    guard status == noErr else {
      throw ValidationError("failed to set input device (status \(status))")
    }
  }

  private static func defaultDeviceID() -> AudioDeviceID {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var id: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
    return id
  }

  private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return false }
    return size > 0
  }

  private static func name(of id: AudioDeviceID) -> String? {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
      AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
    }
    guard status == noErr else { return nil }
    return name as String
  }
}
