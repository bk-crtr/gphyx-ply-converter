// File: GaussianCloud.swift
import Foundation
import simd

/// Per-splat data in raw (untransformed) form from PLY, then transformed in-place.
/// After transform: opacity = sigmoid(raw), scale = exp(raw), quaternion normalized, color = SH→RGB
struct GaussianSplat {
    var position: SIMD3<Float>      // xyz
    var scale: SIMD3<Float>         // raw from PLY → exp() after transform
    var rotation: simd_quatf        // raw from PLY → normalized after transform
    var opacity: Float              // raw from PLY → sigmoid after transform
    var color: SIMD4<UInt8>         // RGBA 0-255, computed from SH DC after transform
    var shDC: SIMD3<Float>          // f_dc_0/1/2 raw
    var shRest: [Float]             // f_rest_0..N raw
}

/// Cloud of Gaussian splats with metadata
struct GaussianCloud {
    var splats: [GaussianSplat]
    var shDegree: Int               // 0, 1, 2, or 3
    var isTransformed: Bool = false

    var count: Int { splats.count }

    /// Number of SH rest coefficients per splat based on degree
    var shRestCount: Int {
        switch shDegree {
        case 0: return 0
        case 1: return 9
        case 2: return 24
        case 3: return 45
        default: return 0
        }
    }

    /// Number of SH coefficients per channel for a given degree
    static func shCoeffsPerChannel(degree: Int) -> Int {
        switch degree {
        case 0: return 1
        case 1: return 4    // 1 + 3
        case 2: return 9    // 1 + 3 + 5
        case 3: return 16   // 1 + 3 + 5 + 7
        default: return 1
        }
    }

    mutating func capSHDegree(to degree: Int) {
        guard degree < shDegree else { return }
        let newRestCount: Int
        switch degree {
        case 0: newRestCount = 0
        case 1: newRestCount = 9
        case 2: newRestCount = 24
        default: return
        }
        for i in splats.indices {
            if splats[i].shRest.count > newRestCount {
                splats[i].shRest = Array(splats[i].shRest.prefix(newRestCount))
            }
        }
        shDegree = degree
    }

    /// CPU fallback for transform
    mutating func transformCPU() {
        guard !isTransformed else { return }
        let SH_C0: Float = 0.28209479177387814

        for i in splats.indices {
            // sigmoid(opacity)
            splats[i].opacity = 1.0 / (1.0 + exp(-splats[i].opacity))

            // exp(scale)
            splats[i].scale = SIMD3(
                exp(splats[i].scale.x),
                exp(splats[i].scale.y),
                exp(splats[i].scale.z)
            )

            // normalize quaternion
            let q = splats[i].rotation
            let len = sqrt(q.real * q.real + simd_dot(q.imag, q.imag))
            if len > 0 {
                splats[i].rotation = simd_quatf(
                    ix: q.imag.x / len,
                    iy: q.imag.y / len,
                    iz: q.imag.z / len,
                    r: q.real / len
                )
            }

            // SH DC → RGB
            let r = clampByte(splats[i].shDC.x * SH_C0 + 0.5)
            let g = clampByte(splats[i].shDC.y * SH_C0 + 0.5)
            let b = clampByte(splats[i].shDC.z * SH_C0 + 0.5)
            let a = clampByte(splats[i].opacity)
            splats[i].color = SIMD4(r, g, b, a)
        }
        isTransformed = true
    }

    mutating func filterByAlpha(minAlpha: UInt8) {
        splats.removeAll { $0.color.w < minAlpha }
    }
}

func clampByte(_ v: Float) -> UInt8 {
    UInt8(max(0, min(255, v * 255.0)))
}
