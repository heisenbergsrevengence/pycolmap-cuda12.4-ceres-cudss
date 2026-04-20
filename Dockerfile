# Stage 1: Base Image with System Dependencies
FROM nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04 AS base

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive
# Use ATLAS for BLAS operations
ENV BLA_VENDOR=ATLAS

WORKDIR /build

# Layer 1: CUDA Keyring Setup
# Rarely changes; cached separately for efficiency
RUN mount=type=cache,target=/var/cache/apt,sharing=locked \
    mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y no-install-recommends \
        wget \
        ca-certificates \
        gnupg && \
    wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb && \
    dpkg -i cuda-keyring_1.1-1_all.deb && \
    rm -f cuda-keyring_1.1-1_all.deb

# Layer 2: Core Build Tools
RUN mount=type=cache,target=/var/cache/apt,sharing=locked \
    mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y no-install-recommends \
        git \
        cmake \
        ninja-build \
        build-essential \
        ccache

# Layer 3: Development Libraries
RUN mount=type=cache,target=/var/cache/apt,sharing=locked \
    mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y no-install-recommends \
        # Boost libraries
        libboost-program-options-dev \
        libboost-graph-dev \
        libboost-system-dev \
        # Math and linear algebra
        libeigen3-dev \
        libsuitesparse-dev \
        libmetis-dev \
        libatlas-base-dev \
        # Logging and testing
        libgoogle-glog-dev \
        libgtest-dev \
        libgmock-dev \
        # Graphics and UI
        libglew-dev \
        qtbase5-dev \
        libqt5opengl5-dev \
        libcgal-dev \
        # Image processing
        libopenimageio-dev \
        openimageio-tools \
        libopenexr-dev \
        # Database and Python
        libsqlite3-dev \
        python3-dev \
        python3-pip \
        # Network and security
        libcurl4-openssl-dev \
        libssl-dev

#  Layer 4: cuDSS Installation 
# NVIDIA cuDSS sparse direct solver for GPU-accelerated linear algebra
RUN mount=type=cache,target=/var/cache/apt,sharing=locked \
    mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y no-install-recommends \
        libcudss0-cuda-12 \
        libcudss0-static-cuda-12 \
        libcudss0-dev-cuda-12 && \
    mkdir -p /usr/include/opencv4

# Register cuDSS library path with dynamic linker
# cuDSS installs to a versioned subdirectory not in the default search path
RUN echo "/usr/lib/x86_64-linux-gnu/libcudss/12" > /etc/ld.so.conf.d/cudss.conf && \
    ldconfig

#  cuDSS CMake Configuration 
# NVIDIA's cuDSS package does not ship a CMake config file, so we provide
# a minimal shim to enable find_package(cudss) for Ceres
RUN mkdir -p /usr/local/lib/cmake/cudss && \
    cat > /usr/local/lib/cmake/cudss/cudss-config.cmake <<'EOF'
# cuDSS CMake Config (auto-generated shim)
set(cudss_VERSION 0.7.1)
set(PACKAGE_VERSION 0.7.1)
set(cudss_INCLUDE_DIRS /usr/include/libcudss/12)
set(cudss_LIBRARIES /usr/lib/x86_64-linux-gnu/libcudss/12/libcudss.so)

if(NOT TARGET cudss)
    add_library(cudss SHARED IMPORTED)
    set_target_properties(cudss PROPERTIES
        IMPORTED_LOCATION /usr/lib/x86_64-linux-gnu/libcudss/12/libcudss.so
        INTERFACE_INCLUDE_DIRECTORIES /usr/include/libcudss/12
    )
endif()

set(cudss_FOUND TRUE)
EOF

# cuDSS version config for CMake version compatibility checks
RUN cat > /usr/local/lib/cmake/cudss/cudss-config-version.cmake <<'EOF'
set(PACKAGE_VERSION "0.7.1")
if("${PACKAGE_FIND_VERSION}" VERSION_LESS_EQUAL "${PACKAGE_VERSION}")
    set(PACKAGE_VERSION_COMPATIBLE TRUE)
    if("${PACKAGE_FIND_VERSION}" VERSION_EQUAL "${PACKAGE_VERSION}")
        set(PACKAGE_VERSION_EXACT TRUE)
    endif()
endif()
EOF



# Stage 2: Ceres Solver Build

FROM base AS ceres-build

# Pinned commit for reproducibility (2026-04-08)
# Contains C++17 modernization and cuDSS sparse solver support
ARG CERES_COMMIT=806af05aff16eefc38c75a0c6dd3e9a3df4c9be8

# ccache configuration for faster rebuilds
ENV CCACHE_DIR=/ccache
ENV CCACHE_BASEDIR=/build
ENV CMAKE_C_COMPILER_LAUNCHER=ccache
ENV CMAKE_CXX_COMPILER_LAUNCHER=ccache
ENV CMAKE_CUDA_COMPILER_LAUNCHER=ccache

# Clone and build Ceres with CUDA/cuDSS support
RUN mount=type=cache,target=/ccache,sharing=locked \
    git clone https://github.com/ceres-solver/ceres-solver.git && \
    cd ceres-solver && \
    git checkout ${CERES_COMMIT} && \
    git submodule update init recursive depth 1 && \
    mkdir build && cd build && \
    cmake .. \
        -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTING=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DUSE_CUDA=ON \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_CUDA_ARCHITECTURES="86;89" && \
    ninja -j$(nproc) && \
    ninja install && \
    ldconfig && \
    rm -rf /build/ceres-solver

# Verify Ceres was built with cuDSS support
RUN echo "=== Ceres cuDSS Verification ===" && \
    ldd /usr/local/lib/libceres.so | grep -i cudss && \
    ! ldd /usr/local/lib/libceres.so | grep -i cudss | grep -q "not found" && \
    echo "[OK] Ceres linked with cuDSS and library is loadable"



# Stage 3: COLMAP Build

FROM ceres-build AS colmap-build

# Pinned version for reproducibility
# Release: 4.0.3 (2025-04-06)
ARG COLMAP_VERSION=4.0.3
ARG COLMAP_COMMIT=e5b4a3e

# ccache configuration
ENV CCACHE_DIR=/ccache
ENV CCACHE_BASEDIR=/build
ENV CMAKE_C_COMPILER_LAUNCHER=ccache
ENV CMAKE_CXX_COMPILER_LAUNCHER=ccache
ENV CMAKE_CUDA_COMPILER_LAUNCHER=ccache

# Clone and build COLMAP with CUDA support
RUN mount=type=cache,target=/ccache,sharing=locked \
    git clone https://github.com/colmap/colmap.git branch ${COLMAP_VERSION} depth 1 && \
    cd colmap && \
    mkdir build && cd build && \
    cmake .. \
        -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCUDA_ENABLED=ON \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_CUDA_ARCHITECTURES="86;89" \
        -DCeres_DIR=/usr/local/lib/cmake/Ceres \
        2>&1 | tee /tmp/colmap-cmake.log && \
    ninja -j$(nproc) && \
    ninja install && \
    ldconfig

# Verify COLMAP installation
RUN echo "=== COLMAP Build Verification ===" && \
    echo " CMake CUDA Configuration " && \
    grep -i "cuda" /build/colmap/build/CMakeCache.txt | head -15 && \
    echo "" && \
    echo " Installed Libraries " && \
    find /usr/local -name "libcolmap*" -type f 2>/dev/null && \
    echo "[OK] COLMAP installation complete"


# Stage 4: pycolmap Build (Final)
FROM colmap-build AS pycolmap

LABEL maintainer="pycolmap" \
      description="pycolmap with CUDA 12.4, cuDSS, and GPU-accelerated bundle adjustment" \
      version="1.0.0"

# Register COLMAP third-party libraries
RUN echo "/usr/local/thirdparty" > /etc/ld.so.conf.d/colmap.conf && \
    ldconfig

# Install Python build dependencies
RUN mount=type=cache,target=/root/.cache/pip,sharing=locked \
    pip3 install upgrade pip && \
    pip3 install \
        "scikit-build-core>=0.3.3" \
        "pybind11==3.0.2" \
        "pybind11_stubgen @ git+https://github.com/sarlinpe/pybind11-stubgen@sarlinpe/fix-2025-08-20" \
        "numpy" \
        "ruff==0.15.7" \
        "clang-format==22.1.1"

# ccache configuration for pycolmap build
ENV CCACHE_DIR=/ccache
ENV CCACHE_BASEDIR=/build

# Build and install pycolmap
RUN mount=type=cache,target=/ccache,sharing=locked \
    mount=type=cache,target=/root/.cache/pip,sharing=locked \
    cd colmap && \
    pip3 install . no-build-isolation -v

WORKDIR /workspace
