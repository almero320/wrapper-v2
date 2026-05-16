// wrapper-v2 daemon (Phase 0 stub).
//
// This binary is the rewrite target of upstream `wrapper`'s `main.c` from
// the Apple Music FairPlay decryption project. In Phase 0 it does not yet
// touch Apple's libraries; it only proves that:
//
//   1. The NDK toolchain works.
//   2. cpp-httplib + nlohmann::json compile and link cleanly under the
//      Android x86_64 sysroot.
//   3. The chroot launcher can exec us, we bind a port inside the chroot,
//      and an HTTP client outside the chroot can hit /health.
//
// Phase 1 will introduce the C++ bindings to libstoreservicescore /
// libmediaplatform / libandroidappmusic, port the FairPlay decrypt loop,
// and add /m3u8 + /decrypt endpoints.

#include <atomic>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <string_view>
#include <thread>

#include <httplib.h>
#include <nlohmann/json.hpp>

namespace {

constexpr const char* kHost      = "0.0.0.0";
constexpr int         kDefaultPort = 80;

std::atomic<httplib::Server*> g_server{nullptr};

void on_signal(int sig) {
    auto* s = g_server.load();
    if (s != nullptr) {
        std::fprintf(stderr, "wrapper-v2: caught signal %d, stopping server\n", sig);
        s->stop();
    }
}

struct Config {
    std::string host = kHost;
    int         port = kDefaultPort;
};

Config parse_args(int argc, char** argv) {
    Config c;
    for (int i = 1; i < argc; ++i) {
        std::string_view a = argv[i];
        if ((a == "--host" || a == "-H") && i + 1 < argc) {
            c.host = argv[++i];
        } else if ((a == "--port" || a == "-p") && i + 1 < argc) {
            c.port = std::atoi(argv[++i]);
        } else if (a == "--help" || a == "-h") {
            std::printf(
                "wrapper-v2 (Phase 0 stub)\n"
                "Usage: %s [--host HOST] [--port PORT]\n"
                "  --host HOST   Bind address (default %s)\n"
                "  --port PORT   Bind port    (default %d)\n",
                argv[0], kHost, kDefaultPort);
            std::exit(0);
        }
    }
    return c;
}

}  // namespace

int main(int argc, char** argv) {
    Config cfg = parse_args(argc, argv);

    std::signal(SIGINT,  on_signal);
    std::signal(SIGTERM, on_signal);
    std::signal(SIGPIPE, SIG_IGN);

    httplib::Server svr;
    g_server.store(&svr);

    svr.Get("/health", [](const httplib::Request&, httplib::Response& res) {
        nlohmann::json body = {
            {"status",  "ok"},
            {"phase",   0},
            {"version", "0.0.0-phase0"},
        };
        res.set_content(body.dump(), "application/json");
    });

    svr.set_exception_handler([](const httplib::Request&, httplib::Response& res, std::exception_ptr ep) {
        std::string what = "unknown";
        try { if (ep) std::rethrow_exception(ep); }
        catch (const std::exception& e) { what = e.what(); }
        catch (...) {}
        nlohmann::json body = {{"error", what}};
        res.status = 500;
        res.set_content(body.dump(), "application/json");
    });

    std::fprintf(stderr, "wrapper-v2: listening on %s:%d (Phase 0 stub, /health only)\n",
                 cfg.host.c_str(), cfg.port);

    if (!svr.listen(cfg.host, cfg.port)) {
        std::fprintf(stderr, "wrapper-v2: bind failed\n");
        return 1;
    }
    return 0;
}
