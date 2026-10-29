import AVFoundation
import CoreMedia
import Foundation

/// Extracts the audio track from any media format supported by AVFoundation
/// and writes a 16 kHz mono PCM WAV suitable for whisper.cpp.
public final class MediaAudioConverter: @unchecked Sendable {
    public enum ConversionError: LocalizedError {
        case noAudioTrack
        case cannotRead(String)
        case cannotWrite(String)

        public var errorDescription: String? {
            switch self {
            case .noAudioTrack:
                return L10n.t("file.error.noAudio")
            case .cannotRead(let detail):
                return L10n.t("file.error.read", detail)
            case .cannotWrite(let detail):
                return L10n.t("file.error.write", detail)
            }
        }
    }

    public init() {}

    public func convertToWAV(sourceURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw ConversionError.noAudioTrack
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ConversionError.cannotRead(error.localizedDescription)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ConversionError.cannotRead("unsupported audio track")
        }
        reader.add(output)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxlocal-media-\(UUID().uuidString).wav")
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw ConversionError.cannotWrite("cannot create temporary WAV file")
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw ConversionError.cannotWrite(error.localizedDescription)
        }

        do {
            try handle.write(contentsOf: Self.wavHeader(dataBytes: 0))
            guard reader.startReading() else {
                throw ConversionError.cannotRead(reader.error?.localizedDescription ?? "reader did not start")
            }

            var byteCount: UInt32 = 0
            while reader.status == .reading {
                try Task.checkCancellation()
                guard let sample = output.copyNextSampleBuffer() else { break }
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                guard length > 0 else { continue }
                var bytes = [UInt8](repeating: 0, count: length)
                let result: OSStatus = bytes.withUnsafeMutableBytes { buffer in
                    guard let address = buffer.baseAddress else {
                        return kCMBlockBufferBadCustomBlockSourceErr
                    }
                    return CMBlockBufferCopyDataBytes(
                        block,
                        atOffset: 0,
                        dataLength: length,
                        destination: address)
                }
                guard result == kCMBlockBufferNoErr else {
                    throw ConversionError.cannotRead("audio buffer error \(result)")
                }
                try handle.write(contentsOf: Data(bytes))
                byteCount = byteCount &+ UInt32(length)
            }

            guard reader.status == .completed else {
                throw ConversionError.cannotRead(reader.error?.localizedDescription ?? "conversion stopped")
            }
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Self.wavHeader(dataBytes: byteCount))
            try handle.close()
            return destination
        } catch {
            reader.cancelReading()
            try? handle.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func wavHeader(dataBytes: UInt32) -> Data {
        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.appendUInt32LE(36 &+ dataBytes)
        data.append("WAVEfmt ".data(using: .ascii)!)
        data.appendUInt32LE(16)
        data.appendUInt16LE(1)
        data.appendUInt16LE(1)
        data.appendUInt32LE(16_000)
        data.appendUInt32LE(32_000)
        data.appendUInt16LE(2)
        data.appendUInt16LE(16)
        data.append("data".data(using: .ascii)!)
        data.appendUInt32LE(dataBytes)
        return data
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
