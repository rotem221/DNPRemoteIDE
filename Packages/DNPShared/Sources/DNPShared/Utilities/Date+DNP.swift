import Foundation

extension Date {
    /// Quantize to millisecond precision, matching the wire format used by `DNPCoders`
    /// (`iso8601withFraction`). Apply at model boundaries so in-memory values are bit-equal
    /// to the same value after persist / decode round-trips — required for dedup and equality
    /// checks across the bridge and on-disk store.
    public var dnpQuantized: Date {
        let ms = (self.timeIntervalSince1970 * 1000.0).rounded()
        return Date(timeIntervalSince1970: ms / 1000.0)
    }
}
