// File: KSplatWriter.swift
import Foundation
import simd

/// Writes .ksplat format (mkkellogg/GaussianSplats3D)
/// This version targets Version 1 with 4096-byte alignment and 24-byte splats.
final class KSplatWriter {
    let compressionLevel: Int

    init(compressionLevel: Int = 1) {
        self.compressionLevel = min(max(compressionLevel, 0), 2)
    }

    func write(cloud: GaussianCloud, to path: String) throws {
        var buffer = Data()

        // ── File Header (32 bytes used in reference) ──
        // Alignment: Page size = 4096 bytes
        let version: UInt16 = 1
        let sectionCount: UInt8 = 1
        let splatCount = UInt32(cloud.count)
        let shDeg = UInt8(cloud.shDegree)

        // Offset 0: Version/Magic
        appendU16(&buffer, version)   // 0-1
        buffer.append(0)              // 2
        buffer.append(0)              // 3
        
        // Offset 4: totalSplatCount
        appendU32(&buffer, splatCount) // 4-7
        
        // Offset 8: Section information
        buffer.append(1)              // 8 -> Section Count?
        buffer.append(0)              // 9
        buffer.append(0)              // 10
        buffer.append(0)              // 11
        
        // Offset 12: Repeat splat count? (Matches reference dump)
        appendU32(&buffer, splatCount) // 12-15
        
        // Offset 16..31: Reserved or additional meta
        buffer.append(contentsOf: [UInt8](repeating: 0, count: 16))

        // Pad to 4096 bytes (0x1000)
        buffer.append(contentsOf: [UInt8](repeating: 0, count: 4096 - buffer.count))

        // ── Section Header (64 bytes) ──
        // Starting at 4096 (0x1000)
        let bucketSize: UInt32 = 256
        let bucketCount: UInt32 = UInt32((cloud.count + Int(bucketSize) - 1) / Int(bucketSize))
        let blockSize: Float = 5.0

        appendU32(&buffer, splatCount)      // 0-3
        appendU32(&buffer, splatCount)      // 4-7 (maxSplatCount)
        appendU32(&buffer, bucketSize)      // 8-11
        appendU32(&buffer, bucketCount)     // 12-15
        appendF32(&buffer, blockSize)       // 16-19
        appendF32(&buffer, blockSize * 0.5) // 20-23
        
        // Placeholder for SH/Metadata until end of Section Header
        let sectionHeaderPad = 64 - 24
        buffer.append(contentsOf: [UInt8](repeating: 0, count: sectionHeaderPad))

        // Pad to start of data (Reference dump data starts at 0x1400 = 5120 bytes)
        buffer.append(contentsOf: [UInt8](repeating: 0, count: 5120 - buffer.count))

        // ── Splat Data (24 bytes per splat) ──
        // Interleaved: Pos(6) + Scale(6) + Rot(8) + Col(4) = 24 bytes
        for splat in cloud.splats {
            // Position (3 x f16) = 6
            appendF16(&buffer, splat.position.x)
            appendF16(&buffer, splat.position.y)
            appendF16(&buffer, splat.position.z)
            
            // Scale (3 x f16) = 6
            // We store log value for reconstruction by shader
            appendF16(&buffer, log(max(splat.scale.x, 1e-10)))
            appendF16(&buffer, log(max(splat.scale.y, 1e-10)))
            appendF16(&buffer, log(max(splat.scale.z, 1e-10)))
            
            // Rotation (4 x f16) = 8
            appendF16(&buffer, splat.rotation.real)
            appendF16(&buffer, splat.rotation.imag.x)
            appendF16(&buffer, splat.rotation.imag.y)
            appendF16(&buffer, splat.rotation.imag.z)
            
            // Color RGBA = 4
            buffer.append(splat.color.x)
            buffer.append(splat.color.y)
            buffer.append(splat.color.z)
            buffer.append(splat.color.w)
        }

        try buffer.write(to: URL(fileURLWithPath: path))
    }

    // ── Binary helpers ──
    private func appendU16(_ data: inout Data, _ v: UInt16) {
        var val = v.littleEndian; data.append(contentsOf: withUnsafeBytes(of: &val) { Array($0) })
    }
    private func appendU32(_ data: inout Data, _ v: UInt32) {
        var val = v.littleEndian; data.append(contentsOf: withUnsafeBytes(of: &val) { Array($0) })
    }
    private func appendF32(_ data: inout Data, _ v: Float) {
        var val = v.bitPattern.littleEndian; data.append(contentsOf: withUnsafeBytes(of: &val) { Array($0) })
    }
    private func appendF16(_ data: inout Data, _ v: Float) {
        let bits = floatToHalf(v).littleEndian
        var val = bits; data.append(contentsOf: withUnsafeBytes(of: &val) { Array($0) })
    }

    private func floatToHalf(_ value: Float) -> UInt16 {
        let bits = value.bitPattern
        let sign = (bits >> 31) & 1
        let exponent = Int((bits >> 23) & 0xFF) - 127
        let mantissa = bits & 0x7FFFFF

        if exponent > 15 {
            return UInt16(sign << 15) | 0x7C00
        } else if exponent < -14 {
            if exponent < -24 { return UInt16(sign << 15) }
            let shift = -14 - exponent
            let m = (mantissa | 0x800000) >> (shift + 13)
            return UInt16(sign << 15) | UInt16(m)
        } else {
            let e = UInt16(exponent + 15)
            let m = UInt16(mantissa >> 13)
            return UInt16(sign << 15) | (e << 10) | m
        }
    }
}
