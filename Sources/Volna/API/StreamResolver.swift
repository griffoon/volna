import CommonCrypto
import CryptoKit
import Foundation

struct StreamSource: Sendable, Equatable {
    let url: URL
    let codec: String
    let kbps: Int?

    /// HUD line like `FLAC · 1411 kbps`.
    var label: String {
        let name = codec.replacingOccurrences(of: "-mp4", with: "").uppercased()
        guard let kbps, kbps > 0 else { return name }
        return "\(name) · \(kbps) kbps"
    }
}

/// Turns a track id into something AVPlayer can play. Nothing is kept beyond the temp cache.
struct StreamResolver: Sendable {
    private static let salt = "XGRlBW9FXlekgbPrRHuSiA"

    let client: YMClient

    func stream(for trackID: String, quality: Preferences.Quality) async throws -> StreamSource {
        switch quality {
        case .lossless:
            if let source = try? await fileInfoSource(trackID: trackID, quality: "lossless") { return source }
        case .efficient:
            if let source = try? await fileInfoSource(trackID: trackID, quality: "nq") { return source }
        case .high:
            break
        }
        return try await legacyMP3(for: trackID)
    }

    // MARK: get-file-info (lossless / aac)

    private func fileInfoSource(trackID: String, quality: String) async throws -> StreamSource {
        let info = try await client.fileInfo(trackID: trackID, quality: quality, transport: "raw")
        guard var url = URL(string: info.url) else { throw YMError.noStream }
        if let key = info.key, !key.isEmpty {
            url = try await decryptToTemp(url: url, hexKey: key, codec: info.codec, trackID: trackID)
        }
        return StreamSource(url: url, codec: info.codec, kbps: info.bitrate)
    }

    /// `encraw` files are AES-128-CTR with a zero counter; decrypt once into the caches dir.
    private func decryptToTemp(url: URL, hexKey: String, codec: String, trackID: String) async throws -> URL {
        let ext = codec.contains("mp4") ? "m4a" : (codec == "mp3" ? "mp3" : codec)
        let dir = FileManager.default.temporaryDirectory.appending(path: "stream", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appending(path: "\(trackID).\(ext)")
        if FileManager.default.fileExists(atPath: target.path) { return target }

        let (data, _) = try await client.session.data(from: url)
        let plain = try AESCTR.decrypt(data, hexKey: hexKey)
        try plain.write(to: target, options: .atomic)
        return target
    }

    // MARK: Legacy download-info (mp3)

    private func legacyMP3(for trackID: String) async throws -> StreamSource {
        let variants = try await client.downloadInfo(trackID: trackID)
        guard let best = variants
            .filter({ $0.codec == "mp3" })
            .max(by: { $0.bitrateInKbps < $1.bitrateInKbps }),
              let infoURL = URL(string: best.downloadInfoUrl)
        else { throw YMError.noStream }

        let (data, _) = try await client.session.data(from: infoURL)
        let info = try DownloadXML.parse(data)

        let path = info.path.hasPrefix("/") ? String(info.path.dropFirst()) : info.path
        let digest = Insecure.MD5.hash(data: Data((Self.salt + path + info.s).utf8))
        let sign = digest.map { String(format: "%02x", $0) }.joined()

        guard let url = URL(string: "https://\(info.host)/get-mp3/\(sign)/\(info.ts)/\(path)") else {
            throw YMError.noStream
        }
        return StreamSource(url: url, codec: "mp3", kbps: best.bitrateInKbps)
    }

    /// Drops temp files left from previous lossless playback.
    static func clearCache() {
        let dir = FileManager.default.temporaryDirectory.appending(path: "stream", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: dir)
    }
}

enum AESCTR {
    static func decrypt(_ data: Data, hexKey: String) throws -> Data {
        let key = try hexBytes(hexKey)
        let iv = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        var cryptor: CCCryptorRef?
        var status = CCCryptorCreateWithMode(
            CCOperation(kCCDecrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
            CCPadding(ccNoPadding), iv, key, key.count, nil, 0, 0,
            CCModeOptions(kCCModeOptionCTR_BE), &cryptor
        )
        guard status == kCCSuccess, let cryptor else { throw YMError.noStream }
        defer { CCCryptorRelease(cryptor) }

        var output = Data(count: data.count)
        var moved = 0
        status = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { out in
                CCCryptorUpdate(cryptor, input.baseAddress, data.count, out.baseAddress, data.count, &moved)
            }
        }
        guard status == kCCSuccess else { throw YMError.noStream }
        return output.prefix(moved)
    }

    private static func hexBytes(_ hex: String) throws -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else { throw YMError.noStream }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

/// Parses `<download-info><host/><path/><ts/><s/></download-info>`.
private final class DownloadXML: NSObject, XMLParserDelegate {
    struct Info {
        let host: String
        let path: String
        let ts: String
        let s: String
    }

    private var values: [String: String] = [:]
    private var buffer = ""

    static func parse(_ data: Data) throws -> Info {
        let delegate = DownloadXML()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(),
              let host = delegate.values["host"],
              let path = delegate.values["path"],
              let ts = delegate.values["ts"],
              let s = delegate.values["s"]
        else { throw YMError.noStream }
        return Info(host: host, path: path, ts: ts, s: s)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        values[elementName] = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
