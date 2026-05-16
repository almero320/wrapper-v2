# wrapper-v2 image.
#
# This Dockerfile assumes that rootfs/system/lib64/ has already been populated
# by tools/extract-libs.sh on the host (or in CI). The image itself does not
# fetch the APK - that is the caller's responsibility, so the build remains
# hermetic and reproducible given identical inputs.
#
#   tools/fetch-apk.sh ...
#   tools/extract-libs.sh ...
#   docker build -t wrapper-v2 .
#
# In CI the workflow under .github/workflows/build.yml does this.

ARG BUILD_PLATFORM=linux/amd64
ARG RUNTIME_PLATFORM=linux/amd64

# -----------------------------------------------------------------------------
# Build stage
# -----------------------------------------------------------------------------
FROM --platform=${BUILD_PLATFORM} debian:13.2 AS build

ARG TARGET_ARCH=x86_64
ARG NDK_VERSION=23
ARG WRAPPER_DEBUG_HOOKS=OFF

SHELL ["/bin/bash", "-c"]
ENV DEBIAN_FRONTEND=noninteractive

RUN --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        git \
        jq \
        ninja-build \
        unzip

RUN curl -fSL -o /tmp/ndk.zip \
        "https://dl.google.com/android/repository/android-ndk-r${NDK_VERSION}b-linux.zip" && \
    unzip -q /tmp/ndk.zip -d /opt && \
    rm /tmp/ndk.zip
ENV ANDROID_NDK_HOME=/opt/android-ndk-r${NDK_VERSION}b

WORKDIR /app
COPY . /app

RUN test -f rootfs/system/bin/linker64 || { \
        echo "ERROR: rootfs/system/bin/linker64 is missing." >&2; \
        echo "Run tools/stage-system.sh on the host before docker build." >&2; \
        exit 1; \
    } && \
    test -d rootfs/system/lib64 && \
    ls rootfs/system/lib64/*.so >/dev/null 2>&1 || { \
        echo "ERROR: rootfs/system/lib64/ has no .so files." >&2; \
        echo "Run tools/fetch-apk.sh + tools/extract-libs.sh + tools/stage-system.sh on the host before docker build." >&2; \
        exit 1; \
    }

RUN cmake -S . -B build -G Ninja \
        -DTARGET_ARCH=${TARGET_ARCH} \
        -DWRAPPER_DEBUG_HOOKS=${WRAPPER_DEBUG_HOOKS} \
        -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build -j

# -----------------------------------------------------------------------------
# Runtime stage
# -----------------------------------------------------------------------------
FROM --platform=${RUNTIME_PLATFORM} debian:13.2

WORKDIR /app

COPY --from=build /app/wrapper        /app/wrapper
COPY --from=build /app/rootfs         /app/rootfs

EXPOSE 80

ENTRYPOINT ["/app/wrapper"]
CMD ["--host", "0.0.0.0", "--port", "80"]
