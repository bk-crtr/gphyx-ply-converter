// File: KSplatWriter.swift
import Foundation
import simd

/// Writes .ksplat format (uncompressed version)
/// Structure:
/// [FILE HEADER - 4096 bytes]
/// [SECTION HEADER - 1024 bytes]
/// [SPLAT DATA - splatCount * 32 bytes]
final class KSplatWriter {
    let compressionLevel: Int

    init(compressionLevel: Int = 0) {
        // Force compression level 0 for this specific implementation
        self.compressionLevel = 0
    }

    func write(cloud: GaussianCloud, to path: String) throws {
        let splatCount = UInt32(cloud.count)
        let bucketSize = UInt32(256)
        let bucketCount = UInt32((cloud.count + 255) / 256)

        // ─────────────────────────────────────────────
        // 1. FILE HEADER (4096 bytes)
        // ─────────────────────────────────────────────
        var header = Data(count: 4096)
        header[0] = 0x00 // version major
        header[1] = 0x01 // version minor
        header[2] = 0x00
        header[3] = 0x00
        
        // bytes 4-7: splatCount (uint32 LE)
        writeU32(&header, offset: 4, value: splatCount)
        // bytes 8-11: splatCount (uint32 LE)
        writeU32(&header, offset: 8, value: splatCount)
        // bytes 12-15: compression = 0
        writeU32(&header, offset: 12, value: 0)
        
        // ─────────────────────────────────────────────
        // 2. SECTION HEADER (1024 bytes)
        // ─────────────────────────────────────────────
        var sectionHdr = Data(count: 1024)
        // bytes 0-3: splatCount (uint32 LE)
        writeU32(&sectionHdr, offset: 0, value: splatCount)
        // bytes 4-7: splatCount (uint32 LE)
        writeU32(&sectionHdr, offset: 4, value: splatCount)
        // bytes 8-11: 256 (bucketSize, uint32 LE)
        writeU32(&sectionHdr, offset: 8, value: bucketSize)
        // bytes 12-15: bucketCount (uint32 LE)
        writeU32(&sectionHdr, offset: 12, value: bucketCount)

        // ─────────────────────────────────────────────
        // 3. SPLAT DATA (splatCount * 32 bytes)
        //    px, py, pz (f32)
        //    sx, sy, sz (f32)
        //    r, g, b, a (u8)
        //    qw, qx, qy, qz (u8)
        // ─────────────────────────────────────────────
        var splatData = Data()
        splatData.reserveCapacity(cloud.count * 32)

        for splat in cloud.splats {
            // Position (3 × float32 = 12 bytes)
            appendF32(&splatData, splat.position.x)
            appendF32(&splatData, splat.position.y)
            appendF32(&splatData, splat.position.z)

            // Scale (3 × float32 = 12 bytes)
            appendF32(&splatData, splat.scale.x)
            appendF32(&splatData, splat.scale.y)
            appendF32(&splatData, splat.scale.z)

            // Color RGBA (4 bytes)
            splatData.append(splat.color.x) // R
            splatData.append(splat.color.y) // G
            splatData.append(splat.color.z) // B
            splatData.append(splat.color.w) // A

            // Rotation quaternion (normalized -1..1 → 0..255)
            // Layout: qw, qx, qy, qz (4 × u8)
            let q = splat.rotation
            splatData.append(quatToU8(q.real))   // w
            splatData.append(quatToU8(q.imag.x)) // x
            splatData.append(quatToU8(q.imag.y)) // y
            splatData.append(quatToU8(q.imag.z)) // z
        }

        // ─────────────────────────────────────────────
        // Assemble and write
        // ─────────────────────────────────────────────
        var output = Data()
        output.append(header)
        output.append(sectionHdr)
        output.append(splatData)

        try output.write(to: URL(fileURLWithPath: path))
    }

    // ── Write helpers (little-endian) ──
    private func writeU32(_ data: inout Data, offset: Int, value: UInt32) {
        let v = value.littleEndian
        data[offset]     = UInt8(v & 0xFF)
        data[offset + 1] = UInt8((v >> 8) & 0xFF)
        data[offset + 2] = UInt8((v >> 16) & 0xFF)
        data[offset + 3] = UInt8((v >> 24) & 0xFF)
    }

    private func appendU32(_ data: inout Data, _ v: UInt32) {
        var val = v.littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &val) { Array($0) })
    }

    private func appendF32(_ data: inout Data, _ v: Float) {
        appendU32(&data, v.bitPattern)
    }

    private func quatToU8(_ v: Float) -> UInt8 {
        UInt8(max(0, min(255, (v * 128.0 + 128.0).rounded())))
    }
}
