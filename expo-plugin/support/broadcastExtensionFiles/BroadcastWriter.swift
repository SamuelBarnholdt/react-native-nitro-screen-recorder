// MARK: Broadcast Writer

// Copied from the repo:
// https://github.com/romiroma/BroadcastWriter

import AVFoundation
import AudioToolbox
import CoreGraphics
import Foundation
import ReplayKit

extension AVAssetWriter.Status {
  var description: String {
    switch self {
    case .cancelled: return "cancelled"
    case .completed: return "completed"
    case .failed: return "failed"
    case .unknown: return "unknown"
    case .writing: return "writing"
    @unknown default: return "@unknown default"
    }
  }
}

extension CGFloat {
  var nsNumber: NSNumber {
    return .init(value: native)
  }
}

extension Int {
  var nsNumber: NSNumber {
    return .init(value: self)
  }
}

enum Error: Swift.Error {
  case wrongAssetWriterStatus(AVAssetWriter.Status)
  case selfDeallocated
}

public final class BroadcastWriter {

  private var assetWriterSessionStarted: Bool = false
  // Note: audioAssetWriterSessionStarted removed - PCM doesn't use AVAssetWriter sessions
  private let assetWriterQueue: DispatchQueue
  private let assetWriter: AVAssetWriter

  // Shared session start time for audio/video sync
  // All writers use the same reference timestamp to stay in sync
  private var sessionStartTime: CMTime?

  // Early audio buffering: hold audio samples until video starts
  // This prevents dropping audio that arrives before the first video frame
  private var earlyMicBuffers: [CMSampleBuffer] = []
  private var earlyAppAudioBuffers: [CMSampleBuffer] = []
  private let maxEarlyBufferCount = 500  // ~10 seconds at 48kHz with 1024-sample packets
  private var earlyBuffersDropped: Int = 0

  // Track timestamps for padding audio to match video length
  private var lastVideoEndTime: CMTime = .zero
  private var lastVideoPTS: CMTime?
  private var lastVideoFrameDuration: CMTime = .zero
  private var lastMicEndTime: CMTime = .zero
  private var lastAppAudioEndTime: CMTime = .zero

  // PTS ranges per audio stream (min/max of appended samples)
  private var micPtsMin: CMTime?
  private var micPtsMax: CMTime?
  private var separateMicPtsMin: CMTime?
  private var separateMicPtsMax: CMTime?
  private var appAudioPtsMin: CMTime?
  private var appAudioPtsMax: CMTime?

  // Audio format info for generating silence padding
  private var micAudioFormatDescription: CMFormatDescription?
  private var appAudioFormatDescription: CMFormatDescription?

  // Backpressure metrics
  private var micBackpressureHits: Int = 0
  private var micBackpressureDrops: Int = 0
  private var separateAudioBackpressureHits: Int = 0
  private var separateAudioBackpressureDrops: Int = 0
  private var appAudioBackpressureHits: Int = 0
  private var appAudioBackpressureDrops: Int = 0
  private var videoBackpressureHits: Int = 0
  private var videoBackpressureDrops: Int = 0

  // Audio/video sync offset tracking
  private let timingOffsetThreshold = CMTime(value: 4, timescale: 100)  // 40ms
  private let timingOffsetMax = CMTime(value: 3, timescale: 1)  // 3s
  // Positive values delay audio to counter slight lead on playback
  private let audioLeadCompensation = CMTime(value: 20, timescale: 1000)  // 20ms
  private var micTimingOffset: CMTime = .zero
  private var micTimingOffsetResolved = false
  private var appAudioTimingOffset: CMTime = .zero
  private var appAudioTimingOffsetResolved = false
  private var observedFirstMicDeltaToVideo: Double?
  private var observedFirstAppAudioDeltaToVideo: Double?
  private var micAdjustmentAppliedCount: Int = 0
  private var appAudioAdjustmentAppliedCount: Int = 0
  private var micAdjustmentAppliedSeconds: Double = 0
  private var appAudioAdjustmentAppliedSeconds: Double = 0

  // Audio session change tracking (route/sample rate shifts during a chunk)
  private let audioSessionCheckInterval: TimeInterval = 0.5
  private var lastAudioSessionCheckTime = Date.distantPast
  private var lastAudioRouteSignature: String?
  private var lastAudioSampleRate: Double = 0
  private var lastAudioIOBufferDuration: TimeInterval = 0
  private var audioSessionChangeCount: Int = 0

  // Low power mode tuning (reduce audio drops under CPU pressure)
  private var isLowPowerModeEnabled: Bool {
    if #available(iOS 9.0, *) {
      return ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    return false
  }

  private var audioBackpressureTimeout: TimeInterval {
    return isLowPowerModeEnabled ? 0.1 : 0.05
  }

  private var inputReadyPollInterval: TimeInterval {
    return isLowPowerModeEnabled ? 0.01 : 0.005
  }

  // MARK: - Audio Metrics

  // First PTS tracking for sync analysis
  private var firstVideoPTS: CMTime?
  private var firstMicPTS: CMTime?
  private var firstAppAudioPTS: CMTime?

  // Sample counts
  private var totalVideoFrames: Int = 0
  private var totalMicSamples: Int = 0
  private var totalAppAudioSamples: Int = 0
  private var totalSeparateAudioSamples: Int = 0

  // Drop counts by reason
  private var micDroppedBeforeSession: Int = 0
  private var micDroppedPTSBelowStart: Int = 0
  private var appAudioDroppedBeforeSession: Int = 0
  private var appAudioDroppedPTSBelowStart: Int = 0

  // Monotonicity tracking
  private var lastMicPTS: CMTime?
  private var lastAppAudioPTS: CMTime?
  private var micMonotonicityViolations: Int = 0
  private var appAudioMonotonicityViolations: Int = 0

  // Audio gap tracking (for detecting privacy interruptions)
  private var lastMicBufferTime: Date?
  private var lastAppAudioBufferTime: Date?
  private var micGapCount: Int = 0
  private var appAudioGapCount: Int = 0

  // Channel count tracking for stereo→mono downmix
  private var detectedAppAudioChannels: Int = 0
  private var appAudioDownmixWarningLogged: Bool = false

  // MARK: - Comprehensive Audio Logging
  // Separate log buffer for audio-only diagnostics - RESET per chunk
  private var audioLogBuffer: [String] = []
  private let maxAudioLogEntries = 500
  private let audioLogLock = NSLock()
  private var currentAudioChunkId: String = "pre-chunk"
  private var chunkStartTime: Date = Date()
  
  // Append failure tracking - RESET per chunk
  private var micAppendFailures: Int = 0
  private var separateAudioAppendFailures: Int = 0
  private var appAudioAppendFailures: Int = 0
  private var lastMicAppendError: String?
  private var lastSeparateAudioAppendError: String?
  private var lastAppAudioAppendError: String?
  
  // Sample receive tracking (before any processing) - RESET per chunk
  private var micSamplesReceived: Int = 0
  private var appAudioSamplesReceived: Int = 0
  
  // Format tracking - persists across chunks for continuity detection
  private var lastMicFormat: String?
  private var lastAppAudioFormat: String?
  private var micFormatChanges: Int = 0
  private var appAudioFormatChanges: Int = 0
  
  /// Resets audio logging state for a new chunk
  public func resetAudioLogsForChunk(chunkId: String?) {
    audioLogLock.lock()
    audioLogBuffer.removeAll()
    audioLogLock.unlock()
    
    currentAudioChunkId = chunkId ?? "chunk-\(Int(Date().timeIntervalSince1970))"
    chunkStartTime = Date()
    
    // Reset per-chunk counters
    micAppendFailures = 0
    separateAudioAppendFailures = 0
    appAudioAppendFailures = 0
    lastMicAppendError = nil
    lastSeparateAudioAppendError = nil
    lastAppAudioAppendError = nil
    micSamplesReceived = 0
    appAudioSamplesReceived = 0
    micFormatChanges = 0
    appAudioFormatChanges = 0
    pcmFormatChangeOffsets.removeAll()
    
    audioLog("=== CHUNK START: \(currentAudioChunkId) ===")
    audioLog("Writer state: separateAudioFile=\(separateAudioFile), sampleRate=\(audioSampleRate)")
    audioLog("MIC PCM: handle=\(pcmFileHandle != nil), bytesWritten=\(pcmBytesWritten), formatLocked=\(pcmFormatLocked)")
    audioLog("APPAUDIO writer: status=\(appAudioWriter?.status.description ?? "nil")")
    audioLog("Session: videoStarted=\(assetWriterSessionStarted), appAudioStarted=\(appAudioAssetWriterSessionStarted)")
    if let lastMic = lastMicFormat {
      audioLog("Last mic format (from prev chunk): \(lastMic)")
    }
    if let lastApp = lastAppAudioFormat {
      audioLog("Last appAudio format (from prev chunk): \(lastApp)")
    }
  }
  
  /// Returns the current PCM format info (if available)
  public func getPcmFormatInfo() -> PCMFormatInfo? {
    guard var info = pcmFormatInfo else { return nil }
    info.bytesWritten = pcmBytesWritten
    return info
  }
  
  private func audioLog(_ message: String) {
    let elapsed = Date().timeIntervalSince(chunkStartTime)
    let elapsedStr = String(format: "%.3f", elapsed)
    let entry = "[+\(elapsedStr)s] [\(currentAudioChunkId)] \(message)"
    audioLogLock.lock()
    audioLogBuffer.append(entry)
    if audioLogBuffer.count > maxAudioLogEntries {
      audioLogBuffer.removeFirst(audioLogBuffer.count - maxAudioLogEntries)
    }
    audioLogLock.unlock()
    // Also print for immediate debugging
    debugPrint("🔊 \(message)")
  }
  
  private func formatDescription(_ sampleBuffer: CMSampleBuffer) -> String {
    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
      return "NO_FORMAT"
    }
    return "rate=\(asbd.mSampleRate),ch=\(asbd.mChannelsPerFrame),bits=\(asbd.mBitsPerChannel),frames=\(CMSampleBufferGetNumSamples(sampleBuffer))"
  }
  
  /// Returns the audio-specific log buffer for diagnostics
  public func getAudioLogs() -> [String] {
    audioLogLock.lock()
    let logs = audioLogBuffer
    audioLogLock.unlock()
    return logs
  }
  
  /// Returns comprehensive audio diagnostics as a dictionary
  public func getAudioDiagnostics() -> [String: Any] {
    let chunkDuration = Date().timeIntervalSince(chunkStartTime)
    return [
      // Chunk identification
      "chunkId": currentAudioChunkId,
      "chunkDurationSec": chunkDuration,
      
      // Sample counts
      "micSamplesReceived": micSamplesReceived,
      "appAudioSamplesReceived": appAudioSamplesReceived,
      "totalMicSamples": totalMicSamples,
      "totalSeparateAudioSamples": totalSeparateAudioSamples,
      "totalAppAudioSamples": totalAppAudioSamples,
      
      // Append failures
      "micAppendFailures": micAppendFailures,
      "separateAudioAppendFailures": separateAudioAppendFailures,
      "appAudioAppendFailures": appAudioAppendFailures,
      "lastMicAppendError": lastMicAppendError ?? "none",
      "lastSeparateAudioAppendError": lastSeparateAudioAppendError ?? "none",
      "lastAppAudioAppendError": lastAppAudioAppendError ?? "none",
      
      // Drops
      "micDroppedBeforeSession": micDroppedBeforeSession,
      "micDroppedPTSBelowStart": micDroppedPTSBelowStart,
      "appAudioDroppedBeforeSession": appAudioDroppedBeforeSession,
      "appAudioDroppedPTSBelowStart": appAudioDroppedPTSBelowStart,
      "earlyBuffersDropped": earlyBuffersDropped,
      
      // Backpressure
      "micBackpressureHits": micBackpressureHits,
      "micBackpressureDrops": micBackpressureDrops,
      "separateAudioBackpressureHits": separateAudioBackpressureHits,
      "separateAudioBackpressureDrops": separateAudioBackpressureDrops,
      "appAudioBackpressureHits": appAudioBackpressureHits,
      "appAudioBackpressureDrops": appAudioBackpressureDrops,
      
      // Format changes
      "micFormatChanges": micFormatChanges,
      "appAudioFormatChanges": appAudioFormatChanges,
      "lastMicFormat": lastMicFormat ?? "none",
      "lastAppAudioFormat": lastAppAudioFormat ?? "none",
      
      // Gaps and violations
      "micGapCount": micGapCount,
      "appAudioGapCount": appAudioGapCount,
      "micMonotonicityViolations": micMonotonicityViolations,
      "appAudioMonotonicityViolations": appAudioMonotonicityViolations,
      
      // Session state
      "audioSessionChangeCount": audioSessionChangeCount,
      "appAudioAssetWriterSessionStarted": appAudioAssetWriterSessionStarted,
      
      // PCM mic state
      "pcmFileHandleOpen": pcmFileHandle != nil,
      "pcmBytesWritten": pcmBytesWritten,
      "pcmFormatLocked": pcmFormatLocked,
      "pcmSampleRate": pcmFormatInfo?.sampleRate ?? 0,
      "pcmChannelCount": pcmFormatInfo?.channelCount ?? 0,
      "pcmBitsPerChannel": pcmFormatInfo?.bitsPerChannel ?? 0,
      "pcmDuration": pcmFormatInfo?.duration ?? 0,
      "pcmFormatChangeCount": pcmFormatChangeOffsets.count,
      
      // App audio writer state (still AAC)
      "appAudioWriterStatus": appAudioWriter?.status.description ?? "nil",
      "appAudioWriterError": appAudioWriter?.error?.localizedDescription ?? "none",
      
      // Timing
      "sessionStartTime": sessionStartTime?.seconds ?? -1,
      "firstMicPTS": firstMicPTS?.seconds ?? -1,
      "firstAppAudioPTS": firstAppAudioPTS?.seconds ?? -1,
      "lastMicEndTime": lastMicEndTime.seconds,
      "lastAppAudioEndTime": lastAppAudioEndTime.seconds,
      
      // Early buffers
      "earlyMicBuffersCount": earlyMicBuffers.count,
      "earlyAppAudioBuffersCount": earlyAppAudioBuffers.count,
    ]
  }

  // MARK: - Audio Interruption Handling
  private var isAudioPaused: Bool = false
  private var audioInterruptionCount: Int = 0
  private var audioResumeCount: Int = 0
  private var totalInterruptionDuration: TimeInterval = 0
  private var lastInterruptionTime: Date?

  // MARK: - Sample Rate Tracking
  private var configuredSampleRate: Double = 0
  private var sampleRateMismatchDetected: Bool = false
  private var sampleRateMismatchCount: Int = 0
  private var maxSampleRateDrift: Double = 0

  // MARK: - Format Validation Tracking
  private var lastMicFormatDescription: CMFormatDescription?
  private var lastAppAudioFormatDescription: CMFormatDescription?
  private var micFormatChangeCount: Int = 0
  private var appAudioFormatChangeCount: Int = 0

  // MARK: - Writer Failure Detection
  private var writerFailureDetected: Bool = false
  private var writerFailureTime: Date?
  private var writerFailureError: Swift.Error?
  private var samplesDroppedAfterFailure: Int = 0

  // MARK: - CMTime Precision Tracking
  private var maxTimescaleMismatch: Int32 = 0
  private lazy var defaultAudioFormatDescription: CMFormatDescription? = {
    let fallbackSampleRate = audioSampleRate > 0 ? audioSampleRate : 48_000
    var asbd = AudioStreamBasicDescription(
      mSampleRate: fallbackSampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 2,
      mFramesPerPacket: 1,
      mBytesPerFrame: 2,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 16,
      mReserved: 0
    )
    var desc: CMFormatDescription?
    let status = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &asbd,
      layoutSize: 0,
      layout: nil,
      magicCookieSize: 0,
      magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &desc
    )
    if status != noErr {
      debugPrint("⚠️ Failed to create default audio format description: \(status)")
      return nil
    }
    return desc
  }()

  // MARK: - PCM Mic Audio Writer
  // Replaces AVAssetWriter with raw PCM streaming for guaranteed partial recovery
  
  /// PCM format metadata for computing duration and playback
  public struct PCMFormatInfo: Codable {
    public let sampleRate: Double
    public let channelCount: Int
    public let bitsPerChannel: Int
    public let isFloat: Bool
    public let isInterleaved: Bool
    public var bytesPerFrame: Int { (bitsPerChannel / 8) * channelCount }
    public var bytesWritten: Int64 = 0
    
    /// Computed duration in seconds based on bytes written
    public var duration: Double {
      guard bytesPerFrame > 0, sampleRate > 0 else { return 0 }
      return Double(bytesWritten) / Double(bytesPerFrame) / sampleRate
    }
    
    public init(sampleRate: Double, channelCount: Int, bitsPerChannel: Int, isFloat: Bool, isInterleaved: Bool) {
      self.sampleRate = sampleRate
      self.channelCount = channelCount
      self.bitsPerChannel = bitsPerChannel
      self.isFloat = isFloat
      self.isInterleaved = isInterleaved
    }
  }
  
  private var pcmFileHandle: FileHandle?
  private var pcmFormatInfo: PCMFormatInfo?
  private var pcmBytesWritten: Int64 = 0
  private var pcmFormatLocked: Bool = false  // Once format is set, reject changes
  private var pcmFormatChangeOffsets: [(offset: Int64, format: String)] = []  // Track format shifts
  
  private let separateAudioFile: Bool
  private let audioOutputURL: URL?

  // Separate app audio writer
  private var appAudioWriter: AVAssetWriter?
  private let appAudioOutputURL: URL?
  private var appAudioAssetWriterSessionStarted: Bool = false

  private lazy var videoInput: AVAssetWriterInput = { [unowned self] in
    let videoWidth = screenSize.width * screenScale
    let videoHeight = screenSize.height * screenScale

    // Ensure encoder-friendly even dimensions
    let w = (Int(videoWidth) / 2) * 2
    let h = (Int(videoHeight) / 2) * 2

    // Decide codec: prefer HEVC when available
    let hevcSupported: Bool = {
      if #available(iOS 11.0, *) {
        return self.assetWriter.canApply(
          outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevc],
          forMediaType: .video
        )
      }
      return false
    }()

    let codec: AVVideoCodecType = hevcSupported ? .hevc : .h264

    var compressionProperties: [String: Any] = [
      AVVideoExpectedSourceFrameRateKey: 30.nsNumber
    ]
    if hevcSupported {
      // Works broadly; adjust if you need different profiles
      compressionProperties[AVVideoProfileLevelKey] = "HEVC_Main_AutoLevel"
    } else {
      compressionProperties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
    }

    let videoSettings: [String: Any] = [
      AVVideoCodecKey: codec,
      AVVideoWidthKey: w.nsNumber,
      AVVideoHeightKey: h.nsNumber,
      AVVideoCompressionPropertiesKey: compressionProperties,
    ]

    let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    input.expectsMediaDataInRealTime = true
    return input
  }()

  private var audioSampleRate: Double {
    #if os(iOS)
      return AVAudioSession.sharedInstance().sampleRate
    #else
      return 48_000
    #endif
  }
  private lazy var audioInput: AVAssetWriterInput = {

    var audioSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVNumberOfChannelsKey: 1,
      AVSampleRateKey: audioSampleRate,
    ]
    let input: AVAssetWriterInput = .init(
      mediaType: .audio,
      outputSettings: audioSettings
    )
    input.expectsMediaDataInRealTime = true
    return input
  }()

  private lazy var microphoneInput: AVAssetWriterInput = {
    let rate = audioSampleRate
    if configuredSampleRate == 0 { configuredSampleRate = rate }
    debugPrint("📊 Configuring microphoneInput @ \(rate)Hz")

    var audioSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVNumberOfChannelsKey: 1,
      AVSampleRateKey: rate,
    ]
    let input: AVAssetWriterInput = .init(
      mediaType: .audio,
      outputSettings: audioSettings
    )
    input.expectsMediaDataInRealTime = true
    return input
  }()

  // Note: separateAudioInput removed - PCM mic audio uses direct FileHandle writes

  // Separate app audio file input (still uses AAC)
  private lazy var appAudioInput: AVAssetWriterInput = {
    // Calculate appropriate bitrate based on sample rate
    // AAC encoder rejects high bitrates for low sample rates (e.g. 128kbps at 24kHz)
    // Base: 64kbps for 44.1kHz mono, scaled proportionally
    let scaleFactor = audioSampleRate / 44100.0
    let bitRatePerChannel = 64000.0 * scaleFactor
    let calculatedBitRate = Int(bitRatePerChannel)
    let bitRate = max(min(calculatedBitRate, 128000), 24000)

    var audioSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVNumberOfChannelsKey: 1,
      AVSampleRateKey: audioSampleRate,
      AVEncoderBitRateKey: bitRate,
    ]
    let input: AVAssetWriterInput = .init(
      mediaType: .audio,
      outputSettings: audioSettings
    )
    input.expectsMediaDataInRealTime = true
    return input
  }()

  // Main video file inputs: video + mic audio only (no app audio)
  // App audio is written to a separate file for Mux compatibility
  private lazy var inputs: [AVAssetWriterInput] = [
    videoInput,
    microphoneInput,
  ]

  private let screenSize: CGSize
  private let screenScale: CGFloat

  public init(
    outputURL url: URL,
    audioOutputURL: URL? = nil,
    appAudioOutputURL: URL? = nil,
    assetWriterQueue queue: DispatchQueue = .init(label: "BroadcastSampleHandler.assetWriterQueue"),
    screenSize: CGSize,
    screenScale: CGFloat,
    separateAudioFile: Bool = false
  ) throws {
    assetWriterQueue = queue
    assetWriter = try .init(url: url, fileType: .mp4)
    assetWriter.shouldOptimizeForNetworkUse = true

    self.screenSize = screenSize
    self.screenScale = screenScale
    self.separateAudioFile = separateAudioFile
    self.audioOutputURL = audioOutputURL
    self.appAudioOutputURL = appAudioOutputURL

    // Initialize PCM mic audio file if needed (raw streaming, no encoder)
    if separateAudioFile, let audioURL = audioOutputURL {
      // Create empty file and open for writing
      FileManager.default.createFile(atPath: audioURL.path, contents: nil, attributes: nil)
      pcmFileHandle = try FileHandle(forWritingTo: audioURL)
      debugPrint("📝 PCM mic audio file created: \(audioURL.lastPathComponent)")
    }

    // Initialize separate app audio writer if needed
    if separateAudioFile, let appAudioURL = appAudioOutputURL {
      appAudioWriter = try .init(url: appAudioURL, fileType: .m4a)
      appAudioWriter?.shouldOptimizeForNetworkUse = true
    }
  }

  public func start() throws {
    try assetWriterQueue.sync {
      let status = assetWriter.status
      guard status == .unknown else {
        throw Error.wrongAssetWriterStatus(status)
      }
      try assetWriter.error.map {
        throw $0
      }
      inputs
        .lazy
        .filter(assetWriter.canAdd(_:))
        .forEach(assetWriter.add(_:))
      try assetWriter.error.map {
        throw $0
      }
      assetWriter.startWriting()
      try assetWriter.error.map {
        throw $0
      }

      // PCM mic audio file is already opened in init - no encoder to start

      // Start separate app audio writer if enabled (still AAC for app audio)
      if separateAudioFile, let appWriter = appAudioWriter {
        let appAudioStatus = appWriter.status
        guard appAudioStatus == .unknown else {
          throw Error.wrongAssetWriterStatus(appAudioStatus)
        }
        try appWriter.error.map { throw $0 }
        if appWriter.canAdd(appAudioInput) {
          appWriter.add(appAudioInput)
        }
        try appWriter.error.map { throw $0 }
        appWriter.startWriting()
        try appWriter.error.map { throw $0 }
      }
      
      // Log audio writer initialization
      audioLog("WRITER STARTED: separateAudioFile=\(separateAudioFile), sampleRate=\(audioSampleRate)")
      if separateAudioFile {
        audioLog("MIC PCM: fileHandle=\(pcmFileHandle != nil), bytesWritten=\(pcmBytesWritten)")
        audioLog("APPAUDIO WRITER: status=\(appAudioWriter?.status.description ?? "nil"), canAdd=\(appAudioWriter?.canAdd(appAudioInput) ?? false)")
      }
    }
  }

  public func processSampleBuffer(
    _ sampleBuffer: CMSampleBuffer,
    with sampleBufferType: RPSampleBufferType
  ) throws -> Bool {

    guard sampleBuffer.isValid,
      CMSampleBufferDataIsReady(sampleBuffer)
    else {
      debugPrint(
        "sampleBuffer.isValid", sampleBuffer.isValid,
        "CMSampleBufferDataIsReady(sampleBuffer)", CMSampleBufferDataIsReady(sampleBuffer)
      )
      return false
    }

    let isWriting = assetWriterQueue.sync {
      let status = assetWriter.status
      if status != .writing && !writerFailureDetected {
        writerFailureDetected = true
        writerFailureTime = Date()
        writerFailureError = assetWriter.error
        debugPrint("🔴 AVAssetWriter FAILED: \(status.description), error: \(assetWriter.error?.localizedDescription ?? "none")")
      }
      return status == .writing
    }

    guard isWriting else {
      assetWriterQueue.sync {
        samplesDroppedAfterFailure += 1
        if samplesDroppedAfterFailure % 100 == 1 {
          debugPrint("⚠️ Dropping sample #\(samplesDroppedAfterFailure) after writer failure")
        }
      }
      return false
    }

    if sampleBufferType == .video {
      assetWriterQueue.sync {
        startSessionIfNeeded(sampleBuffer: sampleBuffer)
      }
    } else {
      // Buffer early audio until video starts instead of dropping
      let hasSessionStart = assetWriterQueue.sync { sessionStartTime != nil }
      if !hasSessionStart {
        return assetWriterQueue.sync {
          bufferEarlyAudio(sampleBuffer, type: sampleBufferType)
        }
      }
    }

    switch sampleBufferType {
    case .video:
      return assetWriterQueue.sync {
        captureVideoOutput(sampleBuffer)
      }
    case .audioApp:
      // App audio goes to separate file only (not embedded in main video)
      return assetWriterQueue.sync {
        let adjustedBuffer = adjustedAudioSampleBufferIfNeeded(
          sampleBuffer,
          audioType: .audioApp
        )
        if separateAudioFile {
          _ = captureAppAudioOutput(adjustedBuffer)
        }
        // Return early - don't write app audio to main video file
        return true
      }
    case .audioMic:
      // Also write to separate mic audio file if enabled
      return assetWriterQueue.sync {
        let adjustedBuffer = adjustedAudioSampleBufferIfNeeded(
          sampleBuffer,
          audioType: .audioMic
        )
        if separateAudioFile {
          _ = captureSeparateAudioOutput(adjustedBuffer)
        }
        return captureMicrophoneOutput(adjustedBuffer)
      }
    @unknown default:
      debugPrint(#file, "Unknown type of sample buffer, \(sampleBufferType)")
      return false
    }
  }

  public func pause() {
    assetWriterQueue.sync {
      guard !isAudioPaused else { return }
      isAudioPaused = true
      audioInterruptionCount += 1
      lastInterruptionTime = Date()
      debugPrint("⏸️ Writer paused (interruption #\(audioInterruptionCount))")
    }
  }

  public func resume() {
    assetWriterQueue.sync {
      guard isAudioPaused else { return }
      isAudioPaused = false
      audioResumeCount += 1

      if let startTime = lastInterruptionTime {
        totalInterruptionDuration += Date().timeIntervalSince(startTime)
      }
      lastInterruptionTime = nil

      // Reset timing offsets (audio PTS may have shifted)
      micTimingOffsetResolved = false
      appAudioTimingOffsetResolved = false

      debugPrint("▶️ Writer resumed (resume #\(audioResumeCount), total interruption: \(String(format: "%.2f", totalInterruptionDuration))s)")
    }
  }

  /// Returns true if the writer has failed
  public var hasFailed: Bool {
    assetWriterQueue.sync { writerFailureDetected }
  }

  /// Returns the failure error if the writer has failed
  public var failureError: Swift.Error? {
    assetWriterQueue.sync { writerFailureError }
  }

  /// Returns diagnostic info about the writer state for debugging
  public func getDiagnostics() -> String {
    return assetWriterQueue.sync {
      var info: [String] = []
      info.append("status=\(assetWriter.status.description)")
      if let error = assetWriter.error {
        info.append("error=\(error.localizedDescription)")
      }
      info.append("sessionStarted=\(assetWriterSessionStarted)")
      info.append("sessionStartTime=\(sessionStartTime?.seconds ?? -1)")
      info.append("lastVideoPTS=\(lastVideoPTS?.seconds ?? -1)")
      info.append("lastVideoEndTime=\(lastVideoEndTime.seconds)")
      info.append("lastMicEndTime=\(lastMicEndTime.seconds)")
      info.append("lastAppAudioEndTime=\(lastAppAudioEndTime.seconds)")
      info.append("videoInputReady=\(videoInput.isReadyForMoreMediaData)")

      // Sample counts
      info.append("totalVideoFrames=\(totalVideoFrames)")
      info.append("totalMicSamples=\(totalMicSamples)")
      info.append("totalSeparateAudioSamples=\(totalSeparateAudioSamples)")
      info.append("totalAppAudioSamples=\(totalAppAudioSamples)")

      // First PTS deltas (audio vs video sync)
      if let firstVideo = firstVideoPTS {
        if let firstMic = firstMicPTS {
          let delta = CMTimeSubtract(firstMic, firstVideo).seconds
          info.append("firstMicDeltaToVideo=\(String(format: "%.3f", delta))s")
        }
        if let firstApp = firstAppAudioPTS {
          let delta = CMTimeSubtract(firstApp, firstVideo).seconds
          info.append("firstAppAudioDeltaToVideo=\(String(format: "%.3f", delta))s")
        }
      }
      if let observedDelta = observedFirstMicDeltaToVideo {
        info.append("observedFirstMicDeltaToVideo=\(String(format: "%.3f", observedDelta))s")
      }
      if let observedDelta = observedFirstAppAudioDeltaToVideo {
        info.append("observedFirstAppAudioDeltaToVideo=\(String(format: "%.3f", observedDelta))s")
      }
      info.append("micTimingOffset=\(String(format: "%.3f", micTimingOffset.seconds))s")
      info.append("appAudioTimingOffset=\(String(format: "%.3f", appAudioTimingOffset.seconds))s")
      info.append(
        "audioLeadCompensation=\(String(format: "%.3f", audioLeadCompensation.seconds))s"
      )
      info.append("audioSessionChangeCount=\(audioSessionChangeCount)")

      // Duration comparison (audio vs video)
      let videoDuration =
        isPositiveTime(lastVideoEndTime) && sessionStartTime != nil
        ? CMTimeSubtract(lastVideoEndTime, sessionStartTime!).seconds : 0
      let micDuration =
        isPositiveTime(lastMicEndTime) && sessionStartTime != nil
        ? CMTimeSubtract(lastMicEndTime, sessionStartTime!).seconds : 0
      let appAudioDuration =
        isPositiveTime(lastAppAudioEndTime) && sessionStartTime != nil
        ? CMTimeSubtract(lastAppAudioEndTime, sessionStartTime!).seconds : 0
      info.append("videoDuration=\(String(format: "%.2f", videoDuration))s")
      info.append("micDuration=\(String(format: "%.2f", micDuration))s")
      info.append("appAudioDuration=\(String(format: "%.2f", appAudioDuration))s")

      // Backpressure metrics (hits/drops)
      info.append("videoBackpressure=\(videoBackpressureHits)/\(videoBackpressureDrops)")
      info.append("micBackpressure=\(micBackpressureHits)/\(micBackpressureDrops)")
      info.append(
        "separateAudioBackpressure=\(separateAudioBackpressureHits)/\(separateAudioBackpressureDrops)"
      )
      info.append("appAudioBackpressure=\(appAudioBackpressureHits)/\(appAudioBackpressureDrops)")

      info.append("lowPowerMode=\(isLowPowerModeEnabled)")
      info.append("audioBackpressureTimeout=\(String(format: "%.3f", audioBackpressureTimeout))s")

      // Drop counts by reason
      info.append("micDroppedBeforeSession=\(micDroppedBeforeSession)")
      info.append("micDroppedPTSBelowStart=\(micDroppedPTSBelowStart)")
      info.append("appAudioDroppedBeforeSession=\(appAudioDroppedBeforeSession)")
      info.append("appAudioDroppedPTSBelowStart=\(appAudioDroppedPTSBelowStart)")

      // Monotonicity violations
      info.append("micMonotonicityViolations=\(micMonotonicityViolations)")
      info.append("appAudioMonotonicityViolations=\(appAudioMonotonicityViolations)")

      // Early buffer metrics
      info.append("earlyBuffersDropped=\(earlyBuffersDropped)")

      // Check output file
      let outputPath = assetWriter.outputURL.path
      let fileExists = FileManager.default.fileExists(atPath: outputPath)
      var fileSize: Int64 = 0
      if fileExists, let attrs = try? FileManager.default.attributesOfItem(atPath: outputPath) {
        fileSize = (attrs[.size] as? Int64) ?? 0
      }
      info.append("outputExists=\(fileExists)")
      info.append("outputSize=\(fileSize)")

      return info.joined(separator: ", ")
    }
  }

  /// Returns audio metrics as a dictionary for structured logging/Sentry
  public func getAudioMetrics() -> [String: Any] {
    return assetWriterQueue.sync {
      var metrics: [String: Any] = [:]

      // Timestamps
      metrics["sessionStartTime"] = sessionStartTime?.seconds ?? -1
      metrics["firstVideoPTS"] = firstVideoPTS?.seconds ?? -1
      metrics["firstMicPTS"] = firstMicPTS?.seconds ?? -1
      metrics["firstAppAudioPTS"] = firstAppAudioPTS?.seconds ?? -1

      // Sample counts
      metrics["totalVideoFrames"] = totalVideoFrames
      metrics["totalMicSamples"] = totalMicSamples
      metrics["totalSeparateAudioSamples"] = totalSeparateAudioSamples
      metrics["totalAppAudioSamples"] = totalAppAudioSamples

      // Durations
      let videoDuration =
        isPositiveTime(lastVideoEndTime) && sessionStartTime != nil
        ? CMTimeSubtract(lastVideoEndTime, sessionStartTime!).seconds : 0
      let micDuration =
        isPositiveTime(lastMicEndTime) && sessionStartTime != nil
        ? CMTimeSubtract(lastMicEndTime, sessionStartTime!).seconds : 0
      let appAudioDuration =
        isPositiveTime(lastAppAudioEndTime) && sessionStartTime != nil
        ? CMTimeSubtract(lastAppAudioEndTime, sessionStartTime!).seconds : 0
      metrics["videoDuration"] = videoDuration
      metrics["micDuration"] = micDuration
      metrics["appAudioDuration"] = appAudioDuration

      // PTS deltas (sync indicators)
      if let firstVideo = firstVideoPTS {
        if let firstMic = firstMicPTS {
          metrics["firstMicDeltaToVideo"] = CMTimeSubtract(firstMic, firstVideo).seconds
        }
        if let firstApp = firstAppAudioPTS {
          metrics["firstAppAudioDeltaToVideo"] = CMTimeSubtract(firstApp, firstVideo).seconds
        }
      }
      if let observedDelta = observedFirstMicDeltaToVideo {
        metrics["observedFirstMicDeltaToVideo"] = observedDelta
      }
      if let observedDelta = observedFirstAppAudioDeltaToVideo {
        metrics["observedFirstAppAudioDeltaToVideo"] = observedDelta
      }
      metrics["micTimingOffset"] = micTimingOffset.seconds
      metrics["appAudioTimingOffset"] = appAudioTimingOffset.seconds
      metrics["audioLeadCompensationSeconds"] = audioLeadCompensation.seconds
      metrics["micAdjustmentApplied"] = micAdjustmentAppliedCount > 0
      metrics["micAdjustmentAppliedCount"] = micAdjustmentAppliedCount
      metrics["micAdjustmentAppliedSeconds"] = micAdjustmentAppliedSeconds
      metrics["appAudioAdjustmentApplied"] = appAudioAdjustmentAppliedCount > 0
      metrics["appAudioAdjustmentAppliedCount"] = appAudioAdjustmentAppliedCount
      metrics["appAudioAdjustmentAppliedSeconds"] = appAudioAdjustmentAppliedSeconds

      // Backpressure
      metrics["videoBackpressureHits"] = videoBackpressureHits
      metrics["videoBackpressureDrops"] = videoBackpressureDrops
      metrics["micBackpressureHits"] = micBackpressureHits
      metrics["micBackpressureDrops"] = micBackpressureDrops
      metrics["separateAudioBackpressureHits"] = separateAudioBackpressureHits
      metrics["separateAudioBackpressureDrops"] = separateAudioBackpressureDrops
      metrics["appAudioBackpressureHits"] = appAudioBackpressureHits
      metrics["appAudioBackpressureDrops"] = appAudioBackpressureDrops

      metrics["lowPowerModeEnabled"] = isLowPowerModeEnabled
      metrics["audioBackpressureTimeout"] = audioBackpressureTimeout

      // Drops by reason
      metrics["micDroppedBeforeSession"] = micDroppedBeforeSession
      metrics["micDroppedPTSBelowStart"] = micDroppedPTSBelowStart
      metrics["appAudioDroppedBeforeSession"] = appAudioDroppedBeforeSession
      metrics["appAudioDroppedPTSBelowStart"] = appAudioDroppedPTSBelowStart
      metrics["earlyBuffersDropped"] = earlyBuffersDropped

      // Monotonicity
      metrics["micMonotonicityViolations"] = micMonotonicityViolations
      metrics["appAudioMonotonicityViolations"] = appAudioMonotonicityViolations

      // Audio gap tracking (privacy interruptions)
      metrics["micGapCount"] = micGapCount
      metrics["appAudioGapCount"] = appAudioGapCount

      // Channel count detection
      metrics["detectedAppAudioChannels"] = detectedAppAudioChannels

      metrics["micPtsMin"] = micPtsMin?.seconds ?? -1
      metrics["micPtsMax"] = micPtsMax?.seconds ?? -1
      metrics["separateMicPtsMin"] = separateMicPtsMin?.seconds ?? -1
      metrics["separateMicPtsMax"] = separateMicPtsMax?.seconds ?? -1
      metrics["appAudioPtsMin"] = appAudioPtsMin?.seconds ?? -1
      metrics["appAudioPtsMax"] = appAudioPtsMax?.seconds ?? -1

      // Writer status
      metrics["writerStatus"] = assetWriter.status.description
      metrics["sessionStarted"] = assetWriterSessionStarted
      metrics["audioSessionChangeCount"] = audioSessionChangeCount

      // Audio Interruption metrics
      metrics["audioInterruptionCount"] = audioInterruptionCount
      metrics["audioResumeCount"] = audioResumeCount
      metrics["totalInterruptionDuration"] = totalInterruptionDuration
      metrics["isAudioPaused"] = isAudioPaused

      // Sample Rate mismatch metrics
      metrics["configuredSampleRate"] = configuredSampleRate
      metrics["sampleRateMismatchDetected"] = sampleRateMismatchDetected
      metrics["sampleRateMismatchCount"] = sampleRateMismatchCount
      metrics["maxSampleRateDrift"] = maxSampleRateDrift

      // Format change metrics
      metrics["micFormatChangeCount"] = micFormatChangeCount
      metrics["appAudioFormatChangeCount"] = appAudioFormatChangeCount

      // Writer failure metrics
      metrics["writerFailureDetected"] = writerFailureDetected
      metrics["samplesDroppedAfterFailure"] = samplesDroppedAfterFailure

      // CMTime precision metrics
      metrics["maxTimescaleMismatch"] = maxTimescaleMismatch

      #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        let route = audioSession.currentRoute
        metrics["audioSessionSampleRate"] = audioSession.sampleRate
        metrics["audioInputLatency"] = audioSession.inputLatency
        metrics["audioOutputLatency"] = audioSession.outputLatency
        metrics["audioIOBufferDuration"] = audioSession.ioBufferDuration
        metrics["audioRouteInputs"] = route.inputs.map {
          "\($0.portType.rawValue):\($0.portName)"
        }
        metrics["audioRouteOutputs"] = route.outputs.map {
          "\($0.portType.rawValue):\($0.portName)"
        }
        if let preferredInput = audioSession.preferredInput {
          metrics["audioPreferredInput"] =
            "\(preferredInput.portType.rawValue):\(preferredInput.portName)"
        }
      #endif

      return metrics
    }
  }

  /// Result containing video and optional separate audio URLs
  public struct FinishResult {
    public let videoURL: URL
    public let audioURL: URL?  // Mic audio file (.pcm raw audio)
    public let appAudioURL: URL?  // App/system audio file (.m4a AAC)
    public let micPcmInfo: PCMFormatInfo?  // PCM format metadata for mic audio
  }

  public func finish() throws -> URL {
    let result = try finishWithAudio()
    return result.videoURL
  }

  /// Returns true if the writer has received at least one video frame
  public var hasReceivedVideoFrames: Bool {
    return assetWriterQueue.sync { assetWriterSessionStarted }
  }

  public func finishWithAudio() throws -> FinishResult {
    return try assetWriterQueue.sync {
      // IMPORTANT: If no video frames were ever received, the session was never started.
      // AVAssetWriter will fail if we try to finish without starting a session.
      // In this case, cancel the writer and throw a specific error.
      guard assetWriterSessionStarted else {
        debugPrint("⚠️ BroadcastWriter: No video frames received, canceling writer")
        assetWriter.cancelWriting()
        // Close PCM file handle and delete if empty
        if let handle = pcmFileHandle {
          try? handle.close()
          pcmFileHandle = nil
          if pcmBytesWritten == 0, let url = audioOutputURL {
            try? FileManager.default.removeItem(at: url)
          }
        }
        appAudioWriter?.cancelWriting()
        throw Error.wrongAssetWriterStatus(.cancelled)
      }

      let group: DispatchGroup = .init()

      // Pad audio files with silenne to match video length
      if isPositiveTime(lastVideoEndTime) {
        padAudioToVideoLength()
      }

      inputs
        .lazy
        .filter { $0.isReadyForMoreMediaData }
        .forEach { $0.markAsFinished() }

      let status = assetWriter.status
      guard status == .writing else {
        throw Error.wrongAssetWriterStatus(status)
      }
      group.enter()

      var error: Swift.Error?
      assetWriter.finishWriting { [weak self] in

        defer {
          group.leave()
        }

        guard let self = self else {
          error = Error.selfDeallocated
          return
        }

        if let e = self.assetWriter.error {
          error = e
          return
        }

        let status = self.assetWriter.status
        guard status == .completed else {
          error = Error.wrongAssetWriterStatus(status)
          return
        }
      }
      group.wait()
      try error.map { throw $0 }

      // Finish PCM mic audio file if enabled
      var audioURL: URL? = nil
      var finalPcmInfo: PCMFormatInfo? = nil
      if separateAudioFile, let handle = pcmFileHandle {
        do {
          try handle.close()
          pcmFileHandle = nil
          
          // Update format info with final bytes written
          if var info = pcmFormatInfo {
            info.bytesWritten = pcmBytesWritten
            finalPcmInfo = info
          }
          
          // Only return URL if we actually wrote bytes
          if pcmBytesWritten > 0 {
            audioURL = audioOutputURL
            audioLog("MIC PCM FINISHED: bytesWritten=\(pcmBytesWritten), duration=\(finalPcmInfo?.duration ?? 0)s")
            
            // Convert PCM to M4A for final output
            if let pcmURL = audioOutputURL, let info = finalPcmInfo {
              let m4aURL = pcmURL.deletingPathExtension().appendingPathExtension("m4a")
              if convertPcmToM4a(pcmURL: pcmURL, m4aURL: m4aURL, format: info) {
                audioURL = m4aURL
                // Delete the PCM file after successful conversion
                try? FileManager.default.removeItem(at: pcmURL)
                audioLog("MIC PCM->M4A CONVERTED: \(m4aURL.lastPathComponent)")
              } else {
                // Conversion failed - keep PCM as fallback
                audioURL = pcmURL
                audioLog("MIC PCM->M4A FAILED: keeping PCM file")
              }
            }
          } else if let url = audioOutputURL {
            // Delete empty file
            try? FileManager.default.removeItem(at: url)
            audioLog("MIC PCM FINISHED: empty file deleted")
          }
        } catch {
          audioLog("MIC PCM CLOSE ERROR: \(error.localizedDescription)")
        }
      }

      // Finish separate app audio writer if enabled
      var appAudioURL: URL? = nil
      if separateAudioFile, let appWriter = appAudioWriter {
        if appAudioInput.isReadyForMoreMediaData {
          appAudioInput.markAsFinished()
        }

        if appWriter.status == .writing {
          let appAudioGroup = DispatchGroup()
          appAudioGroup.enter()

          var appAudioError: Swift.Error?
          appWriter.finishWriting {
            defer { appAudioGroup.leave() }
            if let e = appWriter.error {
              appAudioError = e
              return
            }
            if appWriter.status != .completed {
              appAudioError = Error.wrongAssetWriterStatus(appWriter.status)
            }
          }
          appAudioGroup.wait()

          if appAudioError == nil {
            appAudioURL = appWriter.outputURL
          }
        }
      }

      // Final audio diagnostic dump
      audioLog("=== FINISH AUDIO DIAGNOSTICS ===")
      audioLog("MIC PCM: bytesWritten=\(pcmBytesWritten), received=\(micSamplesReceived), written=\(totalSeparateAudioSamples), appendFails=\(separateAudioAppendFailures)")
      if let info = finalPcmInfo {
        audioLog("MIC PCM FORMAT: rate=\(info.sampleRate), ch=\(info.channelCount), bits=\(info.bitsPerChannel), duration=\(info.duration)s")
      }
      audioLog("APPAUDIO: received=\(appAudioSamplesReceived), written=\(totalAppAudioSamples), appendFails=\(appAudioAppendFailures), drops=\(appAudioDroppedBeforeSession + appAudioDroppedPTSBelowStart + appAudioBackpressureDrops)")
      audioLog("APPAUDIO WRITER: status=\(appAudioWriter?.status.description ?? "nil"), error=\(appAudioWriter?.error?.localizedDescription ?? "none"), sessionStarted=\(appAudioAssetWriterSessionStarted)")
      audioLog("TIMING: sessionStart=\(sessionStartTime?.seconds ?? -1), firstMicPTS=\(firstMicPTS?.seconds ?? -1), firstAppAudioPTS=\(firstAppAudioPTS?.seconds ?? -1)")
      audioLog("FORMAT: lastMic=\(lastMicFormat ?? "none"), lastAppAudio=\(lastAppAudioFormat ?? "none"), micChanges=\(micFormatChanges), appAudioChanges=\(appAudioFormatChanges)")
      audioLog("GAPS: mic=\(micGapCount), appAudio=\(appAudioGapCount), audioSessionChanges=\(audioSessionChangeCount)")
      if let lastMicErr = lastSeparateAudioAppendError {
        audioLog("LAST MIC ERROR: \(lastMicErr)")
      }
      if let lastAppErr = lastAppAudioAppendError {
        audioLog("LAST APPAUDIO ERROR: \(lastAppErr)")
      }
      audioLog("=== END AUDIO DIAGNOSTICS ===")

      return FinishResult(
        videoURL: assetWriter.outputURL, audioURL: audioURL, appAudioURL: appAudioURL, micPcmInfo: finalPcmInfo)
    }
  }
}

extension BroadcastWriter {

  /// Buffers early audio samples that arrive before video starts
  fileprivate func bufferEarlyAudio(_ sampleBuffer: CMSampleBuffer, type: RPSampleBufferType)
    -> Bool
  {
    // Retain the sample buffer for later use
    if type == .audioMic {
      if earlyMicBuffers.count < maxEarlyBufferCount {
        earlyMicBuffers.append(sampleBuffer)
        debugPrint("📦 Buffered early mic audio (\(earlyMicBuffers.count) samples)")
        return true
      } else {
        earlyBuffersDropped += 1
        debugPrint(
          "⚠️ Early mic buffer full, dropping audio sample (dropped: \(earlyBuffersDropped))")
        return false
      }
    } else if type == .audioApp {
      if earlyAppAudioBuffers.count < maxEarlyBufferCount {
        earlyAppAudioBuffers.append(sampleBuffer)
        debugPrint("📦 Buffered early app audio (\(earlyAppAudioBuffers.count) samples)")
        return true
      } else {
        earlyBuffersDropped += 1
        debugPrint(
          "⚠️ Early app buffer full, dropping audio sample (dropped: \(earlyBuffersDropped))")
        return false
      }
    }
    return false
  }

  /// Flushes buffered early audio after video session starts
  fileprivate func flushEarlyAudioBuffers() {
    guard let startTime = sessionStartTime else { return }

    // Small tolerance: allow audio up to 50ms before video start (tighter sync)
    let tolerance = CMTime(value: 50, timescale: 1000)  // 50ms
    let adjustedStartTime = CMTimeSubtract(startTime, tolerance)

    // Flush mic audio buffers
    let micCount = earlyMicBuffers.count
    var micFlushed = 0
    var micDropped = 0
    for buffer in earlyMicBuffers {
      let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
      // Only flush if PTS is within tolerance of session start
      if CMTimeCompare(pts, adjustedStartTime) >= 0 {
        let adjusted = adjustedAudioSampleBufferIfNeeded(buffer, audioType: .audioMic)
        if captureMicrophoneOutput(adjusted) {
          micFlushed += 1
        }
        if separateAudioFile {
          _ = captureSeparateAudioOutput(adjusted)
        }
      } else {
        micDropped += 1
      }
    }
    if micCount > 0 {
      debugPrint(
        "📦 Flushed \(micFlushed)/\(micCount) early mic buffers (dropped \(micDropped) too early)")
    }
    earlyMicBuffers.removeAll()

    // Flush app audio buffers
    let appCount = earlyAppAudioBuffers.count
    var appFlushed = 0
    var appDropped = 0
    for buffer in earlyAppAudioBuffers {
      let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
      if CMTimeCompare(pts, adjustedStartTime) >= 0 {
        if separateAudioFile {
          let adjusted = adjustedAudioSampleBufferIfNeeded(buffer, audioType: .audioApp)
          if captureAppAudioOutput(adjusted) {
            appFlushed += 1
          }
        }
      } else {
        appDropped += 1
      }
    }
    if appCount > 0 {
      debugPrint(
        "📦 Flushed \(appFlushed)/\(appCount) early app audio buffers (dropped \(appDropped) too early)"
      )
    }
    earlyAppAudioBuffers.removeAll()

    if earlyBuffersDropped > 0 {
      debugPrint("⚠️ Total early audio buffers dropped due to full buffer: \(earlyBuffersDropped)")
    }
  }

  fileprivate func startSessionIfNeeded(sampleBuffer: CMSampleBuffer) {
    guard !assetWriterSessionStarted else {
      return
    }

    let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

    // VIDEO IS THE ANCHOR - never adjust for early audio
    // Using audio timestamps as anchor causes gradual A/V desync
    sessionStartTime = sourceTime
    assetWriter.startSession(atSourceTime: sourceTime)
    assetWriterSessionStarted = true
    if firstVideoPTS == nil {
      firstVideoPTS = sourceTime
      debugPrint("📊 First video PTS: \(sourceTime.seconds)s")
    }
    debugPrint("🎬 Session started at video PTS: \(sourceTime.seconds)s")

    // Flush buffered early audio now that session has started
    flushEarlyAudioBuffers()
  }

  // Note: startAudioSessionIfNeeded removed - PCM doesn't use AVAssetWriter sessions

  fileprivate func startAppAudioSessionIfNeeded() {
    guard !appAudioAssetWriterSessionStarted, let appWriter = appAudioWriter,
      appWriter.status == .writing
    else {
      return
    }

    // Always use the shared session start time for audio/video sync
    guard let startTime = sessionStartTime else {
      return
    }
    appWriter.startSession(atSourceTime: startTime)
    appAudioAssetWriterSessionStarted = true
  }

  fileprivate func captureVideoOutput(_ sampleBuffer: CMSampleBuffer) -> Bool {
    if !videoInput.isReadyForMoreMediaData {
      videoBackpressureHits += 1
      // Brief wait for video - critical for sync
      if !waitForInputReady(videoInput, timeout: 0.05) {
        videoBackpressureDrops += 1
        debugPrint(
          "⚠️ videoInput backpressure drop (hits: \(videoBackpressureHits), drops: \(videoBackpressureDrops))"
        )
        return false
      }
    }
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

    // Track first video PTS for sync analysis
    if firstVideoPTS == nil {
      firstVideoPTS = pts
      debugPrint("📊 First video PTS: \(pts.seconds)s")
    }

    var frameDuration = CMSampleBufferGetDuration(sampleBuffer)
    // Trust buffer duration or use last known good duration
    // Do NOT calculate from PTS delta (accumulates errors over time)
    if !isPositiveTime(frameDuration) {
      frameDuration =
        isPositiveTime(lastVideoFrameDuration)
        ? lastVideoFrameDuration
        : CMTime(value: 1, timescale: 30)  // Conservative 30fps default
    }
    let endTime = isPositiveTime(frameDuration) ? CMTimeAdd(pts, frameDuration) : pts
    let appended = videoInput.append(sampleBuffer)
    if appended {
      totalVideoFrames += 1
      // Only update from buffer-provided duration, not calculated
      let bufferDuration = CMSampleBufferGetDuration(sampleBuffer)
      if isPositiveTime(bufferDuration) {
        lastVideoFrameDuration = bufferDuration
      }
      lastVideoPTS = pts
      if CMTimeCompare(endTime, lastVideoEndTime) > 0 {
        lastVideoEndTime = endTime
      }
    }
    return appended
  }

  fileprivate func captureAudioOutput(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard audioInput.isReadyForMoreMediaData else {
      debugPrint("audioInput is not ready")
      return false
    }
    return audioInput.append(sampleBuffer)
  }

  fileprivate func captureMicrophoneOutput(_ sampleBuffer: CMSampleBuffer) -> Bool {
    // Skip audio during pause (interruption handling)
    if isAudioPaused { return false }

    // Validate sample rate for mismatch detection
    validateIncomingSampleRate(sampleBuffer, label: "mic")

    // Validate and track format changes
    if !validateAndTrackFormat(sampleBuffer, lastFormat: &lastMicFormatDescription,
                               changeCount: &micFormatChangeCount, label: "Mic") {
      return false
    }

    if !microphoneInput.isReadyForMoreMediaData {
      micBackpressureHits += 1
      // Brief wait for audio - avoid blocking too long
      if !waitForInputReady(microphoneInput, timeout: audioBackpressureTimeout) {
        micBackpressureDrops += 1
        debugPrint(
          "⚠️ microphoneInput backpressure drop (hits: \(micBackpressureHits), drops: \(micBackpressureDrops))"
        )
        return false
      }
    }
    guard let startTime = sessionStartTime else {
      micDroppedBeforeSession += 1
      debugPrint(
        "⚠️ Mic audio before video session start; dropping. (count: \(micDroppedBeforeSession))")
      return false
    }

    // Track audio buffer gaps (for detecting privacy interruptions)
    let now = Date()
    if let lastTime = lastMicBufferTime {
      let gap = now.timeIntervalSince(lastTime)
      if gap > 0.5 {  // 500ms gap threshold
        micGapCount += 1
        debugPrint("⚠️ Mic audio gap detected: \(Int(gap * 1000))ms (gap #\(micGapCount))")
      }
    }
    lastMicBufferTime = now

    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

    // Track first mic PTS and monotonicity
    if firstMicPTS == nil {
      firstMicPTS = pts
      let deltaToVideo = firstVideoPTS != nil ? CMTimeSubtract(pts, firstVideoPTS!).seconds : 0
      debugPrint("📊 First mic PTS: \(pts.seconds)s (delta to video: \(deltaToVideo)s)")
    }
    if let prevPTS = lastMicPTS, CMTimeCompare(pts, prevPTS) < 0 {
      micMonotonicityViolations += 1
      debugPrint(
        "⚠️ Mic PTS monotonicity violation: \(pts.seconds)s < \(prevPTS.seconds)s (count: \(micMonotonicityViolations))"
      )
    }
    lastMicPTS = pts

    // Allow small tolerance (100ms) for audio slightly before session start
    let tolerance = CMTime(value: 1, timescale: 10)
    let adjustedStartTime = CMTimeSubtract(startTime, tolerance)
    if CMTimeCompare(pts, adjustedStartTime) < 0 {
      micDroppedPTSBelowStart += 1
      debugPrint(
        "⚠️ Mic audio timestamp \(pts.seconds)s precedes adjusted start \(adjustedStartTime.seconds)s; dropping. (count: \(micDroppedPTSBelowStart))"
      )
      return false
    }
    let appended = microphoneInput.append(sampleBuffer)
    if appended {
      totalMicSamples += 1
      updatePtsRange(pts, min: &micPtsMin, max: &micPtsMax)
    }
    return appended
  }

  fileprivate func captureSeparateAudioOutput(_ sampleBuffer: CMSampleBuffer) -> Bool {
    // Track every sample received
    micSamplesReceived += 1
    let currentFormat = formatDescription(sampleBuffer)
    
    // Log format changes
    if lastMicFormat == nil {
      lastMicFormat = currentFormat
      audioLog("MIC PCM FIRST SAMPLE: \(currentFormat), received=#\(micSamplesReceived)")
    } else if lastMicFormat != currentFormat {
      micFormatChanges += 1
      // Track format change offset for recovery
      pcmFormatChangeOffsets.append((offset: pcmBytesWritten, format: currentFormat))
      audioLog("MIC PCM FORMAT CHANGED at byte \(pcmBytesWritten): was=\(lastMicFormat ?? "nil"), now=\(currentFormat), changes=#\(micFormatChanges)")
      lastMicFormat = currentFormat
    }
    
    // Log every 100th sample for ongoing tracking
    if micSamplesReceived % 100 == 0 {
      audioLog("MIC PCM SAMPLE #\(micSamplesReceived): \(currentFormat), bytesWritten=\(pcmBytesWritten), failures=\(separateAudioAppendFailures)")
    }
    
    guard separateAudioFile, let handle = pcmFileHandle else {
      audioLog("MIC PCM REJECTED: separateAudioFile=\(separateAudioFile), handle=\(pcmFileHandle != nil)")
      return false
    }

    guard let startTime = sessionStartTime else {
      audioLog("MIC PCM REJECTED: no sessionStartTime yet (video not started)")
      return false
    }

    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    // Allow tolerance (250ms) for audio slightly before session start
    let tolerance = CMTime(value: 250, timescale: 1000)  // 250ms
    let adjustedStartTime = CMTimeSubtract(startTime, tolerance)
    if CMTimeCompare(pts, adjustedStartTime) < 0 {
      audioLog("MIC PCM REJECTED: PTS \(pts.seconds)s < adjusted start \(adjustedStartTime.seconds)s")
      return false
    }

    // Extract and lock PCM format info on first valid sample
    if pcmFormatInfo == nil {
      guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
        audioLog("MIC PCM REJECTED: no format description")
        return false
      }
      
      let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
      let isInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
      
      pcmFormatInfo = PCMFormatInfo(
        sampleRate: asbd.mSampleRate,
        channelCount: Int(asbd.mChannelsPerFrame),
        bitsPerChannel: Int(asbd.mBitsPerChannel),
        isFloat: isFloat,
        isInterleaved: isInterleaved
      )
      pcmFormatLocked = true
      audioLog("MIC PCM FORMAT LOCKED: rate=\(asbd.mSampleRate), ch=\(asbd.mChannelsPerFrame), bits=\(asbd.mBitsPerChannel), float=\(isFloat), interleaved=\(isInterleaved)")
    }

    // Track format for padding
    if micAudioFormatDescription == nil {
      micAudioFormatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
      audioLog("MIC FORMAT DESC SET: \(currentFormat)")
    }
    let duration = audioSampleDuration(sampleBuffer, formatDescription: micAudioFormatDescription)
    let endTime = isPositiveTime(duration) ? CMTimeAdd(pts, duration) : pts

    // Extract raw PCM bytes from sample buffer
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
      separateAudioAppendFailures += 1
      lastSeparateAudioAppendError = "no_block_buffer"
      audioLog("MIC PCM APPEND FAILED #\(separateAudioAppendFailures): no block buffer")
      return false
    }
    
    var length = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
    
    guard status == kCMBlockBufferNoErr, let ptr = dataPointer, length > 0 else {
      separateAudioAppendFailures += 1
      lastSeparateAudioAppendError = "block_buffer_error_\(status)"
      audioLog("MIC PCM APPEND FAILED #\(separateAudioAppendFailures): block buffer error \(status)")
      return false
    }
    
    // Write raw PCM bytes to file
    let data = Data(bytes: ptr, count: length)
    do {
      try handle.write(contentsOf: data)
      pcmBytesWritten += Int64(length)
      totalSeparateAudioSamples += 1
      updatePtsRange(pts, min: &separateMicPtsMin, max: &separateMicPtsMax)
      if CMTimeCompare(endTime, lastMicEndTime) > 0 {
        lastMicEndTime = endTime
      }
      return true
    } catch {
      separateAudioAppendFailures += 1
      lastSeparateAudioAppendError = "write_error_\(error.localizedDescription)"
      audioLog("MIC PCM WRITE FAILED #\(separateAudioAppendFailures): \(error.localizedDescription)")
      return false
    }
  }

  fileprivate func captureAppAudioOutput(_ sampleBuffer: CMSampleBuffer) -> Bool {
    // Skip audio during pause (interruption handling)
    if isAudioPaused { return false }

    guard separateAudioFile, let appWriter = appAudioWriter else {
      return false
    }

    // Check if app audio writer is still writing
    guard appWriter.status == .writing else {
      debugPrint("appAudioWriter is not writing, status: \(appWriter.status.description)")
      return false
    }

    // Validate sample rate for mismatch detection
    validateIncomingSampleRate(sampleBuffer, label: "appAudio")

    // Validate and track format changes
    if !validateAndTrackFormat(sampleBuffer, lastFormat: &lastAppAudioFormatDescription,
                               changeCount: &appAudioFormatChangeCount, label: "AppAudio") {
      return false
    }

    guard let startTime = sessionStartTime else {
      appAudioDroppedBeforeSession += 1
      debugPrint(
        "⚠️ App audio before video session start; dropping. (count: \(appAudioDroppedBeforeSession))"
      )
      return false
    }

    // Track audio buffer gaps (for detecting privacy interruptions)
    let now = Date()
    if let lastTime = lastAppAudioBufferTime {
      let gap = now.timeIntervalSince(lastTime)
      if gap > 0.5 {  // 500ms gap threshold
        appAudioGapCount += 1
        debugPrint("⚠️ App audio gap detected: \(Int(gap * 1000))ms (gap #\(appAudioGapCount))")
      }
    }
    lastAppAudioBufferTime = now

    // Start session if needed
    startAppAudioSessionIfNeeded()

    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

    // Track first app audio PTS and monotonicity
    if firstAppAudioPTS == nil {
      firstAppAudioPTS = pts
      let deltaToVideo = firstVideoPTS != nil ? CMTimeSubtract(pts, firstVideoPTS!).seconds : 0
      debugPrint("📊 First app audio PTS: \(pts.seconds)s (delta to video: \(deltaToVideo)s)")
    }
    if let prevPTS = lastAppAudioPTS, CMTimeCompare(pts, prevPTS) < 0 {
      appAudioMonotonicityViolations += 1
      debugPrint(
        "⚠️ App audio PTS monotonicity violation: \(pts.seconds)s < \(prevPTS.seconds)s (count: \(appAudioMonotonicityViolations))"
      )
    }
    lastAppAudioPTS = pts

    // Allow small tolerance (100ms) for audio slightly before session start
    let tolerance = CMTime(value: 1, timescale: 10)
    let adjustedStartTime = CMTimeSubtract(startTime, tolerance)
    if CMTimeCompare(pts, adjustedStartTime) < 0 {
      appAudioDroppedPTSBelowStart += 1
      debugPrint(
        "⚠️ App audio timestamp \(pts.seconds)s precedes adjusted start \(adjustedStartTime.seconds)s; dropping. (count: \(appAudioDroppedPTSBelowStart))"
      )
      return false
    }

    // Track format for padding
    if appAudioFormatDescription == nil {
      appAudioFormatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
    }
    let duration = audioSampleDuration(sampleBuffer, formatDescription: appAudioFormatDescription)
    let endTime = isPositiveTime(duration) ? CMTimeAdd(pts, duration) : pts

    if !appAudioInput.isReadyForMoreMediaData {
      appAudioBackpressureHits += 1
      // Brief wait for app audio
      if !waitForInputReady(appAudioInput, timeout: audioBackpressureTimeout) {
        appAudioBackpressureDrops += 1
        debugPrint(
          "⚠️ appAudioInput backpressure drop (hits: \(appAudioBackpressureHits), drops: \(appAudioBackpressureDrops))"
        )
        return false
      }
    }

    // Track every app audio sample received
    appAudioSamplesReceived += 1
    let currentFormat = formatDescription(sampleBuffer)
    
    // Log format changes
    if lastAppAudioFormat == nil {
      lastAppAudioFormat = currentFormat
      audioLog("APPAUDIO FIRST SAMPLE: \(currentFormat), received=#\(appAudioSamplesReceived)")
    } else if lastAppAudioFormat != currentFormat {
      appAudioFormatChanges += 1
      audioLog("APPAUDIO FORMAT CHANGED: was=\(lastAppAudioFormat ?? "nil"), now=\(currentFormat), changes=#\(appAudioFormatChanges)")
      lastAppAudioFormat = currentFormat
    }
    
    // Log every 100th sample
    if appAudioSamplesReceived % 100 == 0 {
      audioLog("APPAUDIO SAMPLE #\(appAudioSamplesReceived): \(currentFormat), written=\(totalAppAudioSamples), failures=\(appAudioAppendFailures)")
    }

    // Downmix stereo to mono if needed (app audio is often stereo, but input is configured for mono)
    let bufferToAppend = downmixToMonoIfNeeded(sampleBuffer)
    let appended = appAudioInput.append(bufferToAppend)
    if appended {
      totalAppAudioSamples += 1
      updatePtsRange(pts, min: &appAudioPtsMin, max: &appAudioPtsMax)
      if CMTimeCompare(endTime, lastAppAudioEndTime) > 0 {
        lastAppAudioEndTime = endTime
      }
    } else {
      // APPEND FAILED - critical!
      appAudioAppendFailures += 1
      let writerError = appWriter.error?.localizedDescription ?? "none"
      let inputReady = appAudioInput.isReadyForMoreMediaData
      lastAppAudioAppendError = "append_failed_writerErr=\(writerError)_ready=\(inputReady)"
      audioLog("APPAUDIO APPEND FAILED #\(appAudioAppendFailures): writerError=\(writerError), inputReady=\(inputReady), writerStatus=\(appWriter.status.description), format=\(currentFormat)")
    }
    return appended
  }

  // MARK: - Audio Padding

  /// Pads audio files with silence to match video length
  fileprivate func padAudioToVideoLength() {
    let videoEndTime = lastVideoEndTime
    guard isPositiveTime(videoEndTime), let sessionStartTime = sessionStartTime else {
      debugPrint("📐 Padding skipped: missing video end time or session start time")
      return
    }
    debugPrint("📐 Video end time: \(videoEndTime.seconds)s")

    // Pad mic PCM audio if it's shorter than video
    if separateAudioFile, let handle = pcmFileHandle, let info = pcmFormatInfo {
      let micStartTime = isPositiveTime(lastMicEndTime) ? lastMicEndTime : sessionStartTime
      if CMTimeCompare(micStartTime, videoEndTime) < 0 {
        let silenceDuration = CMTimeSubtract(videoEndTime, micStartTime)
        let silenceSeconds = silenceDuration.seconds
        let silenceBytes = Int(silenceSeconds * info.sampleRate) * info.bytesPerFrame
        
        if silenceBytes > 0 {
          debugPrint("📐 Padding mic PCM audio with \(silenceSeconds)s of silence (\(silenceBytes) bytes)")
          let silenceData = Data(count: silenceBytes)  // Zero-filled = silence
          do {
            try handle.write(contentsOf: silenceData)
            pcmBytesWritten += Int64(silenceBytes)
            audioLog("MIC PCM PADDED: \(silenceBytes) bytes of silence")
          } catch {
            audioLog("MIC PCM PAD ERROR: \(error.localizedDescription)")
          }
        }
      } else {
        debugPrint("📐 Mic PCM audio already matches/exceeds video length; no padding needed")
      }
    } else {
      debugPrint("📐 Mic PCM audio padding skipped: no file handle or format info")
    }

    // Pad app audio if it's shorter than video
    if separateAudioFile, let appWriter = appAudioWriter, appWriter.status == .writing {
      if !appAudioAssetWriterSessionStarted {
        appWriter.startSession(atSourceTime: sessionStartTime)
        appAudioAssetWriterSessionStarted = true
      }
      let appStartTime =
        isPositiveTime(lastAppAudioEndTime) ? lastAppAudioEndTime : sessionStartTime
      if CMTimeCompare(appStartTime, videoEndTime) < 0 {
        let silenceDuration = CMTimeSubtract(videoEndTime, appStartTime)
        debugPrint("📐 Padding app audio with \(silenceDuration.seconds)s of silence")
        appendSilence(
          to: appAudioInput,
          from: appStartTime,
          duration: silenceDuration,
          formatDescription: appAudioFormatDescription ?? defaultAudioFormatDescription
        )
      } else {
        debugPrint("📐 App audio already matches/exceeds video length; no padding needed")
      }
    } else {
      debugPrint("📐 App audio padding skipped: no app writer or not writing")
    }
  }

  /// Appends silent audio samples to an input
  fileprivate func appendSilence(
    to input: AVAssetWriterInput,
    from startTime: CMTime,
    duration: CMTime,
    formatDescription: CMFormatDescription?
  ) {
    guard isPositiveTime(duration) else {
      return
    }
    let formatDesc = formatDescription ?? defaultAudioFormatDescription
    guard let formatDesc else {
      debugPrint("⚠️ Cannot pad audio: no format description available")
      return
    }

    // Get audio format details
    guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
      debugPrint("⚠️ Cannot pad audio: unable to get audio stream description")
      return
    }

    let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : audioSampleRate
    let channelCount = max(Int(asbd.mChannelsPerFrame), 1)
    let bitsPerChannel = asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : 16
    let bytesPerSample = max(bitsPerChannel / 8, 1)
    let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    let bytesPerFrame: Int = {
      if asbd.mBytesPerFrame > 0 {
        return Int(asbd.mBytesPerFrame)
      }
      let channelsForFrame = isNonInterleaved ? 1 : channelCount
      return bytesPerSample * channelsForFrame
    }()

    let timeScale = CMTimeScale(sampleRate)
    guard timeScale > 0 else {
      debugPrint("⚠️ Cannot pad audio: invalid sample rate \(sampleRate)")
      return
    }

    // Calculate samples needed (generate in chunks to avoid huge allocations)
    let samplesNeededTime = CMTimeConvertScale(
      duration, timescale: timeScale, method: .roundHalfAwayFromZero)
    var samplesRemaining = Int(samplesNeededTime.value)
    guard samplesRemaining > 0 else {
      return
    }

    let samplesPerChunk = 1024
    let totalSamplesNeeded = samplesRemaining

    // Convert start time to the target timescale for absolute time calculation
    let startTimeInTargetScale = CMTimeConvertScale(startTime, timescale: timeScale, method: .roundHalfAwayFromZero)

    // Track timescale mismatch for diagnostics
    if startTime.timescale != timeScale {
      let mismatch = abs(Int32(startTime.timescale) - timeScale)
      if mismatch > maxTimescaleMismatch {
        maxTimescaleMismatch = mismatch
      }
    }

    while samplesRemaining > 0 {
      guard waitForInputReady(input, timeout: 0.5) else {
        debugPrint("⚠️ Input not ready while padding audio; remaining samples: \(samplesRemaining)")
        break
      }

      let samplesToWrite = min(samplesRemaining, samplesPerChunk)
      let bufferSize = samplesToWrite * bytesPerFrame
      let bufferCount = isNonInterleaved ? channelCount : 1

      // Allocate AudioBufferList
      let audioBufferList = AudioBufferList.allocate(maximumBuffers: bufferCount)
      audioBufferList.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(bufferCount)

      var bufferPointers: [UnsafeMutableRawPointer] = []
      bufferPointers.reserveCapacity(bufferCount)

      for i in 0..<bufferCount {
        guard let silentData = calloc(bufferSize, 1) else {
          break
        }
        bufferPointers.append(silentData)

        audioBufferList[i].mNumberChannels = isNonInterleaved ? 1 : UInt32(channelCount)
        audioBufferList[i].mDataByteSize = UInt32(bufferSize)
        audioBufferList[i].mData = silentData
      }
      defer {
        bufferPointers.forEach { free($0) }
        audioBufferList.unsafeMutablePointer.deallocate()
      }

      if bufferPointers.count != bufferCount {
        debugPrint("⚠️ Failed to allocate silent audio buffers")
        break
      }

      // Use absolute time calculation to avoid cumulative rounding errors
      let samplesWritten = totalSamplesNeeded - samplesRemaining
      let currentTime = CMTime(value: startTimeInTargetScale.value + CMTimeValue(samplesWritten), timescale: timeScale)

      // Create CMSampleBuffer
      var sampleBuffer: CMSampleBuffer?
      var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: timeScale),
        presentationTimeStamp: currentTime,
        decodeTimeStamp: .invalid
      )

      let status = CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: nil,
        dataReady: false,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: formatDesc,
        sampleCount: samplesToWrite,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sampleBuffer
      )

      guard status == noErr, let buffer = sampleBuffer else {
        debugPrint("⚠️ Failed to create silent sample buffer: \(status)")
        break
      }

      // Set audio buffer data
      let setStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
        buffer,
        blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: 0,
        bufferList: audioBufferList.unsafePointer
      )

      guard setStatus == noErr else {
        debugPrint("⚠️ Failed to set audio buffer data: \(setStatus)")
        break
      }

      // Append to writer
      if !input.append(buffer) {
        debugPrint("⚠️ Failed to append silent audio buffer")
        break
      }

      samplesRemaining -= samplesToWrite
    }

    debugPrint("📐 Finished padding audio, remaining samples: \(samplesRemaining)")
  }

  // MARK: - Helpers

  fileprivate func isPositiveTime(_ time: CMTime) -> Bool {
    time.isValid && !time.isIndefinite && CMTimeCompare(time, .zero) > 0
  }

  fileprivate func updatePtsRange(
    _ pts: CMTime,
    min: inout CMTime?,
    max: inout CMTime?
  ) {
    guard pts.isValid, !pts.isIndefinite else { return }
    if let currentMin = min {
      if CMTimeCompare(pts, currentMin) < 0 {
        min = pts
      }
    } else {
      min = pts
    }
    if let currentMax = max {
      if CMTimeCompare(pts, currentMax) > 0 {
        max = pts
      }
    } else {
      max = pts
    }
  }

  fileprivate func audioSampleDuration(
    _ sampleBuffer: CMSampleBuffer,
    formatDescription: CMFormatDescription?
  ) -> CMTime {
    let duration = CMSampleBufferGetDuration(sampleBuffer)
    if isPositiveTime(duration) {
      return duration
    }

    if let formatDescription,
      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
    {
      let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : audioSampleRate
      if sampleRate > 0 {
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let timeScale = CMTimeScale(sampleRate)
        if timeScale > 0 {
          return CMTime(value: CMTimeValue(sampleCount), timescale: timeScale)
        }
      }
    }
    return .zero
  }

  #if os(iOS)
    fileprivate func audioRouteSignature(_ route: AVAudioSessionRouteDescription) -> String {
      let inputs = route.inputs.map {
        "\($0.portType.rawValue):\($0.portName)"
      }.joined(separator: ",")
      let outputs = route.outputs.map {
        "\($0.portType.rawValue):\($0.portName)"
      }.joined(separator: ",")
      return "in[\(inputs)]|out[\(outputs)]"
    }

    fileprivate func refreshAudioSessionStateIfNeeded() {
      let now = Date()
      if now.timeIntervalSince(lastAudioSessionCheckTime) < audioSessionCheckInterval {
        return
      }
      lastAudioSessionCheckTime = now

      let session = AVAudioSession.sharedInstance()
      let routeSignature = audioRouteSignature(session.currentRoute)
      let sampleRate = session.sampleRate
      let ioBufferDuration = session.ioBufferDuration

      if lastAudioRouteSignature == nil {
        lastAudioRouteSignature = routeSignature
        lastAudioSampleRate = sampleRate
        lastAudioIOBufferDuration = ioBufferDuration
        return
      }

      let routeChanged = routeSignature != lastAudioRouteSignature
      let sampleRateChanged = abs(sampleRate - lastAudioSampleRate) > 1
      let ioBufferChanged = abs(ioBufferDuration - lastAudioIOBufferDuration) > 0.001

      if routeChanged || sampleRateChanged || ioBufferChanged {
        audioSessionChangeCount += 1
        lastAudioRouteSignature = routeSignature
        lastAudioSampleRate = sampleRate
        lastAudioIOBufferDuration = ioBufferDuration

        micTimingOffsetResolved = false
        appAudioTimingOffsetResolved = false
        micTimingOffset = .zero
        appAudioTimingOffset = .zero
        observedFirstMicDeltaToVideo = nil
        observedFirstAppAudioDeltaToVideo = nil

        debugPrint(
          "🔄 Audio session changed; resetting timing offsets (route=\(routeSignature), rate=\(String(format: "%.0f", sampleRate)))"
        )
      }
    }
  #endif

  fileprivate func resolveTimingOffsetIfNeeded(
    currentPTS: CMTime,
    firstVideoPTS: CMTime,
    resolved: inout Bool,
    offset: inout CMTime,
    observedDelta: inout Double?,
    label: String
  ) {
    if observedDelta == nil {
      observedDelta = CMTimeSubtract(currentPTS, firstVideoPTS).seconds
    }

    guard !resolved else { return }

    let delta = CMTimeSubtract(currentPTS, firstVideoPTS)
    if delta.isValid, !delta.isIndefinite {
      let deltaSeconds = delta.seconds
      let absDeltaSeconds = abs(deltaSeconds)
      let thresholdSeconds = timingOffsetThreshold.seconds
      let maxSeconds = timingOffsetMax.seconds

      if absDeltaSeconds > thresholdSeconds {
        if absDeltaSeconds >= maxSeconds {
          debugPrint(
            "⏱️ Skipping \(label) timing offset: \(String(format: "%.3f", deltaSeconds))s exceeds max \(String(format: "%.3f", maxSeconds))s"
          )
        } else {
          offset = delta
          debugPrint(
            "⏱️ Applying \(label) timing offset: \(String(format: "%.3f", deltaSeconds))s"
          )
        }
      }
    }
    resolved = true
  }

  fileprivate func adjustedAudioSampleBufferIfNeeded(
    _ sampleBuffer: CMSampleBuffer,
    audioType: RPSampleBufferType
  ) -> CMSampleBuffer {
    #if os(iOS)
      refreshAudioSessionStateIfNeeded()
    #endif
    guard audioType == .audioMic || audioType == .audioApp else {
      return sampleBuffer
    }
    guard let firstVideo = firstVideoPTS else {
      return sampleBuffer
    }

    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

    switch audioType {
    case .audioMic:
      resolveTimingOffsetIfNeeded(
        currentPTS: pts,
        firstVideoPTS: firstVideo,
        resolved: &micTimingOffsetResolved,
        offset: &micTimingOffset,
        observedDelta: &observedFirstMicDeltaToVideo,
        label: "mic"
      )
      guard micTimingOffsetResolved else { return sampleBuffer }
      let baseOffset = CMTimeMultiply(micTimingOffset, multiplier: -1)
      let applyLeadCompensation = micTimingOffset.seconds < 0
      let offset =
        applyLeadCompensation
        ? CMTimeAdd(baseOffset, audioLeadCompensation)
        : baseOffset
      guard CMTimeCompare(offset, .zero) != 0 else { return sampleBuffer }
      if let adjusted = sampleBufferByApplyingTimeOffset(
        sampleBuffer,
        offset: offset,
        minPTS: sessionStartTime
      ) {
        micAdjustmentAppliedCount += 1
        micAdjustmentAppliedSeconds = offset.seconds
        return adjusted
      }
      return sampleBuffer
    case .audioApp:
      resolveTimingOffsetIfNeeded(
        currentPTS: pts,
        firstVideoPTS: firstVideo,
        resolved: &appAudioTimingOffsetResolved,
        offset: &appAudioTimingOffset,
        observedDelta: &observedFirstAppAudioDeltaToVideo,
        label: "app audio"
      )
      guard appAudioTimingOffsetResolved else { return sampleBuffer }
      let baseOffset = CMTimeMultiply(appAudioTimingOffset, multiplier: -1)
      let applyLeadCompensation = appAudioTimingOffset.seconds < 0
      let offset =
        applyLeadCompensation
        ? CMTimeAdd(baseOffset, audioLeadCompensation)
        : baseOffset
      guard CMTimeCompare(offset, .zero) != 0 else { return sampleBuffer }
      if let adjusted = sampleBufferByApplyingTimeOffset(
        sampleBuffer,
        offset: offset,
        minPTS: sessionStartTime
      ) {
        appAudioAdjustmentAppliedCount += 1
        appAudioAdjustmentAppliedSeconds = offset.seconds
        return adjusted
      }
      return sampleBuffer
    default:
      return sampleBuffer
    }
  }

  fileprivate func sampleBufferByApplyingTimeOffset(
    _ sampleBuffer: CMSampleBuffer,
    offset: CMTime,
    minPTS: CMTime?
  ) -> CMSampleBuffer? {
    let entryCount = CMSampleBufferGetNumSamples(sampleBuffer)
    guard entryCount > 0 else {
      return nil
    }

    var timingInfo = Array(
      repeating: CMSampleTimingInfo(
        duration: .invalid,
        presentationTimeStamp: .invalid,
        decodeTimeStamp: .invalid
      ),
      count: entryCount
    )

    var timingInfoCount: CMItemCount = 0
    let status = CMSampleBufferGetSampleTimingInfoArray(
      sampleBuffer,
      entryCount: entryCount,
      arrayToFill: &timingInfo,
      entriesNeededOut: &timingInfoCount
    )
    guard status == noErr, timingInfoCount > 0 else {
      return nil
    }

    let count = Int(timingInfoCount)
    for index in 0..<count {
      let originalPTS = timingInfo[index].presentationTimeStamp
      if originalPTS.isValid, !originalPTS.isIndefinite {
        var adjustedPTS = CMTimeAdd(originalPTS, offset)
        if let minPTS, CMTimeCompare(adjustedPTS, minPTS) < 0 {
          adjustedPTS = minPTS
        }
        timingInfo[index].presentationTimeStamp = adjustedPTS
      }

      let originalDTS = timingInfo[index].decodeTimeStamp
      if originalDTS.isValid, !originalDTS.isIndefinite {
        var adjustedDTS = CMTimeAdd(originalDTS, offset)
        if let minPTS, CMTimeCompare(adjustedDTS, minPTS) < 0 {
          adjustedDTS = minPTS
        }
        timingInfo[index].decodeTimeStamp = adjustedDTS
      }
    }

    var adjustedBuffer: CMSampleBuffer?
    let copyStatus = CMSampleBufferCreateCopyWithNewTiming(
      allocator: kCFAllocatorDefault,
      sampleBuffer: sampleBuffer,
      sampleTimingEntryCount: count,
      sampleTimingArray: &timingInfo,
      sampleBufferOut: &adjustedBuffer
    )
    guard copyStatus == noErr else {
      return nil
    }
    return adjustedBuffer
  }

  fileprivate func waitForInputReady(_ input: AVAssetWriterInput, timeout: TimeInterval) -> Bool {
    let start = Date()
    while !input.isReadyForMoreMediaData {
      if Date().timeIntervalSince(start) >= timeout {
        return false
      }
      Thread.sleep(forTimeInterval: inputReadyPollInterval)
    }
    return true
  }

  /// Converts stereo audio to mono by averaging channels
  /// Returns the original buffer if already mono or if conversion fails
  fileprivate func downmixToMonoIfNeeded(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
    else {
      return sampleBuffer
    }

    let channelCount = Int(asbd.mChannelsPerFrame)

    // Track detected channels for diagnostics
    if detectedAppAudioChannels == 0 {
      detectedAppAudioChannels = channelCount
      debugPrint("📊 App audio channel count: \(channelCount)")
    }

    // If mono, return as-is
    guard channelCount > 1 else {
      return sampleBuffer
    }

    // Log warning once
    if !appAudioDownmixWarningLogged {
      debugPrint("⚠️ App audio is \(channelCount)-channel, downmixing to mono")
      appAudioDownmixWarningLogged = true
    }

    // Get audio buffer data
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
      return sampleBuffer
    }

    var length: Int = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    let status = CMBlockBufferGetDataPointer(
      blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
      dataPointerOut: &dataPointer)

    guard status == kCMBlockBufferNoErr, let data = dataPointer else {
      return sampleBuffer
    }

    let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
    let bytesPerSample = Int(asbd.mBitsPerChannel) / 8

    // Only handle 16-bit PCM (most common for app audio)
    guard asbd.mBitsPerChannel == 16 else {
      debugPrint("⚠️ Unsupported bit depth for downmix: \(asbd.mBitsPerChannel)")
      return sampleBuffer
    }

    // Create mono buffer
    let monoLength = sampleCount * bytesPerSample
    guard let monoData = malloc(monoLength) else {
      return sampleBuffer
    }

    // Downmix: average channels (assuming interleaved Int16)
    let stereoPtr = data.withMemoryRebound(to: Int16.self, capacity: sampleCount * channelCount) {
      $0
    }
    let monoPtr = monoData.bindMemory(to: Int16.self, capacity: sampleCount)

    for i in 0..<sampleCount {
      var sum: Int32 = 0
      for ch in 0..<channelCount {
        sum += Int32(stereoPtr[i * channelCount + ch])
      }
      monoPtr[i] = Int16(clamping: sum / Int32(channelCount))
    }

    // Create mono format description
    var monoAsbd = AudioStreamBasicDescription(
      mSampleRate: asbd.mSampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: asbd.mFormatFlags,
      mBytesPerPacket: UInt32(bytesPerSample),
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(bytesPerSample),
      mChannelsPerFrame: 1,
      mBitsPerChannel: asbd.mBitsPerChannel,
      mReserved: 0
    )

    var monoFormatDesc: CMFormatDescription?
    let formatStatus = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &monoAsbd,
      layoutSize: 0,
      layout: nil,
      magicCookieSize: 0,
      magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &monoFormatDesc
    )

    guard formatStatus == noErr, let monoFormat = monoFormatDesc else {
      free(monoData)
      return sampleBuffer
    }

    // Create block buffer from mono data
    var monoBlockBuffer: CMBlockBuffer?
    let blockStatus = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: monoData,
      blockLength: monoLength,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: monoLength,
      flags: 0,
      blockBufferOut: &monoBlockBuffer
    )

    guard blockStatus == kCMBlockBufferNoErr, let monoBlock = monoBlockBuffer else {
      free(monoData)
      return sampleBuffer
    }

    // Create new sample buffer with mono data
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let duration = CMSampleBufferGetDuration(sampleBuffer)
    var timing = CMSampleTimingInfo(
      duration: duration,
      presentationTimeStamp: pts,
      decodeTimeStamp: .invalid
    )

    var monoSampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreate(
      allocator: kCFAllocatorDefault,
      dataBuffer: monoBlock,
      dataReady: true,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: monoFormat,
      sampleCount: sampleCount,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 0,
      sampleSizeArray: nil,
      sampleBufferOut: &monoSampleBuffer
    )

    guard sampleStatus == noErr, let monoBuffer = monoSampleBuffer else {
      return sampleBuffer
    }

    return monoBuffer
  }

  /// Validates audio format before appending and logs mismatches
  fileprivate func validateAudioFormat(
    _ sampleBuffer: CMSampleBuffer, expectedChannels: Int, label: String
  ) -> Bool {
    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
    else {
      debugPrint("⚠️ \(label): Could not get format description")
      return false
    }

    let channels = Int(asbd.mChannelsPerFrame)
    if channels != expectedChannels {
      debugPrint("⚠️ \(label): Channel mismatch - expected \(expectedChannels), got \(channels)")
      return false
    }
    return true
  }

  // MARK: - Sample Rate Validation

  /// Validates incoming sample rate against configured rate and logs mismatches
  fileprivate func validateIncomingSampleRate(_ sampleBuffer: CMSampleBuffer, label: String) {
    guard configuredSampleRate > 0 else { return }
    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else { return }

    let drift = abs(asbd.mSampleRate - configuredSampleRate)
    if drift > 1 {
      if !sampleRateMismatchDetected {
        debugPrint("⚠️ \(label): Sample rate mismatch - configured=\(configuredSampleRate), incoming=\(asbd.mSampleRate)")
      }
      sampleRateMismatchDetected = true
      sampleRateMismatchCount += 1
      if drift > maxSampleRateDrift { maxSampleRateDrift = drift }
    }
  }

  // MARK: - Format Change Tracking

  /// Validates and tracks format changes, logging when format differs from previous
  fileprivate func validateAndTrackFormat(
    _ sampleBuffer: CMSampleBuffer,
    lastFormat: inout CMFormatDescription?,
    changeCount: inout Int,
    label: String
  ) -> Bool {
    guard let currentFormat = CMSampleBufferGetFormatDescription(sampleBuffer) else {
      debugPrint("⚠️ \(label): No format description in sample buffer")
      return false
    }

    if let previous = lastFormat, !CMFormatDescriptionEqual(previous, otherFormatDescription: currentFormat) {
      changeCount += 1

      // Log detailed format diff
      var details: [String] = []
      if let prevAsbd = CMAudioFormatDescriptionGetStreamBasicDescription(previous)?.pointee,
         let currAsbd = CMAudioFormatDescriptionGetStreamBasicDescription(currentFormat)?.pointee {
        if prevAsbd.mSampleRate != currAsbd.mSampleRate {
          details.append("sampleRate: \(prevAsbd.mSampleRate)→\(currAsbd.mSampleRate)")
        }
        if prevAsbd.mChannelsPerFrame != currAsbd.mChannelsPerFrame {
          details.append("channels: \(prevAsbd.mChannelsPerFrame)→\(currAsbd.mChannelsPerFrame)")
        }
        if prevAsbd.mBitsPerChannel != currAsbd.mBitsPerChannel {
          details.append("bits: \(prevAsbd.mBitsPerChannel)→\(currAsbd.mBitsPerChannel)")
        }
        if prevAsbd.mFormatID != currAsbd.mFormatID {
          details.append("formatID changed")
        }
      }

      debugPrint("⚠️ \(label) FORMAT CHANGED (#\(changeCount)): \(details.joined(separator: ", "))")
    }

    lastFormat = currentFormat
    return true
  }
  
  // MARK: - PCM to M4A Conversion
  
  /// Converts a raw PCM file to AAC M4A format
  /// Returns true on success, false on failure (caller should keep PCM as fallback)
  fileprivate func convertPcmToM4a(pcmURL: URL, m4aURL: URL, format: PCMFormatInfo) -> Bool {
    audioLog("PCM->M4A: Starting conversion, input=\(pcmURL.lastPathComponent)")
    
    // Read PCM data
    guard let pcmData = try? Data(contentsOf: pcmURL) else {
      audioLog("PCM->M4A FAILED: Could not read PCM file")
      return false
    }
    
    guard pcmData.count > 0 else {
      audioLog("PCM->M4A FAILED: PCM file is empty")
      return false
    }
    
    // Create audio format description
    var asbd = AudioStreamBasicDescription(
      mSampleRate: format.sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: format.isFloat ? kAudioFormatFlagIsFloat : (kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked),
      mBytesPerPacket: UInt32(format.bytesPerFrame),
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(format.bytesPerFrame),
      mChannelsPerFrame: UInt32(format.channelCount),
      mBitsPerChannel: UInt32(format.bitsPerChannel),
      mReserved: 0
    )
    
    var formatDesc: CMFormatDescription?
    let formatStatus = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &asbd,
      layoutSize: 0,
      layout: nil,
      magicCookieSize: 0,
      magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &formatDesc
    )
    
    guard formatStatus == noErr, let inputFormat = formatDesc else {
      audioLog("PCM->M4A FAILED: Could not create format description (\(formatStatus))")
      return false
    }
    
    // Create AVAssetWriter for M4A output
    guard let writer = try? AVAssetWriter(url: m4aURL, fileType: .m4a) else {
      audioLog("PCM->M4A FAILED: Could not create asset writer")
      return false
    }
    
    // Calculate AAC bitrate based on sample rate
    let scaleFactor = format.sampleRate / 44100.0
    let bitRate = max(min(Int(64000.0 * scaleFactor), 128000), 24000)
    
    let outputSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVNumberOfChannelsKey: format.channelCount,
      AVSampleRateKey: format.sampleRate,
      AVEncoderBitRateKey: bitRate,
    ]
    
    let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings, sourceFormatHint: inputFormat)
    writerInput.expectsMediaDataInRealTime = false
    
    guard writer.canAdd(writerInput) else {
      audioLog("PCM->M4A FAILED: Cannot add writer input")
      return false
    }
    writer.add(writerInput)
    
    guard writer.startWriting() else {
      audioLog("PCM->M4A FAILED: Could not start writing - \(writer.error?.localizedDescription ?? "unknown")")
      return false
    }
    writer.startSession(atSourceTime: .zero)
    
    // Process PCM data in chunks
    let bytesPerFrame = format.bytesPerFrame
    let framesPerBuffer = 1024
    let bytesPerBuffer = framesPerBuffer * bytesPerFrame
    let totalBytes = pcmData.count
    var offset = 0
    var currentPTS = CMTime.zero
    var framesWritten = 0
    
    while offset < totalBytes {
      // Wait for input to be ready
      while !writerInput.isReadyForMoreMediaData {
        Thread.sleep(forTimeInterval: 0.001)
        if writer.status == .failed {
          audioLog("PCM->M4A FAILED: Writer failed during conversion - \(writer.error?.localizedDescription ?? "unknown")")
          return false
        }
      }
      
      let chunkSize = min(bytesPerBuffer, totalBytes - offset)
      let numFrames = chunkSize / bytesPerFrame
      
      guard numFrames > 0 else { break }
      
      // Create sample buffer for this chunk
      let chunkData = pcmData.subdata(in: offset..<(offset + chunkSize))
      
      var blockBuffer: CMBlockBuffer?
      var status = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: chunkSize,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: chunkSize,
        flags: 0,
        blockBufferOut: &blockBuffer
      )
      
      guard status == kCMBlockBufferNoErr, let buffer = blockBuffer else {
        audioLog("PCM->M4A FAILED: Could not create block buffer (\(status))")
        return false
      }
      
      status = CMBlockBufferReplaceDataBytes(
        with: (chunkData as NSData).bytes,
        blockBuffer: buffer,
        offsetIntoDestination: 0,
        dataLength: chunkSize
      )
      
      guard status == kCMBlockBufferNoErr else {
        audioLog("PCM->M4A FAILED: Could not copy data to block buffer (\(status))")
        return false
      }
      
      var sampleBuffer: CMSampleBuffer?
      var timing = CMSampleTimingInfo(
        duration: CMTime(value: CMTimeValue(numFrames), timescale: CMTimeScale(format.sampleRate)),
        presentationTimeStamp: currentPTS,
        decodeTimeStamp: .invalid
      )
      
      status = CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: buffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: inputFormat,
        sampleCount: numFrames,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sampleBuffer
      )
      
      guard status == noErr, let sample = sampleBuffer else {
        audioLog("PCM->M4A FAILED: Could not create sample buffer (\(status))")
        return false
      }
      
      if !writerInput.append(sample) {
        audioLog("PCM->M4A FAILED: Could not append sample - \(writer.error?.localizedDescription ?? "unknown")")
        return false
      }
      
      offset += chunkSize
      currentPTS = CMTimeAdd(currentPTS, CMTime(value: CMTimeValue(numFrames), timescale: CMTimeScale(format.sampleRate)))
      framesWritten += numFrames
    }
    
    writerInput.markAsFinished()
    
    let group = DispatchGroup()
    group.enter()
    var finishError: Swift.Error?
    writer.finishWriting {
      if writer.status == .failed {
        finishError = writer.error
      }
      group.leave()
    }
    group.wait()
    
    if let error = finishError {
      audioLog("PCM->M4A FAILED: Finish writing failed - \(error.localizedDescription)")
      return false
    }
    
    let outputSize = (try? FileManager.default.attributesOfItem(atPath: m4aURL.path)[.size] as? Int64) ?? 0
    audioLog("PCM->M4A SUCCESS: \(framesWritten) frames, \(totalBytes) bytes -> \(outputSize) bytes M4A")
    return true
  }
}
