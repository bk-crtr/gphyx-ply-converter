// File: KSplatWriter.swift
// Conforms to: mkkellogg/GaussianSplats3D — SplatBuffer.js (official spec)
import Foundation
import simd

/// Writes .ksplat format (mkkellogg/GaussianSplats3D)
/// Spec: src/loaders/SplatBuffer.js → writeHeaderToBuffer + parseSectionHeaders
///
/// FILE LAYOUT:
///   [0 .. 4095]      File Header      (4096 bytes, HeaderSizeBytes)
///   [4096 .. 5119]   Section Header   (1024 bytes, SectionHeaderSizeBytes)
///   [5120 .. 5120+B] Bucket data      (bucketCount * 12 bytes)
///   [5120+B ..]      Splat data       (splatCount * 24 bytes, compression level 1)
final class KSplatWriter {
    let compressionLevel: Int

    init(compressionLevel: Int = 1) {
        self.compressionLevel = min(max(compressionLevel, 0), 2)
    }

    func write(cloud: GaussianCloud, to path: String) throws {
        let splatCount    = UInt32(cloud.count)
        let bucketSize    = UInt32(256)
        let bucketCount   = UInt32((cloud.count + 255) / 256)
        let blockSize     = Float(SplatBuffer.BucketBlockSize)
        // compressionScaleRange for level 1
        let scaleRange    = UInt32(32767)
        // Bucket storage: 12 bytes per bucket (3 × Float32 center)
        let bucketStorageBytes = UInt16(12)
        let fullBucketCount    = UInt32(cloud.count / 256)
        let partialCount       = UInt32(cloud.count % 256 > 0 ? 1 : 0)

        // ─────────────────────────────────────────────
        // 1. FILE HEADER  (4096 bytes)
        //    Offsets are byte offsets into a Uint8/Uint16/Uint32 view:
        //    uint8[0]   = versionMajor (0)
        //    uint8[1]   = versionMinor (1)
        //    uint8[2-3] = 0
        //    uint32[1] (bytes 4-7)   = maxSectionCount
        //    uint32[2] (bytes 8-11)  = sectionCount
        //    uint32[3] (bytes 12-15) = maxSplatCount
        //    uint32[4] (bytes 16-19) = splatCount
        //    uint16[10] (bytes 20-21)= compressionLevel
        // ─────────────────────────────────────────────
        var header = Data(count: SplatBuffer.HeaderSizeBytes)
        header[0] = 0                               // versionMajor = 0
        header[1] = 1                               // versionMinor = 1
        header[2] = 0
        header[3] = 0
        writeU32(&header, offset: 4,  value: 1)            // maxSectionCount
        writeU32(&header, offset: 8,  value: 1)            // sectionCount
        writeU32(&header, offset: 12, value: splatCount)   // maxSplatCount
        writeU32(&header, offset: 16, value: splatCount)   // splatCount
        writeU16(&header, offset: 20, value: UInt16(compressionLevel)) // compressionLevel
        // sceneCenter (float32[6..8]) = 0,0,0 — already zeroed
        // SH range (float32[9..10]) = 0 — will use default in loader

        // ─────────────────────────────────────────────
        // 2. SECTION HEADER  (1024 bytes)
        //    uint32[0] (bytes 0-3)   = splatCount
        //    uint32[1] (bytes 4-7)   = maxSplatCount
        //    uint32[2] (bytes 8-11)  = bucketSize
        //    uint32[3] (bytes 12-15) = bucketCount
        //    float32[4] (bytes 16-19)= bucketBlockSize
        //    ---- byte 20-21 ----
        //    uint16[10] (bytes 20-21)= bucketStorageSizeBytes
        //    uint32[6] (bytes 24-27) = compressionScaleRange
        //    uint32[8] (bytes 32-35) = fullBucketCount
        //    uint32[9] (bytes 36-39) = partiallyFilledBucketCount
        // ─────────────────────────────────────────────
        var sectionHdr = Data(count: SplatBuffer.SectionHeaderSizeBytes)
        writeU32(&sectionHdr, offset: 0,  value: splatCount)       // splatCount
        writeU32(&sectionHdr, offset: 4,  value: splatCount)       // maxSplatCount
        writeU32(&sectionHdr, offset: 8,  value: bucketSize)       // bucketSize
        writeU32(&sectionHdr, offset: 12, value: bucketCount)      // bucketCount
        writeF32(&sectionHdr, offset: 16, value: blockSize)        // bucketBlockSize
        writeU16(&sectionHdr, offset: 20, value: bucketStorageBytes) // bucketStorageSizeBytes (uint16[10])
        writeU32(&sectionHdr, offset: 24, value: scaleRange)       // compressionScaleRange
        writeU32(&sectionHdr, offset: 32, value: fullBucketCount)  // fullBucketCount
        writeU32(&sectionHdr, offset: 36, value: partialCount)     // partiallyFilledBucketCount

        // ─────────────────────────────────────────────
        // 3. BUCKET DATA
        //    partiallyFilledBucketCount × 4 bytes (lengths)
        //    bucketCount × 12 bytes (centers: 3 × float32)
        // ─────────────────────────────────────────────
        var bucketData = Data()
        // partial bucket lengths (uint32 each)
        if partialCount > 0 {
            let remainder = UInt32(cloud.count % 256)
            appendU32(&bucketData, remainder)
        }
        // Compute bucket centers (average position per bucket)
        for b in 0..<Int(bucketCount) {
            let start = b * 256
            let end   = min(start + 256, cloud.count)
            var cx: Float = 0, cy: Float = 0, cz: Float = 0
            for i in start..<end {
                cx += cloud.splats[i].position.x
                cy += cloud.splats[i].position.y
                cz += cloud.splats[i].position.z
            }
            let n = Float(end - start)
            appendF32(&bucketData, cx / n)
            appendF32(&bucketData, cy / n)
            appendF32(&bucketData, cz / n)
        }

        // ─────────────────────────────────────────────
        // 4. SPLAT DATA  (24 bytes per splat, compressionLevel = 1)
        //    Layout (CompressionLevels[1]):
        //     0- 5: center    3 × f16
        //     6-11: scale     3 × f16
        //    12-19: rotation  4 × f16  (order: w, x, y, z per shader expectation)
        //    20-23: color     4 × uint8 (RGBA)
        // ─────────────────────────────────────────────
        var splatData = Data()
        splatData.reserveCapacity(cloud.count * 24)

        let halfRange = Float(scaleRange)   // 32767

        for (bi, splat) in cloud.splats.enumerated() {
            let bucketIdx = bi / 256
            // bucket centers already computed — recompute inline for encoding
            // (quantise position relative to bucket center)
            let startBI = bucketIdx * 256
            let endBI   = min(startBI + 256, cloud.count)
            var bcx: Float = 0, bcy: Float = 0, bcz: Float = 0
            for i in startBI..<endBI {
                bcx += cloud.splats[i].position.x
                bcy += cloud.splats[i].position.y
                bcz += cloud.splats[i].position.z
            }
            let n = Float(endBI - startBI)
            bcx /= n; bcy /= n; bcz /= n

            // ScaleFactor: bucket covers blockSize * 2 at half = 2.5
            let sf: Float = blockSize / halfRange  // ≈0.000152...
            // Quantise relative position
            let qx = UInt16(clamped: Int((splat.position.x - bcx) / sf) + Int(halfRange))
            let qy = UInt16(clamped: Int((splat.position.y - bcy) / sf) + Int(halfRange))
            let qz = UInt16(clamped: Int((splat.position.z - bcz) / sf) + Int(halfRange))
            appendU16Raw(&splatData, qx)
            appendU16Raw(&splatData, qy)
            appendU16Raw(&splatData, qz)

            // Scale (log space → f16)
            appendF16(&splatData, splat.scale.x)
            appendF16(&splatData, splat.scale.y)
            appendF16(&splatData, splat.scale.z)

            // Rotation quaternion (w, x, y, z) as f16
            appendF16(&splatData, splat.rotation.real)
            appendF16(&splatData, splat.rotation.imag.x)
            appendF16(&splatData, splat.rotation.imag.y)
            appendF16(&splatData, splat.rotation.imag.z)

            // Color RGBA uint8
            splatData.append(splat.color.x)
            splatData.append(splat.color.y)
            splatData.append(splat.color.z)
            splatData.append(splat.color.w)
        }

        // ─────────────────────────────────────────────
        // Assemble and write
        // ─────────────────────────────────────────────
        var output = Data()
        output.append(header)
        output.append(sectionHdr)
        output.append(bucketData)
        output.append(splatData)

        try output.write(to: URL(fileURLWithPath: path))
    }

    // ── Write helpers (little-endian) ──
    private func writeU8(_ data: inout Data, offset: Int, value: UInt8) {
        data[offset] = value
    }
    private func writeU16(_ data: inout Data, offset: Int, value: UInt16) {
        let v = value.littleEndian
        data[offset]     = UInt8(v & 0xFF)
        data[offset + 1] = UInt8((v >> 8) & 0xFF)
    }
    private func writeU32(_ data: inout Data, offset: Int, value: UInt32) {
        let v = value.littleEndian
        data[offset]     = UInt8(v & 0xFF)
        data[offset + 1] = UInt8((v >> 8) & 0xFF)
        data[offset + 2] = UInt8((v >> 16) & 0xFF)
        data[offset + 3] = UInt8((v >> 24) & 0xFF)
    }
    private func writeF32(_ data: inout Data, offset: Int, value: Float) {
        writeU32(&data, offset: offset, value: value.bitPattern)
    }

    private func appendU32(_ data: inout Data, _ v: UInt32) {
        var val = v.littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &val) { Array($0) })
    }
    private func appendU16Raw(_ data: inout Data, _ v: UInt16) {
        var val = v.littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &val) { Array($0) })
    }
    private func appendF32(_ data: inout Data, _ v: Float) {
        appendU32(&data, v.bitPattern)
    }
    private func appendF16(_ data: inout Data, _ v: Float) {
        var val = floatToHalf(v).littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &val) { Array($0) })
    }

    private func floatToHalf(_ value: Float) -> UInt16 {
        let bits = value.bitPattern
        let sign = (bits >> 31) & 1
        let exponent = Int((bits >> 23) & 0xFF) - 127
        let mantissa = bits & 0x7FFFFF
        if exponent > 15 { return UInt16(sign << 15) | 0x7C00 }
        else if exponent < -14 {
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

// ── Layout constants mirroring SplatBuffer.js ──
private enum SplatBuffer {
    static let HeaderSizeBytes        = 4096
    static let SectionHeaderSizeBytes = 1024
    static let BucketBlockSize: Float = 5.0
    static let BucketSize             = 256
}

private extension UInt16 {
    init(clamped value: Int) {
        self = UInt16(Swift.max(0, Swift.min(Int(UInt16.max), value)))
    }
}
