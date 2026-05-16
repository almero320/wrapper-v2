# wrapper-v2

A clean rewrite of the Apple Music FairPlay decryption wrapper. Currently in
**Phase 0** - the build chain works end-to-end but no Apple-library code has
been ported yet.

## What it is

A small daemon that runs Apple Music's Android native libraries inside a
Linux chroot, exposes a local HTTP API for FairPlay key fetching and sample
decryption, and gives downstream tooling (e.g. [`gamdl`](https://github.com/glomatico/gamdl))
a uniform interface that does not depend on platform or language.

The daemon ships *no* Apple code. At build time, libraries are extracted from
a pinned Apple Music for Android APK split (3.6.0-beta, build 1109) whose
SHA-256 digests are committed in `LIBS_VERSION.json`. Without a matching APK
the build fails loudly.

## Status

| Phase | Goal | State |
| --- | --- | --- |
| 0 | Repo skeleton, build chain, NDK toolchain, CI smoke test | **In progress** |
| 1 | Port the FairPlay loop in C++ against 3.6.0-beta symbols | Pending |
| 2 | HTTP endpoints: `/health`, `/account`, `/m3u8`, `/decrypt` | Pending |
| 3 | Caching, rate limit, dedupe, optional auth | Pending |
| 4 | arm64-v8a build, multi-arch Docker, login state machine | Pending |

## Layout

```
.
├── CMakeLists.txt            top-level build (host launcher + NDK sub-build)
├── Dockerfile                multi-stage build
├── compose.yaml              docker compose entrypoint
├── LIBS_VERSION.json         pinned APK + per-.so SHA-256 digests
├── src/
│   ├── daemon/               C++ daemon (cross-compiled with the NDK)
│   │   ├── CMakeLists.txt
│   │   └── main.cpp
│   └── launcher/
│       └── wrapper.c         host-Linux chroot launcher
├── rootfs/                   chroot tree assembled at build time
│   └── system/
│       ├── bin/              <- main, linker64 (staged)
│       └── lib64/            <- Apple's .so + Android system .so (staged)
├── tools/
│   ├── fetch-apk.sh          download an APK / .apkm, verify SHA-256
│   ├── extract-libs.sh       extract .so files from APK, verify SHA-256
│   └── stage-system.sh       copy committed Android binaries into rootfs/
└── vendor/
    └── android-system/       linker64 + bionic + AOSP libs, SHA-pinned
        └── x86_64/
            ├── bin/linker64
            └── lib64/{libc, libm, libstdc++, liblog, libz, libandroid, libOpenSLES}.so
```

## Building

### One-time setup

You need a working Docker installation. Apart from that, the entire build
runs inside the image. There is no host toolchain prerequisite for the
default workflow.

For the build to succeed you must obtain Apple Music for Android **3.6.0-beta
(1109)** as APK splits. The APK is *not* committed and *not* fetched
automatically by the Dockerfile.

### Local build

```bash
# 1. Fetch the APKMirror bundle (you provide the URL).
APK_URL=https://your-mirror.example/apple-music-3.6.0-beta-1109.apkm \
    tools/fetch-apk.sh --expect apkm \
                        --out    .tmp/bundle.apkm

# 2. Extract Apple libs into rootfs/, verifying SHA-256 at every step
#    (bundle, inner split, every individual .so).
tools/extract-libs.sh --bundle .tmp/bundle.apkm \
                       --arch   x86_64 \
                       --out    rootfs/system/lib64

# 3. Stage the committed Android system binaries (linker64 + bionic + AOSP)
#    into rootfs/, verifying their SHA-256 against LIBS_VERSION.json.
tools/stage-system.sh --arch x86_64

# 4. Build and run.
docker compose up --build
curl http://127.0.0.1/health
```

The daemon binds port 80 inside the container and the compose file maps it
to host port 80 by default. Override with `HTTP_PORT=8080 docker compose up`
on machines that already have something on `:80`.

If you already have a single `split_config.x86_64.apk` rather than an
`.apkm` bundle, swap step 2 for `tools/extract-libs.sh --apk path/to/split_config.x86_64.apk ...` -
the same SHA verification still applies.

### CI build

The `.github/workflows/build.yml` workflow does the same three steps using
a single repository secret:

- `APK_URL` - URL of the pinned `.apkm` bundle (contains every split)

Pull requests opened from forks skip the build job (they cannot read the
secret).

## License

[Unlicense](./LICENSE) - public domain dedication.

This project is not affiliated with Apple Inc. The Apple-authored libraries
it loads at runtime are not redistributed by this repository.
