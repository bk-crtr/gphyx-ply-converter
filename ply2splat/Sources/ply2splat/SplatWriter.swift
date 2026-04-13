// File: SplatWriter.swift
import Foundation
import simd

/// Writes .splat format (antimatter15)
/// Layout: 32 bytes per splat, no header, no SH
/// [pos_x:f32][pos_y:f32][pos_z:f32][scale_x:f32][scale_y:f32][scale_z:f32][r:u8][g:u8][b:u8][a:u8][quat_w:u8][quat_x:u8][quat_y:u8][quat_z:u8]
/// Total: 24 (6 floats) + 4 (RGBA) + 4 (quaternion as u8) = 32 bytes
final class SplatWriter {

    func write(cloud: GaussianCloud, to path: String) throws {
        let count = cloud.count
        let bytesPerSplat = 32
        var buffer = Data(capacity: count * bytesPerSplat)

        for splat in cloud.splats {
            // Position (3 × float32 = 12 bytes)
            var px = splat.position.x; buffer.append(contentsOf: withUnsafeBytes(of: &px) { Array($0) })
            var py = splat.position.y; buffer.append(contentsOf: withUnsafeBytes(of: &py) { Array($0) })
            var pz = splat.position.z; buffer.append(contentsOf: withUnsafeBytes(of: &pz) { Array($0) })

            // Scale (3 × float32 = 12 bytes) — already exp'd
            var sx = splat.scale.x; buffer.append(contentsOf: withUnsafeBytes(of: &sx) { Array($0) })
            var sy = splat.scale.y; buffer.append(contentsOf: withUnsafeBytes(of: &sy) { Array($0) })
            var sz = splat.scale.z; buffer.append(contentsOf: withUnsafeBytes(of: &sz) { Array($0) })

            // Color RGBA (4 bytes)
            buffer.append(splat.color.x)  // R
            buffer.append(splat.color.y)  // G
            buffer.append(splat.color.z)  // B
            buffer.append(splat.color.w)  // A

            // Quaternion as 4 × uint8 (normalized -1..1 → 0..255)
            // .splat format: [w, x, y, z] encoded as (q * 128 + 128)
            let q = splat.rotation
            buffer.append(quatToU8(q.real))    // w
            buffer.append(quatToU8(q.imag.x))  // x
            buffer.append(quatToU8(q.imag.y))  // y
            buffer.append(quatToU8(q.imag.z))  // z
        }

        try buffer.write(to: URL(fileURLWithPath: path))
    }

    private func quatToU8(_ v: Float) -> UInt8 {
        UInt8(max(0, min(255, (v * 128.0 + 128.0).rounded())))
    }
}
