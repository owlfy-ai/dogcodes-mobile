import CoreMedia
import CoreVideo
import Flutter
import VideoToolbox

/// `dogcodes/h264`: create / decode / dispose hardware H.264 decoders whose
/// output is a Flutter texture.
public final class DogcodesVideoPlugin: NSObject, FlutterPlugin {
  private let textures: FlutterTextureRegistry
  private var decoders: [Int64: H264Texture] = [:]

  init(textures: FlutterTextureRegistry) {
    self.textures = textures
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "dogcodes/h264", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(
      DogcodesVideoPlugin(textures: registrar.textures()), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "create":
      let texture = H264Texture(textures: textures)
      let id = textures.register(texture)
      texture.textureId = id
      decoders[id] = texture
      result(id)
    case "decode":
      guard let id = (args["id"] as? NSNumber)?.int64Value, let texture = decoders[id],
        let data = (args["data"] as? FlutterStandardTypedData)?.data
      else {
        result(FlutterError(code: "invalid", message: "unknown decoder", details: nil))
        return
      }
      texture.decode(data) { error in
        if let error {
          result(FlutterError(code: "needKeyframe", message: "\(error)", details: nil))
        } else { result(nil) }
      }
    case "stats":
      guard let id = (args["id"] as? NSNumber)?.int64Value, let texture = decoders[id] else {
        result(FlutterError(code: "invalid", message: "unknown decoder", details: nil))
        return
      }
      result(texture.stats)
    case "dispose":
      if let id = (args["id"] as? NSNumber)?.int64Value, let texture = decoders.removeValue(forKey: id) {
        textures.unregisterTexture(id)
        texture.invalidate()
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

enum DecodeError: Error {
  case needKeyframe
  case status(OSStatus)
}

/// Splits Annex-B into NAL units (without start codes).
func annexBUnits(_ data: Data) -> [Data] {
  var units: [Data] = []
  let bytes = [UInt8](data)
  var i = 0
  var start = -1
  while i + 2 < bytes.count {
    if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
      if start >= 0 {
        var end = i
        // A 4-byte start code's leading zero belongs to it, not the unit.
        if end > start && bytes[end - 1] == 0 { end -= 1 }
        units.append(Data(bytes[start..<end]))
      }
      i += 3
      start = i
    } else {
      i += 1
    }
  }
  if start >= 0 && start < bytes.count {
    units.append(Data(bytes[start...]))
  }
  return units
}

/// One stream: SPS/PPS from each keyframe (re)build the session; slices are
/// decoded asynchronously into BGRA IOSurface buffers that the texture shows.
final class H264Texture: NSObject, FlutterTexture {
  private typealias Completion = (DecodeError?) -> Void
  private weak var textures: FlutterTextureRegistry?
  var textureId: Int64 = 0
  private let lock = NSLock()
  private let worker = DispatchQueue(label: "dogcodes.h264.decode")
  private var latest: CVPixelBuffer?
  // These four fields belong exclusively to worker.
  private var session: VTDecompressionSession?
  private var format: CMVideoFormatDescription?
  private var sps = Data()
  private var pps = Data()
  private var failed = false
  private var closed = false
  private var decodedCount = 0
  private var nextTicket: UInt64 = 0
  private struct Pending {
    let data: Data
    let completion: Completion
  }
  private var pending: [UInt64: Pending] = [:]
  private var peakPending = 0

  var stats: [String: Int] {
    lock.lock()
    defer { lock.unlock() }
    return ["decoded": decodedCount, "pending": pending.count, "maxPending": peakPending]
  }

  init(textures: FlutterTextureRegistry) { self.textures = textures }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let buffer = latest else { return nil }
    return Unmanaged.passRetained(buffer)
  }

  private func deliver(_ completion: @escaping Completion, _ error: DecodeError?) {
    DispatchQueue.main.async { completion(error) }
  }

  /// Unregistering a texture never waits for a hardware driver on the UI thread.
  func invalidate() {
    lock.lock()
    if closed { lock.unlock(); return }
    closed = true
    latest = nil
    let callbacks = pending.values.map { $0.completion }
    pending.removeAll()
    lock.unlock()
    for callback in callbacks { deliver(callback, .needKeyframe) }
    worker.async { self.reset(keeping: nil) }
  }

  /// Reservations include work not yet submitted to VideoToolbox. Thus a slow
  /// worker cannot accumulate an unbounded queue of retained access units.
  func decode(_ data: Data, completion: @escaping (DecodeError?) -> Void) {
    lock.lock()
    guard !closed, !data.isEmpty, data.count <= 4 * 1024 * 1024, pending.count < 3 else {
      failed = true
      lock.unlock()
      deliver(completion, .needKeyframe)
      return
    }
    nextTicket &+= 1
    let ticket = nextTicket
    pending[ticket] = Pending(data: data, completion: completion)
    peakPending = max(peakPending, pending.count)
    lock.unlock()
    worker.async {
      do { try self.submit(ticket: ticket) }
      catch let error as DecodeError { self.finish(ticket, error: error) }
      catch { self.finish(ticket, error: .needKeyframe) }
    }
  }

  private func active(_ ticket: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return !closed && pending[ticket] != nil
  }

  private func finish(_ ticket: UInt64, error: DecodeError?) {
    lock.lock()
    let callback = pending.removeValue(forKey: ticket)?.completion
    if callback != nil && error != nil { failed = true }
    lock.unlock()
    if let callback { deliver(callback, error) }
  }

  private func submit(ticket: UInt64) throws {
    lock.lock()
    let input = closed ? nil : pending[ticket]?.data
    lock.unlock()
    guard let data = input else { return }
    var slices: [Data] = []
    var newSps: Data?
    var newPps: Data?
    for unit in annexBUnits(data) where !unit.isEmpty {
      switch unit[unit.startIndex] & 0x1f {
      case 7: newSps = unit
      case 8: newPps = unit
      case 1, 5: slices.append(unit)
      default: break
      }
    }
    lock.lock()
    let wasBroken = failed
    lock.unlock()
    if let s = newSps, let p = newPps,
      s != sps || p != pps || session == nil || wasBroken {
      try rebuild(sps: s, pps: p, ticket: ticket)
    }
    lock.lock()
    let broken = failed
    lock.unlock()
    guard active(ticket), let session, let format, !broken else { throw DecodeError.needKeyframe }
    if slices.isEmpty { finish(ticket, error: nil); return }

    var avcc = Data()
    for slice in slices {
      var length = UInt32(slice.count).bigEndian
      avcc.append(Data(bytes: &length, count: 4))
      avcc.append(slice)
    }
    var block: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
      blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
      dataLength: avcc.count, flags: 0, blockBufferOut: &block)
    guard status == noErr, let block else { throw DecodeError.status(status) }
    status = avcc.withUnsafeBytes { raw in
      CMBlockBufferReplaceDataBytes(
        with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
        dataLength: avcc.count)
    }
    guard status == noErr else { throw DecodeError.status(status) }
    var sample: CMSampleBuffer?
    var size = avcc.count
    status = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
      sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
      sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
    guard status == noErr, let sample else { throw DecodeError.status(status) }
    guard active(ticket) else { return }
    status = VTDecompressionSessionDecodeFrame(
      session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil
    ) { [weak self] status, _, image, _, _ in
      self?.decoded(ticket: ticket, status: status, image: image)
    }
    // The callback and an immediate error may race. Taking the ticket makes
    // completion exactly once, and retired callbacks cannot alter a new stream.
    if status != noErr { finish(ticket, error: .status(status)) }
  }

  private func decoded(ticket: UInt64, status: OSStatus, image: CVImageBuffer?) {
    lock.lock()
    guard !closed, let callback = pending.removeValue(forKey: ticket)?.completion else { lock.unlock(); return }
    let success = status == noErr && image != nil
    if success { latest = image; decodedCount += 1 } else { failed = true }
    lock.unlock()
    DispatchQueue.main.async { [weak self] in
      if let self {
        self.lock.lock()
        let live = !self.closed
        self.lock.unlock()
        if success && live { self.textures?.textureFrameAvailable(self.textureId) }
      }
      callback(success ? nil : .needKeyframe)
    }
  }

  /// Only worker touches sessions. Remove obsolete callbacks before invalidation
  /// so a late old output cannot report progress or publish the previous screen.
  private func reset(keeping ticket: UInt64?) {
    lock.lock()
    let obsolete = pending.filter { $0.key != ticket }.values.map { $0.completion }
    pending = pending.filter { $0.key == ticket }
    latest = nil
    lock.unlock()
    for callback in obsolete { deliver(callback, .needKeyframe) }
    let old = session
    session = nil
    format = nil
    if let old { VTDecompressionSessionInvalidate(old) }
  }

  private func rebuild(sps: Data, pps: Data, ticket: UInt64) throws {
    reset(keeping: ticket)
    var newFormat: CMVideoFormatDescription?
    let status: OSStatus = sps.withUnsafeBytes { s in
      pps.withUnsafeBytes { p in
        let pointers: [UnsafePointer<UInt8>] = [
          s.bindMemory(to: UInt8.self).baseAddress!,
          p.bindMemory(to: UInt8.self).baseAddress!,
        ]
        let sizes = [sps.count, pps.count]
        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
          allocator: kCFAllocatorDefault, parameterSetCount: 2,
          parameterSetPointers: pointers, parameterSetSizes: sizes,
          nalUnitHeaderLength: 4, formatDescriptionOut: &newFormat)
      }
    }
    guard status == noErr, let newFormat else { throw DecodeError.status(status) }
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
      kCVPixelBufferMetalCompatibilityKey: true,
    ]
    var newSession: VTDecompressionSession?
    let created = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault, formatDescription: newFormat,
      decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
      outputCallback: nil, decompressionSessionOut: &newSession)
    guard created == noErr, let newSession else { throw DecodeError.status(created) }
    VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    lock.lock()
    session = newSession
    format = newFormat
    self.sps = sps
    self.pps = pps
    failed = closed
    lock.unlock()
  }
}
