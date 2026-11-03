import Foundation

/// Reads microphone samples for the level meters.
public enum AudioLevels {
    /// The loudest sample of the first two channels, from 0 to 1. A single channel counts as both.
    /// Nil for a sample format the meter can't read.
    public static func channelPeaks(
        _ bytes: UnsafeRawBufferPointer, bits: Int, float: Bool, channels: Int, interleaved: Bool
    ) -> (left: Float, right: Float)? {
        let read: (Int) -> Float
        let count: Int
        if float, bits == 32 {
            let samples = bytes.bindMemory(to: Float.self)
            count = samples.count
            read = { abs(samples[$0]) }
        } else if bits == 16 {
            let samples = bytes.bindMemory(to: Int16.self)
            count = samples.count
            read = { abs(Float(samples[$0])) / 32768 }
        } else if bits == 32 {
            let samples = bytes.bindMemory(to: Int32.self)
            count = samples.count
            read = { abs(Float(samples[$0])) / 2_147_483_648 }
        } else {
            return nil
        }
        var peaks: [Float] = [0, 0]
        let frames = count / channels
        for index in 0..<count {
            // Interleaved samples alternate channels; otherwise each channel is one block.
            let channel = interleaved ? index % channels : index / max(frames, 1)
            guard channel < 2 else { continue }
            peaks[channel] = max(peaks[channel], read(index))
        }
        return channels == 1 ? (peaks[0], peaks[0]) : (peaks[0], peaks[1])
    }
}
