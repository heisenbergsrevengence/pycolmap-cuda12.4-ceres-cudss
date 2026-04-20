# pycolmap-cuda-12 Docker Build

A Docker build for [pycolmap](https://github.com/colmap/colmap) with full CUDA GPU acceleration, including cuDSS sparse solver support for high-performance global mapping.
## Features

- **CUDA 12.4.1** with cuDNN on Ubuntu 22.04
- **cuDSS** sparse direct solver for GPU-accelerated linear algebra
- **Ceres Solver** built from source with CUDA/cuDSS support
- **COLMAP 4.0.3** with full GPU acceleration
- **pycolmap** Python bindings for COLMAP
- Multi-stage build with layer caching for fast rebuilds
- Pinned dependencies for reproducible builds

[prebuilt docker](https://hub.docker.com/repository/docker/setoaisle/pycolmap-cuda12-cudss-ceres/general)

## Requirements

- Docker 23.0+ with BuildKit support
- NVIDIA GPU with Compute Capability 8.6+ (RTX 30xx) or 8.9+ (RTX 40xx)
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html)

## Pinned Versions

| Component | Version | Commit/Tag | Date |
|-----------|---------|------------|------|
| CUDA | 12.4.1 | - | - |
| cuDSS | 0.7.1 | - | - |
| Ceres Solver | master | `806af05` | 2026-04-08 |
| COLMAP | 4.0.3 | `e5b4a3e` | 2025-04-06 |

## Build

```bash
# Standard build
docker build -t pycolmap:latest .

# Build with custom CUDA architectures
docker build \
    --build-arg CUDA_ARCHITECTURES="86;89;90" \
    -t pycolmap:latest .
```

## Usage

```bash
# Run interactive Python session
docker run --gpus all -it pycolmap:latest

# Run with mounted data directory
docker run --gpus all -it \
    -v /path/to/images:/workspace/images \
    pycolmap:latest

# Run a specific script
docker run --gpus all \
    -v /path/to/project:/workspace \
    pycolmap:latest python3 /workspace/reconstruct.py
```

## Example: Basic Reconstruction

```python
import pycolmap

# Run automatic reconstruction
pycolmap.automatic_reconstructor(
    workspace_path="/workspace/output",
    image_path="/workspace/images",
)
```

## Build Architecture

The Dockerfile uses a multi-stage build for efficient caching:

```
┌─────────────────────────────────────────────────────────────┐
│ Stage 1: base                                               │
│   CUDA 12.4.1 + System packages + cuDSS                     │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ Stage 2: ceres-build                                        │
│   Ceres Solver with CUDA/cuDSS support                      │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ Stage 3: colmap-build                                       │
│   COLMAP 4.0.3 with GPU acceleration                        │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ Stage 4: pycolmap (final)                                   │
│   Python bindings + runtime environment                     │
└─────────────────────────────────────────────────────────────┘
```

## GPU Support

### Supported CUDA Architectures

The default build targets:
- **SM 8.6**: RTX 30xx series (Ampere)
- **SM 8.9**: RTX 40xx series (Ada Lovelace)

To add support for other architectures, modify `CMAKE_CUDA_ARCHITECTURES` in the Dockerfile or use the build argument.

### cuDSS Acceleration

cuDSS (CUDA Direct Sparse Solver) provides GPU-accelerated sparse linear algebra for bundle adjustment. This significantly speeds up large-scale reconstructions compared to CPU-only solvers.

## License

This Docker configuration is provided as-is. COLMAP, Ceres Solver, and other dependencies are subject to their respective licenses:

- [COLMAP License](https://github.com/colmap/colmap/blob/main/COPYING.txt)
- [Ceres Solver License](https://github.com/ceres-solver/ceres-solver/blob/master/LICENSE)

## References

- [COLMAP Documentation](https://colmap.github.io/)
- [Ceres Solver Documentation](http://ceres-solver.org/)
- [NVIDIA cuDSS](https://developer.nvidia.com/cudss)
