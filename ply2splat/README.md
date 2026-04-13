# ply2splat — Metal-Accelerated Gaussian Splat Converter

Standalone macOS CLI tool for converting 3D Gaussian Splat `.ply` files to `.splat`, `.ksplat`, and `.spz` formats.

Part of the **GPHYX** GaussianSplatFX plugin toolkit.

## Requirements

- macOS 14+ (Sonoma)
- Apple Silicon (M1/M2/M3/M4) recommended
- Xcode 15+ / Swift 5.9+

## Build

```bash
cd ply2splat
swift build -c release
```

Binary will be at `.build/release/ply2splat`.

To install system-wide:

```bash
cp .build/release/ply2splat /usr/local/bin/
```

## Usage

```bash
# Convert to all three formats at once
ply2splat scene.ply --all scene

# Individual formats
ply2splat scene.ply --splat scene.splat
ply2splat scene.ply --ksplat scene.ksplat --compression 1
ply2splat scene.ply --spz scene.spz

# Multiple outputs in one pass
ply2splat scene.ply --splat out.splat --spz out.spz --verbose

# Options
ply2splat scene.ply --all scene \
    --sh-degree 2 \
    --compression 1 \
    --alpha-threshold 10 \
    --verbose
```

## Output Formats

| Format   | Extension | Description                           | SH Support | Size     |
|----------|-----------|---------------------------------------|------------|----------|
| `.splat` | .splat    | antimatter15 WebGL viewer format      | No (DC→RGB)| 32 B/splat |
| `.ksplat`| .ksplat   | GaussianSplats3D (mkkellogg) format   | Yes (0-3)  | Variable |
| `.spz`   | .spz      | Niantic Scaniverse compressed format  | Yes (0-3)  | ~10× smaller |

## Options

| Flag                  | Default | Description                              |
|-----------------------|---------|------------------------------------------|
| `--sh-degree <0-3>`   | auto    | Max SH degree to preserve                |
| `--compression <0-2>` | 1       | KSPLAT compression (0=none, 1=f16, 2=f16+u8 SH) |
| `--alpha-threshold`   | 1       | Remove splats with alpha < threshold     |
| `--no-metal`          | off     | Disable Metal GPU, use CPU fallback      |
| `--verbose`           | off     | Detailed progress output                 |

## Architecture

```
Input .ply
    │
    ▼
PLYParser (CPU) → GaussianCloud (raw data in memory)
    │
    ▼
MetalTransformer (GPU compute) — sigmoid, exp, normalize, SH→RGB
    │
    ├── SplatWriter  → .splat  (32 bytes/splat, no SH)
    ├── KSplatWriter → .ksplat (sectioned, compressed, with SH)
    └── SPZWriter    → .spz    (zlib-compressed, coordinate transform)
```

**Metal compute** handles the math-heavy transforms (sigmoid, exp, quaternion normalization, SH→RGB conversion) in parallel across all splats. For a 2M splat scene this is typically 10-50× faster than CPU.

## Integration with GaussianSplatFX

Place the `ply2splat` binary alongside your FxPlug bundle, or install it to a known path. Your plugin can invoke it via `Process`:

```swift
let process = Process()
process.executableURL = URL(fileURLWithPath: "/path/to/ply2splat")
process.arguments = [plyPath, "--all", outputBasename, "--verbose"]
try process.run()
process.waitUntilExit()
```

## License

© GPHYX 2025. All rights reserved.
