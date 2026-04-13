// File: SPZWriter.swift
import Foundation
import simd

/// Writes .spz format (Niantic Labs)
///
/// SPZ binary layout:
///   Header (16 bytes):
///     [0..3]   magic: "SPZ\0" (4 bytes)
///     [4..7]   version: u32 (currently 2)
///     [8..11]  numPoints: u32
///     [12]     shDegree: u8
///     [13]     flags: u8 (bit 0 = antialiased)
///     [14..15] reserved: u16
///
///   Then zlib-compressed payload:
///     positions:  numPoints × 3 × f32 (little-endian)
///     alphas:     numPoints × 1 × u8 (quantized 0-255)
///     colors:     numPoints × 3 × u8 (SH DC → RGB, 0-255)
///     scales:     numPoints × 3 × u8 (quantized log-scale)
///     rotations:  numPoints × 4 × u8 (quaternion)
///     sh:         numPoints × shCoeffs × 3 × u8 (quantized)
///
/// Note: SPZ uses RUB coordinate system (right-up-back, OpenGL convention).
/// PLY typically uses RDF. We do the conversion: PLY(x,y,z) → SPZ(x,-y,-z).
final class SPZWriter {

    func write(cloud: GaussianCloud, to path: String) throws {
        let count = cloud.count
        guard count > 0 else { throw SPZError.emptyCloud }

        var headerData = Data()

        // Magic
        headerData.append(contentsOf: [0x53, 0x50, 0x5A, 0x00]) // "SPZ\0"
        // Version
        appendU32(&headerData, 2)
        // numPoints
        appendU32(&headerData, UInt32(count))
        // shDegree
        headerData.append(UInt8(cloud.shDegree))
        // flags (0 = not antialiased)
        headerData.append(0)
        // reserved
        headerData.append(contentsOf: [0, 0])

        // ── Build payload (uncompressed) ──
        var payload = Data()

        // Positions: N × 3 × f32
        // Coordinate transform: PLY RDF → SPZ RUB: (x, -y, -z)
        for splat in cloud.splats {
            appendF32(&payload, splat.position.x)
            appendF32(&payload, -splat.position.y)
            appendF32(&payload, -splat.position.z)
        }

        // Alphas: N × u8
        for splat in cloud.splats {
            payload.append(splat.color.w)
        }

        // Colors: N × 3 × u8
        for splat in cloud.splats {
            payload.append(splat.color.x)
            payload.append(splat.color.y)
            payload.append(splat.color.z)
        }

        // Scales: N × 3 × u8 (quantized log-scale)
        let logScales = cloud.splats.map { s -> SIMD3<Float> in
            SIMD3(
                log(max(s.scale.x, 1e-10)),
                log(max(s.scale.y, 1e-10)),
                log(max(s.scale.z, 1e-10))
            )
        }

        var minLog = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var maxLog = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        for ls in logScales {
            minLog = simd_min(minLog, ls)
            maxLog = simd_max(maxLog, ls)
        }
        let globalMinLog = min(minLog.x, min(minLog.y, minLog.z))
        let globalMaxLog = max(maxLog.x, max(maxLog.y, maxLog.z))
        let logRange = globalMaxLog - globalMinLog
        let logScale = logRange > 0 ? 255.0 / logRange : 0

        for ls in logScales {
            payload.append(quantize(ls.x, min: globalMinLog, scale: logScale))
            payload.append(quantize(ls.y, min: globalMinLog, scale: logScale))
            payload.append(quantize(ls.z, min: globalMinLog, scale: logScale))
        }

        // Rotations: N × 4 × u8
        for splat in cloud.splats {
            let q = splat.rotation
            let sign: Float = q.real >= 0 ? 1.0 : -1.0
            payload.append(quatToU8(q.real * sign))
            payload.append(quatToU8(q.imag.x * sign))
            payload.append(quatToU8(q.imag.y * sign))
            payload.append(quatToU8(q.imag.z * sign))
        }

        // SH coefficients (for degree > 0)
        if cloud.shDegree > 0 {
            let restCount = cloud.splats.first?.shRest.count ?? 0
            if restCount > 0 {
                var shMin: Float = .greatestFiniteMagnitude
                var shMax: Float = -.greatestFiniteMagnitude
                for splat in cloud.splats {
                    for c in splat.shRest {
                        shMin = min(shMin, c)
                        shMax = max(shMax, c)
                    }
                }
                let shRange = shMax - shMin
                let shScale = shRange > 0 ? 255.0 / shRange : 0

                for splat in cloud.splats {
                    for c in splat.shRest {
                        payload.append(quantize(c, min: shMin, scale: shScale))
                    }
                }
            }
        }

        // ── Compress payload with zlib ──
        let compressed = try zlibCompress(payload)

        // ── Write file: header + compressed payload ──
        var output = headerData
        output.append(compressed)

        try output.write(to: URL(fileURLWithPath: path))
    }

    // ── Helpers ──

    private func quantize(_ v: Float, min minVal: Float, scale: Float) -> UInt8 {
        UInt8(Swift.max(0, Swift.min(255, ((v - minVal) * scale).rounded())))
    }

    private func quatToU8(_ v: Float) -> UInt8 {
        UInt8(max(0, min(255, ((v + 1.0) * 0.5 * 255.0).rounded())))
    }

    private func appendU32(_ data: inout Data, _ v: UInt32) {
        var val = v; data.append(contentsOf: withUnsafeBytes(of: &val) { Array($0) })
    }

    private func appendF32(_ data: inout Data, _ v: Float) {
        var val = v; data.append(contentsOf: withUnsafeBytes(of: &val) { Array($0) })
    }

    /// Zlib compression (deflate) using system libz
    private func zlibCompress(_ data: Data) throws -> Data {
        return try data.withUnsafeBytes { rawBuffer -> Data in
            let sourcePtr = rawBuffer.bindMemory(to: UInt8.self)
            let sourceLen = data.count

            let destLen = sourceLen + sourceLen / 100 + 12 + 256
            var dest = [UInt8](repeating: 0, count: destLen)
            var actualLen = UInt(destLen)

            let result = compress2(
                &dest,
                &actualLen,
                sourcePtr.baseAddress!,
                UInt(sourceLen),
                6  // compression level
            )

            guard result == 0 /* Z_OK */ else {
                throw SPZError.compressionFailed
            }

            return Data(dest.prefix(Int(actualLen)))
        }
    }
}

// Import zlib's compress2 function
@_silgen_name("compress2")
func compress2(
    _ dest: UnsafeMutablePointer<UInt8>,
    _ destLen: UnsafeMutablePointer<UInt>,
    _ source: UnsafePointer<UInt8>,
    _ sourceLen: UInt,
    _ level: Int32
) -> Int32

enum SPZError: LocalizedError {
    case emptyCloud
    case compressionFailed

    var errorDescription: String? {
        switch self {
        case .emptyCloud: return "Cannot write SPZ: cloud is empty"
        case .compressionFailed: return "Zlib compression failed"
        }
    }
}
