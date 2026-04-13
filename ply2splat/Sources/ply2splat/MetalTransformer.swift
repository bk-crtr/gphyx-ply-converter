// File: MetalTransformer.swift
import Foundation
import Metal
import simd

enum MetalError: LocalizedError {
    case noDevice
    case noQueue
    case shaderCompilationFailed(String)
    case bufferCreationFailed

    var errorDescription: String? {
        switch self {
        case .noDevice: return "No Metal device available"
        case .noQueue: return "Failed to create command queue"
        case .shaderCompilationFailed(let e): return "Metal shader compilation failed: \(e)"
        case .bufferCreationFailed: return "Failed to create Metal buffer"
        }
    }
}

/// GPU-packed splat for Metal compute (matches struct in shader)
struct GPUSplat {
    var px: Float; var py: Float; var pz: Float    // position
    var sx: Float; var sy: Float; var sz: Float    // scale (raw → exp)
    var qx: Float; var qy: Float; var qz: Float; var qw: Float  // quaternion (raw → normalized)
    var opacity: Float                              // raw → sigmoid
    var dcR: Float; var dcG: Float; var dcB: Float // SH DC coefficients
    // Output
    var r: UInt8; var g: UInt8; var b: UInt8; var a: UInt8 // computed RGBA
    var _pad: Float  // alignment padding
}

final class MetalTransformer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLComputePipelineState

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw MetalError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw MetalError.noQueue }
        self.device = device
        self.queue = queue

        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct GPUSplat {
            float px, py, pz;
            float sx, sy, sz;
            float qx, qy, qz, qw;
            float opacity;
            float dcR, dcG, dcB;
            uchar r, g, b, a;
            float _pad;
        };

        kernel void transformSplats(
            device GPUSplat *splats [[buffer(0)]],
            constant uint &count [[buffer(1)]],
            uint gid [[thread_position_in_grid]]
        ) {
            if (gid >= count) return;

            // sigmoid(opacity)
            float sig = 1.0f / (1.0f + exp(-splats[gid].opacity));
            splats[gid].opacity = sig;

            // exp(scale)
            splats[gid].sx = exp(splats[gid].sx);
            splats[gid].sy = exp(splats[gid].sy);
            splats[gid].sz = exp(splats[gid].sz);

            // normalize quaternion
            float qx = splats[gid].qx;
            float qy = splats[gid].qy;
            float qz = splats[gid].qz;
            float qw = splats[gid].qw;
            float len = sqrt(qx*qx + qy*qy + qz*qz + qw*qw);
            if (len > 0.0f) {
                float inv = 1.0f / len;
                splats[gid].qx = qx * inv;
                splats[gid].qy = qy * inv;
                splats[gid].qz = qz * inv;
                splats[gid].qw = qw * inv;
            }

            // SH DC → RGB (SH_C0 = 0.28209479177387814)
            float SH_C0 = 0.28209479177387814f;
            float rf = splats[gid].dcR * SH_C0 + 0.5f;
            float gf = splats[gid].dcG * SH_C0 + 0.5f;
            float bf = splats[gid].dcB * SH_C0 + 0.5f;

            splats[gid].r = uchar(clamp(rf * 255.0f, 0.0f, 255.0f));
            splats[gid].g = uchar(clamp(gf * 255.0f, 0.0f, 255.0f));
            splats[gid].b = uchar(clamp(bf * 255.0f, 0.0f, 255.0f));
            splats[gid].a = uchar(clamp(sig * 255.0f, 0.0f, 255.0f));
        }
        """

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            guard let function = library.makeFunction(name: "transformSplats") else {
                throw MetalError.shaderCompilationFailed("transformSplats not found")
            }
            pipeline = try device.makeComputePipelineState(function: function)
        } catch let error as MetalError {
            throw error
        } catch {
            throw MetalError.shaderCompilationFailed(error.localizedDescription)
        }
    }

    func transform(_ cloud: inout GaussianCloud) throws {
        guard !cloud.isTransformed else { return }
        let count = cloud.count
        guard count > 0 else { return }

        // Pack into GPU struct
        var gpuSplats = [GPUSplat]()
        gpuSplats.reserveCapacity(count)
        for s in cloud.splats {
            gpuSplats.append(GPUSplat(
                px: s.position.x, py: s.position.y, pz: s.position.z,
                sx: s.scale.x, sy: s.scale.y, sz: s.scale.z,
                qx: s.rotation.imag.x, qy: s.rotation.imag.y,
                qz: s.rotation.imag.z, qw: s.rotation.real,
                opacity: s.opacity,
                dcR: s.shDC.x, dcG: s.shDC.y, dcB: s.shDC.z,
                r: 0, g: 0, b: 0, a: 0,
                _pad: 0
            ))
        }

        let bufferSize = MemoryLayout<GPUSplat>.stride * count
        guard let buffer = device.makeBuffer(
            bytes: &gpuSplats,
            length: bufferSize,
            options: .storageModeShared
        ) else { throw MetalError.bufferCreationFailed }

        var splatCount = UInt32(count)
        guard let countBuffer = device.makeBuffer(
            bytes: &splatCount,
            length: MemoryLayout<UInt32>.size,
            options: .storageModeShared
        ) else { throw MetalError.bufferCreationFailed }

        guard let cmdBuffer = queue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            throw MetalError.noQueue
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setBuffer(countBuffer, offset: 0, index: 1)

        let threadgroupSize = MTLSize(width: min(pipeline.threadExecutionWidth, count), height: 1, depth: 1)
        let threadgroups = MTLSize(width: (count + threadgroupSize.width - 1) / threadgroupSize.width, height: 1, depth: 1)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()

        // Read back
        let resultPtr = buffer.contents().bindMemory(to: GPUSplat.self, capacity: count)
        for i in 0..<count {
            let g = resultPtr[i]
            cloud.splats[i].scale = SIMD3(g.sx, g.sy, g.sz)
            cloud.splats[i].rotation = simd_quatf(ix: g.qx, iy: g.qy, iz: g.qz, r: g.qw)
            cloud.splats[i].opacity = g.opacity
            cloud.splats[i].color = SIMD4(g.r, g.g, g.b, g.a)
        }

        cloud.isTransformed = true
    }
}
