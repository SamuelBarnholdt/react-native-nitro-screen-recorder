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

  // Separate mic audio - now using raw PCM for resilience
  private let separateAudioFile: Bool
  private let audioOutputURL: URL?  // Final M4A output
  private var micPcmURL: URL?  // Temporary raw PCM file
  private var micPcmFileHandle: FileHandle?
  private var micPcmBytesWritten: Int = 0
  private var micPcmWriteErrors: Int = 0

  // Separate app audio - now using raw PCM for resilience
  private let appAudioOutputURL: URL?  // Final M4A output
  private var appAudioPcmURL: URL?  // Temporary raw PCM file
  private var appAudioPcmFileHandle: FileHandle?
  private var appAudioPcmBytesWritten: Int = 0
  private var appAudioPcmWriteErrors: Int = 0

  // Audio format captured from first sample (needed for PCM → M4A conversion)
  private var capturedMicSampleRate: Double = 48000
  private var capturedMicChannels: Int = 1
  private var capturedAppAudioSampleRate: Double = 48000
  private var capturedAppAudioChannels: Int = 1

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

  // Note: Separate audio inputs removed - now using raw PCM direct disk writes
  // This makes audio recording crash-proof under memory pressure

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

    // Set up raw PCM file URLs for resilient audio recording
    // PCM files are written directly to disk (no buffering), then converted to M4A at finalization
    if separateAudioFile {
      if audioOutputURL != nil {
        // Create PCM file path alongside the M4A output
        let uuid = UUID().uuidString
        micPcmURL = FileManager.default.temporaryDirectory
          .appendingPathComponent("\(uuid)_mic.pcm")
      }
      if appAudioOutputURL != nil {
        let uuid = UUID().uuidString
        appAudioPcmURL = FileManager.default.temporaryDirectory
          .appendingPathComponent("\(uuid)_app.pcm")
      }
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

      // Create raw PCM files for resilient audio recording
      // These write directly to disk with no buffering - crash-proof!
      if separateAudioFile {
        if let pcmURL = micPcmURL {
          // Remove existing file if any
          try? FileManager.default.removeItem(at: pcmURL)
          // Create new file
          FileManager.default.createFile(atPath: pcmURL.path, contents: nil)
          micPcmFileHandle = try? FileHandle(forWritingTo: pcmURL)
          if micPcmFileHandle != nil {
            debugPrint("✅ PCM mic audio file created: \(pcmURL.lastPathComponent)")
          } else {
            debugPrint("⚠️ Failed to create PCM mic audio file handle")
          }
        }

        if let pcmURL = appAudioPcmURL {
          try? FileManager.default.removeItem(at: pcmURL)
          FileManager.default.createFile(atPath: pcmURL.path, contents: nil)
          appAudioPcmFileHandle = try? FileHandle(forWritingTo: pcmURL)
          if appAudioPcmFileHandle != nil {
            debugPrint("✅ PCM app audio file created: \(pcmURL.lastPathComponent)")
          } else {
            debugPrint("⚠️ Failed to create PCM app audio file handle")
          }
        }
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
      assetWriter.status == .writing
    }

    guard isWriting else {
      debugPrint(
        "assetWriter.status",
        assetWriter.status.description,
        "assetWriter.error:",
        assetWriter.error ?? "no error"
      )
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
    // TODO: Pause
  }

  public func resume() {
    // TODO: Resume
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

      // PCM direct-write metrics (crash-proof audio recording)
      info.append("micPcmBytesWritten=\(micPcmBytesWritten)")
      info.append("micPcmWriteErrors=\(micPcmWriteErrors)")
      info.append("appAudioPcmBytesWritten=\(appAudioPcmBytesWritten)")
      info.append("appAudioPcmWriteErrors=\(appAudioPcmWriteErrors)")

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

      // PCM direct-write metrics (crash-proof audio recording)
      metrics["micPcmBytesWritten"] = micPcmBytesWritten
      metrics["micPcmWriteErrors"] = micPcmWriteErrors
      metrics["appAudioPcmBytesWritten"] = appAudioPcmBytesWritten
      metrics["appAudioPcmWriteErrors"] = appAudioPcmWriteErrors
      metrics["capturedMicSampleRate"] = capturedMicSampleRate
      metrics["capturedMicChannels"] = capturedMicChannels
      metrics["capturedAppAudioSampleRate"] = capturedAppAudioSampleRate
      metrics["capturedAppAudioChannels"] = capturedAppAudioChannels

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
    public let audioURL: URL?  // Mic audio file
    public let appAudioURL: URL?  // App/system audio file
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
        // Close PCM file handles
        closePcmFileHandles()
        throw Error.wrongAssetWriterStatus(.cancelled)
      }

      let group: DispatchGroup = .init()

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

      // Close PCM file handles first
      closePcmFileHandles()

      // Convert PCM files to M4A
      var audioURL: URL? = nil
      var appAudioURL: URL? = nil

      if separateAudioFile {
        // Convert mic PCM to M4A
        if let pcmURL = micPcmURL, let outputURL = audioOutputURL, micPcmBytesWritten > 0 {
          debugPrint(
            "🔄 Converting mic PCM to M4A: \(micPcmBytesWritten) bytes, sampleRate=\(capturedMicSampleRate)"
          )
          if let convertedURL = convertPcmToM4A(
            pcmURL: pcmURL,
            outputURL: outputURL,
            sampleRate: capturedMicSampleRate,
            channels: capturedMicChannels
          ) {
            audioURL = convertedURL
            debugPrint("✅ Mic PCM → M4A conversion complete")
          } else {
            debugPrint("⚠️ Mic PCM → M4A conversion failed, returning raw PCM")
            // Fall back to returning PCM file if conversion fails
            audioURL = pcmURL
          }
        } else if micPcmBytesWritten == 0 {
          debugPrint("⚠️ No mic PCM bytes written, skipping conversion")
        }

        // Convert app audio PCM to M4A
        if let pcmURL = appAudioPcmURL, let outputURL = appAudioOutputURL,
          appAudioPcmBytesWritten > 0
        {
          debugPrint(
            "🔄 Converting app audio PCM to M4A: \(appAudioPcmBytesWritten) bytes, sampleRate=\(capturedAppAudioSampleRate)"
          )
          if let convertedURL = convertPcmToM4A(
            pcmURL: pcmURL,
            outputURL: outputURL,
            sampleRate: capturedAppAudioSampleRate,
            channels: capturedAppAudioChannels
          ) {
            appAudioURL = convertedURL
            debugPrint("✅ App audio PCM → M4A conversion complete")
          } else {
            debugPrint("⚠️ App audio PCM → M4A conversion failed, returning raw PCM")
            appAudioURL = pcmURL
          }
        } else if appAudioPcmBytesWritten == 0 {
          debugPrint("⚠️ No app audio PCM bytes written, skipping conversion")
        }
      }

      return FinishResult(
        videoURL: assetWriter.outputURL, audioURL: audioURL, appAudioURL: appAudioURL)
    }
  }

  /// Closes PCM file handles to flush data to disk
  private func closePcmFileHandles() {
    if let handle = micPcmFileHandle {
      do {
        try handle.synchronize()
        try handle.close()
        debugPrint("✅ Mic PCM file closed: \(micPcmBytesWritten) bytes written")
      } catch {
        debugPrint("⚠️ Error closing mic PCM file: \(error.localizedDescription)")
      }
      micPcmFileHandle = nil
    }

    if let handle = appAudioPcmFileHandle {
      do {
        try handle.synchronize()
        try handle.close()
        debugPrint("✅ App audio PCM file closed: \(appAudioPcmBytesWritten) bytes written")
      } catch {
        debugPrint("⚠️ Error closing app audio PCM file: \(error.localizedDescription)")
      }
      appAudioPcmFileHandle = nil
    }
  }

  /// Converts a raw PCM file to M4A (AAC) format
  /// Returns the output URL on success, nil on failure
  private func convertPcmToM4A(
    pcmURL: URL,
    outputURL: URL,
    sampleRate: Double,
    channels: Int
  ) -> URL? {
    // Remove existing output file
    try? FileManager.default.removeItem(at: outputURL)

    // Read PCM data
    guard let pcmData = try? Data(contentsOf: pcmURL) else {
      debugPrint("⚠️ Failed to read PCM file")
      return nil
    }

    guard pcmData.count > 0 else {
      debugPrint("⚠️ PCM file is empty")
      return nil
    }

    // Create AVAssetWriter for M4A output
    guard let writer = try? AVAssetWriter(url: outputURL, fileType: .m4a) else {
      debugPrint("⚠️ Failed to create M4A asset writer")
      return nil
    }

    // Calculate bitrate based on sample rate
    let scaleFactor = sampleRate / 44100.0
    let bitRate = max(min(Int(64000.0 * scaleFactor), 128000), 24000)

    let audioSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVNumberOfChannelsKey: channels,
      AVSampleRateKey: sampleRate,
      AVEncoderBitRateKey: bitRate,
    ]

    let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
    audioInput.expectsMediaDataInRealTime = false

    guard writer.canAdd(audioInput) else {
      debugPrint("⚠️ Cannot add audio input to M4A writer")
      return nil
    }
    writer.add(audioInput)

    // Start writing
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    // Calculate samples and write in chunks
    let bytesPerSample = 2  // 16-bit audio
    let bytesPerFrame = bytesPerSample * channels
    let totalSamples = pcmData.count / bytesPerFrame
    let samplesPerBuffer = 1024
    var samplesWritten = 0

    let semaphore = DispatchSemaphore(value: 0)
    var conversionError: Swift.Error?

    audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "pcm.converter")) {
      while audioInput.isReadyForMoreMediaData && samplesWritten < totalSamples {
        let remainingSamples = totalSamples - samplesWritten
        let samplesToWrite = min(samplesPerBuffer, remainingSamples)
        let byteOffset = samplesWritten * bytesPerFrame
        let byteLength = samplesToWrite * bytesPerFrame

        guard byteOffset + byteLength <= pcmData.count else {
          break
        }

        // Create CMSampleBuffer from PCM data
        let subdata = pcmData.subdata(in: byteOffset..<(byteOffset + byteLength))

        if let sampleBuffer = self.createSampleBuffer(
          from: subdata,
          sampleRate: sampleRate,
          channels: channels,
          sampleOffset: samplesWritten,
          sampleCount: samplesToWrite
        ) {
          if !audioInput.append(sampleBuffer) {
            conversionError = writer.error
            debugPrint("⚠️ Failed to append sample buffer: \(writer.error?.localizedDescription ?? "unknown")")
            break
          }
          samplesWritten += samplesToWrite
        } else {
          debugPrint("⚠️ Failed to create sample buffer at offset \(samplesWritten)")
          break
        }
      }

      audioInput.markAsFinished()
      writer.finishWriting {
        semaphore.signal()
      }
    }

    // Wait for conversion to complete (with timeout)
    let timeout = DispatchTime.now() + .seconds(30)
    if semaphore.wait(timeout: timeout) == .timedOut {
      debugPrint("⚠️ PCM → M4A conversion timed out")
      writer.cancelWriting()
      return nil
    }

    if let error = conversionError ?? writer.error {
      debugPrint("⚠️ PCM → M4A conversion error: \(error.localizedDescription)")
      return nil
    }

    guard writer.status == .completed else {
      debugPrint("⚠️ M4A writer did not complete: \(writer.status.description)")
      return nil
    }

    // Clean up PCM file
    try? FileManager.default.removeItem(at: pcmURL)

    debugPrint(
      "✅ PCM → M4A conversion complete: \(samplesWritten) samples, \(pcmData.count) bytes → M4A")
    return outputURL
  }

  /// Creates a CMSampleBuffer from raw PCM data
  private func createSampleBuffer(
    from data: Data,
    sampleRate: Double,
    channels: Int,
    sampleOffset: Int,
    sampleCount: Int
  ) -> CMSampleBuffer? {
    let bytesPerSample = 2
    let bytesPerFrame = bytesPerSample * channels

    // Create audio format description
    var asbd = AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: UInt32(bytesPerFrame),
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(bytesPerFrame),
      mChannelsPerFrame: UInt32(channels),
      mBitsPerChannel: UInt32(bytesPerSample * 8),
      mReserved: 0
    )

    var formatDescription: CMFormatDescription?
    let formatStatus = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &asbd,
      layoutSize: 0,
      layout: nil,
      magicCookieSize: 0,
      magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &formatDescription
    )

    guard formatStatus == noErr, let format = formatDescription else {
      return nil
    }

    // Create block buffer from data
    var blockBuffer: CMBlockBuffer?
    let blockStatus = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSStatus in
      guard bytes.baseAddress != nil else { return -1 }
      return CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: data.count,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: data.count,
        flags: 0,
        blockBufferOut: &blockBuffer
      )
    }

    guard blockStatus == kCMBlockBufferNoErr, let block = blockBuffer else {
      return nil
    }

    // Copy data into block buffer
    let copyStatus = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSStatus in
      guard let baseAddress = bytes.baseAddress else { return -1 }
      return CMBlockBufferReplaceDataBytes(
        with: baseAddress,
        blockBuffer: block,
        offsetIntoDestination: 0,
        dataLength: data.count
      )
    }

    guard copyStatus == kCMBlockBufferNoErr else {
      return nil
    }

    // Create sample buffer
    var sampleBuffer: CMSampleBuffer?
    let timeScale = CMTimeScale(sampleRate)
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: timeScale),
      presentationTimeStamp: CMTime(value: CMTimeValue(sampleOffset), timescale: timeScale),
      decodeTimeStamp: .invalid
    )

    let sampleStatus = CMSampleBufferCreate(
      allocator: kCFAllocatorDefault,
      dataBuffer: block,
      dataReady: true,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: format,
      sampleCount: sampleCount,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 0,
      sampleSizeArray: nil,
      sampleBufferOut: &sampleBuffer
    )

    guard sampleStatus == noErr else {
      return nil
    }

    return sampleBuffer
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

    // Small tolerance: allow audio up to 100ms before video start
    let tolerance = CMTime(value: 1, timescale: 10)  // 100ms
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

    // Check if we have early audio that should adjust our start time
    // Use the earliest timestamp between video and buffered audio
    var effectiveStartTime = sourceTime
    if let earliestMic = earlyMicBuffers.first {
      let micPTS = CMSampleBufferGetPresentationTimeStamp(earliestMic)
      if CMTimeCompare(micPTS, effectiveStartTime) < 0 {
        effectiveStartTime = micPTS
        debugPrint("📦 Adjusted session start to earliest mic audio: \(effectiveStartTime.seconds)s")
      }
    }
    if let earliestApp = earlyAppAudioBuffers.first {
      let appPTS = CMSampleBufferGetPresentationTimeStamp(earliestApp)
      if CMTimeCompare(appPTS, effectiveStartTime) < 0 {
        effectiveStartTime = appPTS
        debugPrint("📦 Adjusted session start to earliest app audio: \(effectiveStartTime.seconds)s")
      }
    }

    // Store the reference timestamp for all writers to use
    sessionStartTime = effectiveStartTime
    assetWriter.startSession(atSourceTime: effectiveStartTime)
    assetWriterSessionStarted = true
    if firstVideoPTS == nil {
      firstVideoPTS = sourceTime
      debugPrint("📊 First video PTS: \(sourceTime.seconds)s")
    }
    debugPrint(
      "🎬 Session started at \(effectiveStartTime.seconds)s (video PTS: \(sourceTime.seconds)s)")

    // Flush buffered early audio now that session has started
    flushEarlyAudioBuffers()
  }

  // Note: Audio session management removed - now using raw PCM direct writes

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
    if !isPositiveTime(frameDuration), let lastPTS = lastVideoPTS {
      let delta = CMTimeSubtract(pts, lastPTS)
      if isPositiveTime(delta) {
        frameDuration = delta
      }
    }
    if !isPositiveTime(frameDuration) {
      frameDuration =
        isPositiveTime(lastVideoFrameDuration)
        ? lastVideoFrameDuration
        : CMTime(value: 1, timescale: 60)
    }
    let endTime = isPositiveTime(frameDuration) ? CMTimeAdd(pts, frameDuration) : pts
    let appended = videoInput.append(sampleBuffer)
    if appended {
      totalVideoFrames += 1
      if isPositiveTime(frameDuration) {
        lastVideoFrameDuration = frameDuration
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
    guard separateAudioFile, let fileHandle = micPcmFileHandle else {
      return false
    }

    guard let startTime = sessionStartTime else {
      // Still buffer/drop early audio - we need video timestamp reference
      return false
    }

    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    // Allow small tolerance (100ms) for audio slightly before session start
    let tolerance = CMTime(value: 1, timescale: 10)
    let adjustedStartTime = CMTimeSubtract(startTime, tolerance)
    if CMTimeCompare(pts, adjustedStartTime) < 0 {
      return false
    }

    // Capture audio format info from first sample (needed for PCM → M4A conversion)
    if micAudioFormatDescription == nil {
      micAudioFormatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
      if let formatDesc = micAudioFormatDescription,
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
      {
        capturedMicSampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000
        capturedMicChannels = max(Int(asbd.mChannelsPerFrame), 1)
        debugPrint(
          "📊 Captured mic audio format: \(capturedMicSampleRate)Hz, \(capturedMicChannels) channels"
        )
      }
    }

    // Extract raw PCM bytes from sample buffer and write DIRECTLY to disk
    // This is crash-proof - data goes to disk immediately, no buffering!
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
      return false
    }

    var length: Int = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    let status = CMBlockBufferGetDataPointer(
      blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
      dataPointerOut: &dataPointer)

    guard status == kCMBlockBufferNoErr, let pointer = dataPointer, length > 0 else {
      return false
    }

    // Write raw PCM bytes directly to disk
    let data = Data(bytes: pointer, count: length)
    do {
      try fileHandle.write(contentsOf: data)
      micPcmBytesWritten += length
      totalSeparateAudioSamples += 1

      // Track timing for duration calculation
      let duration = audioSampleDuration(sampleBuffer, formatDescription: micAudioFormatDescription)
      let endTime = isPositiveTime(duration) ? CMTimeAdd(pts, duration) : pts
      updatePtsRange(pts, min: &separateMicPtsMin, max: &separateMicPtsMax)
      if CMTimeCompare(endTime, lastMicEndTime) > 0 {
        lastMicEndTime = endTime
      }
      return true
    } catch {
      micPcmWriteErrors += 1
      if micPcmWriteErrors <= 5 {
        debugPrint("⚠️ PCM mic write error (\(micPcmWriteErrors)): \(error.localizedDescription)")
      }
      return false
    }
  }

  fileprivate func captureAppAudioOutput(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard separateAudioFile, let fileHandle = appAudioPcmFileHandle else {
      return false
    }

    guard let startTime = sessionStartTime else {
      appAudioDroppedBeforeSession += 1
      return false
    }

    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

    // Track first app audio PTS and monotonicity
    if firstAppAudioPTS == nil {
      firstAppAudioPTS = pts
      let deltaToVideo = firstVideoPTS != nil ? CMTimeSubtract(pts, firstVideoPTS!).seconds : 0
      debugPrint("📊 First app audio PTS: \(pts.seconds)s (delta to video: \(deltaToVideo)s)")
    }
    if let prevPTS = lastAppAudioPTS, CMTimeCompare(pts, prevPTS) < 0 {
      appAudioMonotonicityViolations += 1
    }
    lastAppAudioPTS = pts

    // Allow small tolerance (100ms) for audio slightly before session start
    let tolerance = CMTime(value: 1, timescale: 10)
    let adjustedStartTime = CMTimeSubtract(startTime, tolerance)
    if CMTimeCompare(pts, adjustedStartTime) < 0 {
      appAudioDroppedPTSBelowStart += 1
      return false
    }

    // Capture audio format info from first sample (needed for PCM → M4A conversion)
    if appAudioFormatDescription == nil {
      appAudioFormatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
      if let formatDesc = appAudioFormatDescription,
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
      {
        capturedAppAudioSampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000
        capturedAppAudioChannels = max(Int(asbd.mChannelsPerFrame), 1)
        debugPrint(
          "📊 Captured app audio format: \(capturedAppAudioSampleRate)Hz, \(capturedAppAudioChannels) channels"
        )
      }
    }

    // Extract raw PCM bytes from sample buffer and write DIRECTLY to disk
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
      return false
    }

    var length: Int = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    let status = CMBlockBufferGetDataPointer(
      blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
      dataPointerOut: &dataPointer)

    guard status == kCMBlockBufferNoErr, let pointer = dataPointer, length > 0 else {
      return false
    }

    // Write raw PCM bytes directly to disk - crash-proof!
    let data = Data(bytes: pointer, count: length)
    do {
      try fileHandle.write(contentsOf: data)
      appAudioPcmBytesWritten += length
      totalAppAudioSamples += 1

      // Track timing
      let duration = audioSampleDuration(sampleBuffer, formatDescription: appAudioFormatDescription)
      let endTime = isPositiveTime(duration) ? CMTimeAdd(pts, duration) : pts
      updatePtsRange(pts, min: &appAudioPtsMin, max: &appAudioPtsMax)
      if CMTimeCompare(endTime, lastAppAudioEndTime) > 0 {
        lastAppAudioEndTime = endTime
      }
      return true
    } catch {
      appAudioPcmWriteErrors += 1
      if appAudioPcmWriteErrors <= 5 {
        debugPrint(
          "⚠️ PCM app audio write error (\(appAudioPcmWriteErrors)): \(error.localizedDescription)")
      }
      return false
    }
  }

  // Note: Audio padding removed - with raw PCM approach, audio has its true recorded duration

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
        let timeScale = CMTimeScale(sampleRate.rounded())
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
}
