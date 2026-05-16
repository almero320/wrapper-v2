/*
 * wrapper-v2 chroot launcher.
 *
 * Sets up a minimal chroot inside ./rootfs/ that exposes the Android dynamic
 * linker (linker64) and Apple Music's native libs to a daemon binary at
 * /system/bin/main, then execs the daemon.
 *
 * This is the host-Linux-side launcher. It is intentionally tiny and has no
 * dependency on the daemon's HTTP code or on the Apple libs.
 *
 * Differences vs upstream wrapper.c:
 *   - No gengetopt; argument parsing is done inside the daemon and forwarded
 *     verbatim. The launcher only handles the chroot setup.
 *   - --base-dir handling is handled by the daemon itself; the launcher only
 *     ensures the directory exists if requested via WRAPPER_BASE_DIR env var.
 *   - SIGTERM is forwarded to the daemon (upstream only handled SIGINT).
 */

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define CAP_SYS_ADMIN_IDX 21
#define CAP_SYS_ADMIN_BIT (1ULL << CAP_SYS_ADMIN_IDX)

#define ROOTFS         "./rootfs"
#define DAEMON_PATH    "/system/bin/main"
#define LINKER_PATH    "/system/bin/linker64"

static volatile pid_t g_child = -1;

static void on_signal(int sig) {
    if (g_child > 0) {
        kill(g_child, sig);
    }
}

static int has_cap_sys_admin(void) {
    FILE* fp = fopen("/proc/self/status", "r");
    if (!fp) return 0;

    char line[256];
    int found = 0;
    while (fgets(line, sizeof(line), fp)) {
        if (strncmp(line, "CapEff:", 7) == 0) {
            char* p = line + 7;
            while (*p == ' ' || *p == '\t') ++p;
            unsigned long long cap = strtoull(p, NULL, 16);
            found = (cap & CAP_SYS_ADMIN_BIT) ? 1 : 0;
            break;
        }
    }
    fclose(fp);
    return found;
}

static int ensure_dir(const char* path, mode_t mode) {
    if (mkdir(path, mode) == 0) return 0;
    if (errno == EEXIST) return 0;
    fprintf(stderr, "wrapper: mkdir %s: %s\n", path, strerror(errno));
    return -1;
}

int main(int argc, char* argv[], char* envp[]) {
    struct sigaction sa = {0};
    sa.sa_handler = on_signal;
    sigaction(SIGINT,  &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    if (ensure_dir(ROOTFS "/dev", 0755) != 0) return 1;

    int fd = open(ROOTFS "/dev/urandom", O_CREAT | O_RDWR, 0666);
    if (fd < 0) {
        fprintf(stderr, "wrapper: open %s/dev/urandom: %s\n", ROOTFS, strerror(errno));
        return 1;
    }
    close(fd);

    if (mount("/dev/urandom", ROOTFS "/dev/urandom", NULL, MS_BIND, NULL) != 0) {
        fprintf(stderr, "wrapper: bind-mount /dev/urandom: %s\n", strerror(errno));
        return 1;
    }

    if (chdir(ROOTFS) != 0) {
        fprintf(stderr, "wrapper: chdir " ROOTFS ": %s\n", strerror(errno));
        return 1;
    }
    if (chroot("./") != 0) {
        fprintf(stderr, "wrapper: chroot: %s (need CAP_SYS_CHROOT or root)\n", strerror(errno));
        return 1;
    }

    if (ensure_dir("/proc", 0755) != 0) return 1;

    chmod(LINKER_PATH, 0755);
    chmod(DAEMON_PATH, 0755);

    if (has_cap_sys_admin()) {
        if (unshare(CLONE_NEWPID) != 0) {
            fprintf(stderr, "wrapper: unshare(CLONE_NEWPID): %s\n", strerror(errno));
            return 1;
        }
    }

    g_child = fork();
    if (g_child < 0) {
        fprintf(stderr, "wrapper: fork: %s\n", strerror(errno));
        return 1;
    }

    if (g_child > 0) {
        int status = 0;
        if (waitpid(g_child, &status, 0) < 0) {
            fprintf(stderr, "wrapper: waitpid: %s\n", strerror(errno));
            return 1;
        }
        if (WIFEXITED(status))   return WEXITSTATUS(status);
        if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
        return 1;
    }

    if (mount("proc", "/proc", "proc", 0, NULL) != 0) {
        fprintf(stderr, "wrapper: mount proc: %s\n", strerror(errno));
        return 1;
    }

    const char* base_dir = getenv("WRAPPER_BASE_DIR");
    if (base_dir && *base_dir) {
        ensure_dir(base_dir, 0777);
        char db_dir[1024];
        snprintf(db_dir, sizeof(db_dir), "%s/mpl_db", base_dir);
        ensure_dir(db_dir, 0777);
    }

    execve(DAEMON_PATH, argv, envp);
    fprintf(stderr, "wrapper: execve %s: %s\n", DAEMON_PATH, strerror(errno));
    return 1;
}
