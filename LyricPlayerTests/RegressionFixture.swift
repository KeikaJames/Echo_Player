import AVFoundation
import Foundation

enum RegressionFixture {
    /// 16 kHz 单声道 WMA，每 250 ms 一个短脉冲。压缩后内嵌，避免测试依赖宿主 ffmpeg。
    private static let wmaPulsesZlibBase64 = """
    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
    """

    /// 视频从 0 秒开始，音频数据的首个 PTS 在 5 秒。
    private static let delayedAudioMKVBase64 = """
    GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAAOERFNm3TA
    v4QICvE6TbuLU6uEFUmpZlOsgaFNu4tTq4QWVK5rU6yB8U27jFOrhBJUw2dTrIIBvk27jFOrhBxT
    u2tTrIIN9ewBAAAAAAAAUwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZsu/hEWhhXEq17GD
    D0JATYCNTGF2ZjYyLjEyLjEwMldBjUxhdmY2Mi4xMi4xMDJzpJA5FKiZ4g1mNhYJ1ZSFPrFvRImI
    QLtgAAAAAAAWVK5rQMe/hJcvzTyuAQAAAAAAAE/XgQFzxYgGJw+3y5atQZyBACK1nIN1bmSIgQCG
    hlZfRkZWMYOBASPjg4Q7msoA4JCwgRC6gRCagQJVsIRVuYEBVe6BAOwBAAAAAAAAAgAArgEAAAAA
    AABg14ECc8WICpNqL7sYYKScgQAitZyDdW5kiIEAhoZBX09QVVNWqoNjLqBWu4QExLQAg4EC4ZGf
    gQG1iEDPQAAAAAAAYmSBEFXugQBjopNPcHVzSGVhZAEBOAGAPgAAAAAAElTDZ0Dav4Q6DX2Nc3Og
    Y8CAZ8iaRaOHRU5DT0RFUkSHjUxhdmY2Mi4xMi4xMDJzc9RjwItjxYgGJw+3y5atQWfIn0Wjh0VO
    Q09ERVJEh5JMYXZjNjIuMjguMTAyIGZmdjFnyKFFo4hEVVJBVElPTkSHkzAwOjAwOjA3LjAwMDAw
    MDAwMABzc9djwItjxYgKk2ovuxhgpGfIokWjh0VOQ09ERVJEh5VMYXZjNjIuMjguMTAyIGxpYm9w
    dXNnyKFFo4hEVVJBVElPTkSHkzAwOjAwOjA3LjAwODAwMDAwMAAfQ7Z1QJK/hFc6Tf7ngQCjq4EA
    AICa7Icwmklt9lZomVf9lUqBm1KlFgDSv/5////4AD0lfP//n7/v//ijlYED6AAAOf/+////8+v9
    //8+P///4KOVgQfQAAA1//7////z2////np////Ao5WBC7gAADH//////+eX///88P///4CjlYEP
    oAAALf//////53f///zs////gB9DtnVKub+EY+SvceeCE4mjk4IAAIAIg8qBihD/2830GSA2TqCj
    lYH//wAAKf//////51f///zo////gKOlggAUgAikiY1N1wAHiemRTv8IMCdvOdNyRS4th/5vDQKL
    957PoKOaggAogAiewWuCRvGIG1lx6L23HA5DqsSlr0CjkYIAPIAInsFrgkbxiBtZb5TAo5eCAFCA
    CJ6w2czrnKpISQqZi3tVe6CJwKOaggBkgAiesNnM65yqSEkGhKJU64f2khkmTlyjlIIAeIAInrDZ
    zOucqkg6iiDrfqVAo5SCAIyACJ6w2czrnKpIOzlKHL09cKOUggCggAiesNnM65yqSEl68ajc5zij
    mIIAtIAInrDZzOucqkhJfN6uwVNvggYjoKOWggDIgAiesNnM65yqSEl68ZRpfpah7aOZggDcgAie
    sNnM65yqD017nOUmiaodApNx+KOjggDwgAiesNnM65yqSDs7bQjwloA9wntGh5KNu2Oxgr1H24Oj
    m4IBBIAInrDZzOucqkhJe+ZgBkO6waTokI79rKOUggEYgAiewWuCRvGIG1lvtU9BntCjmoIBLIAI
    nrDZzOujCQ4tcoQdKopjYnuLFnpgo5KCAUCACJ7Ba4JG8YgbWXGrZgGjlIIBVIAInrDZzOujCQ4t
    clLqgbBQo5iCAWiACJ6w2czrnKpISX3xA7arXvTwAtijk4IBfIAInrDZzOucqkhJevmTlICjlIIB
    kIAInrDZzOucqkhJevLIGMd4o5mCAaSACJ6w2czrnKpISXrzk7Vhc+mhGJPAo52CAbiACJ6hPB0c
    4QKPtzF7Mi7werbo+i80dasGPqOXggHMgAiewWuCRzPIYcUvgqSIK0f4ghyjnYIB4IAInuEk4iOo
    /kmH69Td+zugHSgojExqusVIo5qCAfSACJ+ZS2+vEcA2SY3Z9QuhU8NqIXV3MqOcggIIgAie4lA/
    pjTefgCFS8ubvuz4gUxPQ3yVPKOjggIcgAihbwaNSvPSsg3UTdEXaxE08EcXtnZM8GLRddF28kCj
    lYICMIAIoOGrb68RwDZJjhk3ntCj4KOcggJEgAif8PXYzPyd5T1cVoGdJrjo2yuF1uJBgKOiggJY
    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
    Ap7wgQk=
    """

    static func makeFFmpegOnlyAudio() throws -> URL {
        guard let compressed = Data(base64Encoded: wmaPulsesZlibBase64,
                                    options: .ignoreUnknownCharacters),
              let data = try? (compressed as NSData).decompressed(using: .zlib) as Data else {
            throw FixtureError.invalidEmbeddedData
        }
        return try write(data, extension: "wma")
    }

    static func makeDelayedAudioVideo() throws -> URL {
        guard let data = Data(base64Encoded: delayedAudioMKVBase64,
                              options: .ignoreUnknownCharacters) else {
            throw FixtureError.invalidEmbeddedData
        }
        return try write(data, extension: "mkv")
    }

    static func makeNativeAudio() throws -> URL {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000),
              let samples = buffer.floatChannelData?[0] else {
            throw FixtureError.cannotCreateAudio
        }
        buffer.frameLength = 48_000
        for frame in 0..<Int(buffer.frameLength) {
            let time = Double(frame) / format.sampleRate
            let phase = time.truncatingRemainder(dividingBy: 0.5)
            samples[frame] = phase < 0.025
                ? Float(0.95 * sin(2 * .pi * 90 * time) * exp(-70 * phase))
                : 0
        }

        let url = temporaryURL(extension: "wav")
        let file = try AVAudioFile(forWriting: url,
                                   settings: format.settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        try file.write(from: buffer)
        return url
    }

    static func makeCorruptMedia(extension pathExtension: String = "mkv") throws -> URL {
        try write(Data("not a media stream".utf8), extension: pathExtension)
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func temporaryWAVs() -> Set<URL> {
        let directory = FileManager.default.temporaryDirectory
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return Set(urls.filter { $0.pathExtension.lowercased() == "wav" })
    }

    private static func write(_ data: Data, extension pathExtension: String) throws -> URL {
        let url = temporaryURL(extension: pathExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func temporaryURL(extension pathExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoPlayerRegression-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
    }

    private enum FixtureError: Error {
        case invalidEmbeddedData
        case cannotCreateAudio
    }
}
