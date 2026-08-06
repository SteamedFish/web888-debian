# Upstream RaspSDR `server` Build System (reference)

> **Scope note:** This documents the **upstream RaspSDR/server** CMake build —
> i.e. how the *stock vendor* `websdr.bin` is built (CMake, Alpine/musl,
> cross-compile, embedded web assets). It is **NOT** this project's build.
> The web888-debian project builds a Debian trixie rootfs via debootstrap +
> a linux-xlnx 6.6 kernel and packages websdr as a `.deb` — see the
> [repo-root README](../README.md), `scripts/build-all.sh`, and
> `../dev/CHANGELOG.md` for the actual project build. This
> file is kept only as reference for understanding the upstream `websdr.bin`
> artifact (CMake options, `mkextinit.py` extension auto-gen, FILEDATA web-asset
> embedding, version-numbering scheme).

## Overview

The upstream Web-888/RaspSDR `server` uses CMake, targeting Alpine Linux on ARM Cortex-A9 (Zynq-7010). The build produces a monolithic binary (`websdr.bin`) with embedded web assets.

## Build Requirements

### CMake Version
- **Minimum:** CMake 3.13
- **Recommended:** Latest stable for best compatibility

### Target Platform
- **Architecture:** ARMv7-A (32-bit)
- **CPU:** Cortex-A9 (dual-core in Zynq-7010)
- **OS:** Alpine Linux 3.20 (musl libc)
- **FPGA:** Xilinx Zynq-7010 (XC7Z010)

## Build Configuration

### CMake Options

```cmake
option(ZYNQ "Target Zynq ARM platform" ON)
option(INSTALL_PACKAGES "Install required packages during build" OFF)
option(HFDL "Include HFDL extension" OFF)
option(HAS_GPS "Include GPS support" ON)
option(HAS_SDR_GPS "Include SDR-based GPS" OFF)  # Web-888 uses hardware GPS
option(HAS_WB_DDC "Include wideband DDC support" ON)
option(HAS_E1B "Include E1B PRN code support" OFF)
```

### Compiler Flags

**ARM-specific optimizations:**
```cmake
-march=armv7-a -mtune=cortex-a9 -mfpu=neon -mfloat-abi=hard
```

**General flags:**
```cmake
-Wall                          # Enable all warnings
-fsingle-precision-constant    # Use single precision for float constants
-ffast-math                    # Aggressive floating-point optimizations
-pthread                       # POSIX threading support
```

**Release mode additional:**
```cmake
-DNDEBUG                       # Disable debug assertions
-O3                            # Maximum optimization
-fomit-frame-pointer           # Omit frame pointer for performance
```

## Dependencies

### Required Libraries

| Library | Purpose | Alpine Package |
|---------|---------|----------------|
| FFTW3 | FFT processing | `fftw-dev` |
| zlib | Compression | `zlib-dev` |
| FDK-AAC | AAC audio encoding | `fdk-aac-dev` |
| gpsd | GPS daemon interface | `gpsd-dev` |
| libunwind | Stack unwinding | `libunwind-dev` |
| SQLite3 | Database | `sqlite-dev` |
| curl | HTTP client | `curl-dev` |
| OpenSSL | Cryptography | `openssl-dev` |

### Build Dependencies

```bash
# Alpine Linux packages for building
apk add cmake make gcc g++ linux-headers

# Development libraries
apk add fftw-dev zlib-dev fdk-aac-dev gpsd-dev
apk add libunwind-dev sqlite-dev curl-dev openssl-dev
```

## Build Process

### 1. Directory Structure

```
build/
├── CMakeLists.txt          # Main build configuration
├── CMakeLists-src.txt      # Source file lists
├── CMakeLists-wb.txt       # Wideband DDC configuration
├── extensions/             # Extension source files
│   ├── ALE_2G/
│   ├── CW_decoder/
│   ├── FT8/
│   ├── WSPR/
│   └── ... (27 total)
├── web/                    # Web interface assets
│   ├── kiwi/               # Core JavaScript
│   ├── extensions/         # Extension HTML/JS/CSS
│   └── ip_blacklist/       # Security files
└── unix_env/               # Platform abstraction
```

### 2. Extension Auto-Generation

Extensions are automatically discovered and registered:

```cmake
# CMakeLists.txt snippet
execute_process(
    COMMAND python3 ${PROJECT_SOURCE_DIR}/pkgs/mkextinit.py
    WORKING_DIRECTORY ${PROJECT_SOURCE_DIR}
)
```

The `mkextinit.py` script:
1. Scans `extensions/` directory
2. Generates `extint.cpp` with registration code
3. Creates `ext_int.h` with extension declarations
4. Lists all extension files for compilation

### 3. Web Asset Embedding

Web files are embedded as C++ arrays:

```cmake
# Data files embedded into binary
set(DATA_FILES
    web/kiwi/kiwi.js
    web/kiwi/kiwi.css
    web/kiwi/mkiwi.html
    # ... 70+ files
)

# Generate C++ source files with embedded data
add_custom_command(
    OUTPUT edata_embed.cpp
    COMMAND ${PROJECT_SOURCE_DIR}/tools/FILEDATA
    ARGS ${DATA_FILES}
    DEPENDS ${DATA_FILES}
)
```

**Embedding process:**
1. `tools/FILEDATA` converts web assets to C++ byte arrays
2. Three categories: `edata_always`, `edata_always2`, `edata_embed`
3. Files compressed and embedded in binary
4. Served via built-in HTTP server

### 4. Minification (Release Mode)

```cmake
if(CMAKE_BUILD_TYPE STREQUAL "Release")
    find_program(UGLIFYJS uglifyjs)
    find_program(CLEANCSS cleancss)
    find_program(HTMLMIN html-minifier)
    
    # Minify JavaScript
    uglifyjs kiwi.js -o kiwi.min.js
    
    # Minify CSS
    cleancss kiwi.css -o kiwi.min.css
    
    # Minify HTML
    html-minifier --collapse-whitespace mkiwi.html -o mkiwi.min.html
endif()
```

## Version Numbering

```cpp
// From kiwi.h
#define VERSION_MAJOR 2025
#define VERSION_MINOR 329

// Results in: v1.780 (2025_0329 format)
```

**Format:** `YEAR_MONTH_DAY` (e.g., 20250329 = March 29, 2025)

## Build Commands

### Native Build (on Alpine Linux ARM)

```bash
# Clone repository
git clone https://github.com/RaspSDR/server.git
cd server

# Create build directory
mkdir build && cd build

# Configure
cmake -DZYNQ=ON \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr/local \
      ..

# Build (uses all CPU cores)
make -j$(nproc)

# Install
make install
```

### Cross-Compilation

Using Alpine Linux chroot:

```bash
# Create ARM chroot (on x86_64 host)
apk add alpine-chroot-install
alpine-chroot-install -a armv7

# Enter chroot
/path/to/chroot/enter-chroot

# Install build dependencies
apk add cmake make gcc g++ linux-headers
apk add fftw-dev zlib-dev fdk-aac-dev gpsd-dev

# Build as above
```

### Docker Build

```dockerfile
FROM alpine:3.20 AS builder

RUN apk add --no-cache \
    cmake make gcc g++ linux-headers \
    fftw-dev zlib-dev fdk-aac-dev gpsd-dev \
    libunwind-dev sqlite-dev curl-dev openssl-dev

WORKDIR /build
COPY . .

RUN mkdir build && cd build && \
    cmake -DZYNQ=ON -DCMAKE_BUILD_TYPE=Release .. && \
    make -j$(nproc)

FROM alpine:3.20
RUN apk add --no-cache libstdc++ fftw zlib fdk-aac gpsd
COPY --from=builder /build/build/websdr.bin /usr/local/bin/
EXPOSE 8073
CMD ["/usr/local/bin/websdr.bin"]
```

## Output Files

### Main Binary

| File | Size | Description |
|------|------|-------------|
| `websdr.bin` | ~7.7 MB | Main SDR server executable (unstripped ~15 MB) |

### Embedded Assets

| Category | Files | Purpose |
|----------|-------|---------|
| edata_always | ~30 files | Always-loaded core assets |
| edata_always2 | ~10 files | Secondary core assets |
| edata_embed | ~40 files | On-demand loaded extensions |

## Development Workflow

### 1. Modifying Extensions

```bash
# Edit extension source
vim extensions/FT8/FT8.cpp

# Regenerate extension initialization
python3 pkgs/mkextinit.py

# Rebuild
cd build && make -j$(nproc)
```

### 2. Modifying Web Interface

```bash
# Edit web files
vim web/kiwi/kiwi.js

# Rebuild to re-embed assets
cd build && make -j$(nproc)
```

### 3. Adding New Extensions

1. Create directory: `extensions/NEW_EXT/`
2. Add source files: `NEW_EXT.cpp`, `NEW_EXT.h`
3. Add UI files: `NEW_EXT.html`, `NEW_EXT.js`, `NEW_EXT.css`
4. Run: `python3 pkgs/mkextinit.py`
5. Rebuild with CMake

## Platform-Specific Notes

### Alpine Linux
- Uses **musl libc** instead of glibc
- Static linking preferred for portability
- Smaller binary sizes

### Zynq-7010
- NEON SIMD for signal processing
- Dual-core Cortex-A9
- FPGA fabric for custom logic
- Limited to 512MB RAM typically

### BeagleBone (KiwiSDR compatibility)
- Original KiwiSDR target
- Single-core Cortex-A8
- PRU for real-time processing
- Web-888 build system maintains compatibility

## Debugging

### Debug Build

```bash
cmake -DCMAKE_BUILD_TYPE=Debug -DVALgrind=ON ..
make -j$(nproc)
```

### Runtime Debugging

```bash
# Run with GDB
gdb ./websdr.bin

# Run with Valgrind
valgrind --leak-check=full ./websdr.bin

# Enable verbose logging
./websdr.bin -v
```

### Common Build Issues

| Issue | Solution |
|-------|----------|
| `fftw3.h not found` | Install `fftw-dev` package |
| `gps.h not found` | Install `gpsd-dev` package |
| ARM compilation errors | Ensure `-march=armv7-a -mfpu=neon` flags |
| Linker errors | Check all dependencies installed |
| Python not found | Install `python3` for mkextinit.py |

## Performance Optimization

### Compiler Optimizations
- `-ffast-math`: Aggressive FP optimizations
- `-funroll-loops`: Loop unrolling
- `-fomit-frame-pointer`: Omit frame pointer

### ARM-Specific
- NEON intrinsics for FFT processing
- VFPv3 for floating-point
- Thumb-2 instruction set

### Link-Time Optimization (LTO)
```cmake
set(CMAKE_INTERPROCEDURAL_OPTIMIZATION TRUE)
```

## References

- [CMake Documentation](https://cmake.org/documentation/)
- [Alpine Linux Development](https://wiki.alpinelinux.org/wiki/Development)
- [ARM NEON Programming](https://developer.arm.com/architectures/instruction-sets/simd-isas/neon)
- [RaspSDR Build Guide](https://github.com/RaspSDR/server/blob/main/BUILDING.md)

---

*Document version: 2026-03-31*
