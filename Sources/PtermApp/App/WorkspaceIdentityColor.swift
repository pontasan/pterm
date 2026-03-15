import Foundation

enum WorkspaceIdentityColor {
    struct HeaderStyle {
        let background: (Float, Float, Float, Float)
        let accent: (Float, Float, Float, Float)
        let text: (Float, Float, Float, Float)
    }

    static func headerStyle(for seed: String) -> HeaderStyle {
        let normalizedSeed = seed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "default" : seed
        var state = splitMix64(fnv1a64(normalizedSeed))
        let hue = distributedHue(from: &state)
        let saturation = 0.50 + 0.12 * positiveFraction(from: &state)
        let value = 0.74 + 0.16 * positiveFraction(from: &state)
        let accentRGB = hsvToRGB(h: hue, s: saturation, v: value)

        let background = mix(
            lhs: accentRGB,
            rhs: (0.07, 0.08, 0.10),
            ratio: 0.22
        )

        return HeaderStyle(
            background: (background.0, background.1, background.2, 0.95),
            accent: (accentRGB.0, accentRGB.1, accentRGB.2, 0.78),
            text: readableForeground(for: background)
        )
    }

    private static func readableForeground(
        for background: (Float, Float, Float)
    ) -> (Float, Float, Float, Float) {
        let luminance =
            0.2126 * background.0 +
            0.7152 * background.1 +
            0.0722 * background.2
        return luminance > 0.42 ? (0.06, 0.07, 0.09, 1.0) : (0.96, 0.97, 0.99, 1.0)
    }

    private static func mix(
        lhs: (Float, Float, Float),
        rhs: (Float, Float, Float),
        ratio: Float
    ) -> (Float, Float, Float) {
        let inverse = 1.0 - ratio
        return (
            lhs.0 * inverse + rhs.0 * ratio,
            lhs.1 * inverse + rhs.1 * ratio,
            lhs.2 * inverse + rhs.2 * ratio
        )
    }

    private static func hsvToRGB(
        h: Float,
        s: Float,
        v: Float
    ) -> (Float, Float, Float) {
        guard s > 0 else { return (v, v, v) }
        let scaled = h * 6.0
        let sector = Int(floor(scaled)) % 6
        let fraction = scaled - floor(scaled)
        let p = v * (1.0 - s)
        let q = v * (1.0 - s * fraction)
        let t = v * (1.0 - s * (1.0 - fraction))
        switch sector {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    private static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for scalar in string.unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash &*= 1099511628211
        }
        return hash
    }

    private static func splitMix64(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    private static func distributedHue(from state: inout UInt64) -> Float {
        state = splitMix64(state)
        let majorBucketCount: UInt64 = 12
        let bucket = state % majorBucketCount
        let permutedBucket = (bucket * 5) % majorBucketCount
        let bucketStart = Float(permutedBucket) / Float(majorBucketCount)
        let bucketSpan = Float(1.0 / Double(majorBucketCount))
        state = splitMix64(state)
        let local = Float((state >> 48) & 0xFFFF) / Float(1 << 16)
        let centeredJitter = (local - 0.5) * bucketSpan * 0.42
        let hue = bucketStart + bucketSpan * 0.5 + centeredJitter
        return hue >= 1.0 ? hue - 1.0 : max(0.0, hue)
    }

    private static func positiveFraction(from state: inout UInt64) -> Float {
        state = splitMix64(state)
        let mantissa = state >> 40
        return Float(mantissa) / Float(1 << 24)
    }
}
