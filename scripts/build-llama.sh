#!/bin/bash
# Builds llama.cpp (MIT), the embedding runtime: the pinned build tag plus scripts/llama.cpp-no-logits.patch, as static
# libraries combined into Vendor/llama/lib/libllamacpp.a, with the headers in Vendor/llama/include (all out of git).
# Metal shaders are embedded and compiled on first use, so no Metal toolchain is needed. CMake comes from PATH, or from
# a venv in Vendor/ (needs uv). Does nothing when that build is already there; build.sh runs it every time.
# On Linux and Windows it builds shared libraries instead, with ggml's backends as modules loaded at run
# time (GGML_BACKEND_DL): CPU variants for host storage, Vulkan for hardware inference. Its SDK is required.
# LLAMA_SOURCE / LLAMA_BUILD point at an existing clone and
# build root (each configuration gets its own build directory). On Windows it runs in Git for Windows' bash inside the MSVC environment (vcvars64) and
# leaves DLLs with their import libraries.
set -euo pipefail
cd "$(dirname "$0")/.."
TAG=b11461   # the first tags with EmbeddingGemma 2 (text + vision + audio) are b11452+
COMMIT=4d756bc72bf00a4aacf410ae15a2d315f3db400d   # TAG's commit: a tag can be moved, a commit can't
# A new TAG ships only if `swift test` passes: ReferenceVectorTests checks it makes the same vectors, so every index is
# kept. If it fails, keep this TAG, or bump LlamaEmbedder.vectorVersion and write the reference vectors again
# (DIGUP_WRITE_REFERENCE=1 swift test --filter ReferenceVectorTests): every index then embeds again.
PATCH=scripts/llama.cpp-no-logits.patch
STRICT_PATCH=scripts/llama.cpp-accelerator-only.patch
CUDA_PATCH=scripts/llama.cpp-cuda-policy.patch
CUDA_ARCHS="75-real;86-real;89-real;120a-real"
SOURCE="${LLAMA_SOURCE:-Vendor/llama.cpp}"
BUILD="${LLAMA_BUILD:-Vendor/llama-build}"
OUT=Vendor/llama
OS=$(uname -s)
if [[ $OS == Darwin ]]; then
  FLAVOR=metal
else
  command -v glslc > /dev/null || { echo "Vulkan SDK (glslc) required; CPU-only production builds are disabled." >&2; exit 1; }
  FLAVOR=vulkan
  if [[ $OS == MINGW* || $OS == MSYS* || ${DIGUP_BUILD_CUDA:-0} == 1 ]]; then
    command -v nvcc > /dev/null || { echo "Pinned CUDA Toolkit 12.9.1 required for NVIDIA builds." >&2; exit 1; }
    nvcc --version | grep -q 'V12.9.86' || { echo "Expected CUDA 12.9.1 (nvcc 12.9.86)." >&2; exit 1; }
    FLAVOR=vulkan-cuda
  fi
fi
PATCH_ID=$(cat "$0" "$PATCH" "$STRICT_PATCH" "$CUDA_PATCH" | (shasum -a 256 2>/dev/null || sha256sum) | cut -c1-24)
COMPILER_ID=$(${CXX:-c++} --version 2>&1 | head -1 || true)
if [[ $OS == MINGW* || $OS == MSYS* ]]; then COMPILER_ID=$(cl 2>&1 | head -1 || true); fi
STAMP="$TAG $PATCH_ID $FLAVOR $COMPILER_ID $CUDA_ARCHS cuda12.9.1 accelerator-policy2"
BUILD_ID=$(printf '%s' "$STAMP" | (shasum -a 256 2>/dev/null || sha256sum) | cut -c1-32)
if [[ ( -f "$OUT/lib/libllamacpp.a" || -f "$OUT/lib/libllama.so" || -f "$OUT/lib/llama.dll" ) \
      && "$(cat "$OUT/BUILD" 2>/dev/null)" == "$STAMP" ]]; then
  exit 0
fi
# CMake leaves disabled backend modules in its old bin directory. Separate every compiler/backend/patch identity so
# switching CUDA off (or changing architectures/toolchains) cannot accidentally package a previous module.
BUILD="$BUILD/$BUILD_ID"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if [[ ! -d "$SOURCE" ]]; then
  # Line endings as they are (Git for Windows would turn them into CRLF, and the patch wouldn't apply).
  git -c advice.detachedHead=false -c core.autocrlf=false clone --quiet --depth 1 --branch "$TAG" \
    https://github.com/ggml-org/llama.cpp "$SOURCE"
elif [[ "$(git -C "$SOURCE" describe --tags --exact-match 2>/dev/null)" != "$TAG" ]]; then
  git -C "$SOURCE" fetch --quiet --depth 1 origin tag "$TAG"
  git -C "$SOURCE" checkout --quiet --force "$TAG"   # --force also drops the old patch
fi
if [[ "$(git -C "$SOURCE" rev-parse HEAD)" != "$COMMIT" ]]; then
  echo "llama.cpp's $TAG isn't commit $COMMIT here: not building it" >&2
  exit 1
fi
# Without the patch, every input token costs 1 MiB of logits that an embedding model never produces (262k vocabulary).
# Its path is absolute: git -C reads a relative one from the source folder, which LLAMA_SOURCE can put anywhere.
# Remove previously applied patches in reverse order before applying this set. Custom source edits must still pass git apply checks.
for patch in "$CUDA_PATCH" "$STRICT_PATCH" "$PATCH"; do
  if git -C "$SOURCE" apply --reverse --check "$PWD/$patch" 2>/dev/null; then git -C "$SOURCE" apply --reverse "$PWD/$patch"; fi
done
for patch in "$PATCH" "$STRICT_PATCH" "$CUDA_PATCH"; do
  if git -C "$SOURCE" apply --check "$PWD/$patch" 2>/dev/null; then
    git -C "$SOURCE" apply "$PWD/$patch"
  elif ! git -C "$SOURCE" apply --reverse --check "$PWD/$patch" 2>/dev/null; then
    echo "$patch doesn't apply to $SOURCE, and isn't applied already: not building it" >&2
    exit 1
  fi
done

if ! command -v cmake > /dev/null; then
  if [[ ! -x Vendor/cmake-venv/bin/cmake ]]; then
    uv venv --quiet Vendor/cmake-venv --python 3.12
    uv pip install --quiet --python Vendor/cmake-venv/bin/python cmake==4.4.4 ninja==1.13.2
  fi
  export PATH="$PWD/Vendor/cmake-venv/bin:$PATH"
fi
if [[ $OS == Darwin ]]; then
  GENERATOR=$(command -v ninja > /dev/null && echo Ninja || echo "Unix Makefiles")
  # Only the libraries: no tools, no server, nothing downloaded at build time.
  cmake -S "$SOURCE" -B "$BUILD" -G "$GENERATOR" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DBUILD_SHARED_LIBS=OFF -DGGML_ACCELERATOR_ONLY=ON -DGGML_OPENMP=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DLLAMA_BUILD_MTMD=ON \
    -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_OPENSSL=OFF > /dev/null
  cmake --build "$BUILD" --config Release -j "$(sysctl -n hw.ncpu)" --target llama mtmd > /dev/null

  B="$BUILD"
  mkdir -p "$OUT/lib" "$OUT/include"
  xcrun libtool -static -no_warning_for_no_symbols -o "$OUT/lib/libllamacpp.a" \
    $B/src/libllama.a $B/tools/mtmd/libmtmd.a $B/ggml/src/libggml.a $B/ggml/src/libggml-base.a \
    $B/ggml/src/libggml-cpu.a $B/ggml/src/ggml-metal/libggml-metal.a $B/ggml/src/ggml-blas/libggml-blas.a \
    $B/vendor/hash/libvendor-hash.a
else
  GENERATOR=$(command -v ninja > /dev/null && echo Ninja || echo "Unix Makefiles")
  COMPILERS=()
  if [[ $OS == MINGW* || $OS == MSYS* ]]; then
    export CC=cl CXX=cl   # MSVC, not whatever else bash finds first
  elif [[ $(uname -m) == aarch64 && -z "${CC:-}" ]]; then
    # The arm64 CPU variants go up to armv9.2 with SME (-march=...+sme), which GCC before 14 doesn't know (Ubuntu
    # 24.04's is 13): the first C compiler here that takes it, with its C++ one. Named to CMake, so a build folder
    # set up with another compiler is set up again.
    for pair in cc:c++ gcc-14:g++-14 gcc-15:g++-15 clang:clang++; do
      if command -v "${pair%%:*}" > /dev/null && command -v "${pair##*:}" > /dev/null \
        && echo 'int main(void) { return 0; }' | "${pair%%:*}" -x c -march=armv9.2-a+sme -c -o /dev/null - 2>/dev/null; then
        export CC=${pair%%:*} CXX=${pair##*:}
        COMPILERS=("-DCMAKE_C_COMPILER=$CC" "-DCMAKE_CXX_COMPILER=$CXX")
        break
      fi
    done
    if [[ -z "${CC:-}" ]]; then
      echo "llama.cpp's arm64 CPU variants need GCC 14 or Clang (armv9.2's SME): install gcc-14 or clang, or set CC and CXX" >&2
      exit 1
    fi
  fi
  case $FLAVOR in
    vulkan) GPU=(-DGGML_VULKAN=ON -DGGML_CUDA=OFF) ;;
    vulkan-cuda) GPU=(-DGGML_VULKAN=ON -DGGML_CUDA=ON -DCMAKE_CUDA_RUNTIME_LIBRARY=Shared -DGGML_CUDA_FA=OFF -DGGML_CUDA_GRAPHS=OFF "-DCMAKE_CUDA_ARCHITECTURES=$CUDA_ARCHS") ;;
    *) GPU=() ;;
  esac
  # Shared libraries, the backends as modules (every CPU variant, so one build fits any x86-64 or arm64 machine).
  cmake -S "$SOURCE" -B "$BUILD" -G "$GENERATOR" -DCMAKE_BUILD_TYPE=Release "${COMPILERS[@]}" \
    -DBUILD_SHARED_LIBS=ON -DGGML_ACCELERATOR_ONLY=ON -DGGML_OPENMP=OFF -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON -DGGML_NATIVE=OFF "${GPU[@]}" \
    -DLLAMA_BUILD_MTMD=ON -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_OPENSSL=OFF \
    -DLLAMA_CURL=OFF > /dev/null
  cmake --build "$BUILD" --config Release -j "${DIGUP_BUILD_JOBS:-$(nproc)}" > /dev/null
  rm -rf "$OUT/lib" && mkdir -p "$OUT/lib" "$OUT/include"
  if [[ $OS == MINGW* || $OS == MSYS* ]]; then
    # The DLLs (the backends among them), and the import libraries the helper links against.
    cp "$BUILD"/bin/*.dll "$OUT/lib/"
    find "$BUILD" \( -name llama.lib -o -name mtmd.lib -o -name ggml.lib -o -name ggml-base.lib \) \
      -exec cp {} "$OUT/lib/" \;
  else
    # The libraries with their versioned names (the SONAMEs the helper links against) and the symlinks to them.
    cp -a "$BUILD"/bin/*.so* "$OUT/lib/"
  fi
fi
cp "$SOURCE/include/llama.h" "$SOURCE"/ggml/include/*.h "$SOURCE/tools/mtmd/mtmd.h" "$SOURCE/tools/mtmd/mtmd-helper.h" \
  "$OUT/include/"
# The build, for logs and `digup status` (indexes record LlamaEmbedder.vectorVersion, not this). SwiftPM doesn't see a
# changed header, so the Swift file that reads it is touched.
printf '// Written by scripts/build-llama.sh.\n#define LLAMA_BUILD_TAG "%s"\n#define LLAMA_BUILD_ID "%s"\n#define LLAMA_RUNTIME_FLAVOR "%s"\n' "$TAG" "$BUILD_ID" "$FLAVOR" > "$OUT/include/llama-build.h"
python=python3
python3 -c '' 2>/dev/null || python=python
"$python" - "$OUT" "$TAG" "$COMMIT" "$BUILD_ID" "$FLAVOR" "$CUDA_ARCHS" <<'PYMETA'
import json,sys
from pathlib import Path
out,tag,commit,build,flavor,archs=sys.argv[1:]
Path(out,'native-runtime.json').write_text(json.dumps({'schemaVersion':1,'tag':tag,'commit':commit,'buildIdentity':build,
 'flavor':flavor,'policyVersion':2,'cudaToolkit':'12.9.1' if 'cuda' in flavor else None,
 'cudaPrecision':'cuda-fp32-v1','cudaArchitectures':archs.split(';'),'minimumWindowsDriver':'576.57'},indent=2)+'\n')
PYMETA
touch Sources/LlamaRuntime/LlamaEmbedder.swift
echo "$STAMP" > "$OUT/BUILD"
echo "Built llama.cpp $TAG (patched, $FLAVOR${CC:+, $CC}) into $OUT"
