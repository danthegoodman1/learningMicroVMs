// PID 1 for microVMs that are prepared once, snapshotted, and restored many
// times. The host drives it over vsock with length-prefixed frames of
// NUL-terminated "key=value" records (see ctl.py).
//
//   cmd=PREPARE  warm=<path>... warmrun=<shell command>...
//       Read files into the guest page cache so they ship in the snapshot.
//       Reply, then the host snapshots while the supervisor waits in accept().
//   cmd=START    time_ns=<unix ns> seed=<hex> env=K=V... arg=<argv>...
//                [cwd=<dir>] [hostname=<name>]
//                [rootfs=<block device> rootfs_size=<bytes> rootfs_fs=<type>
//                 rootfs_opts=<mount options> rootfs_overlay=<0|1>]
//       Make this clone unique, then spawn the customer's process with exactly
//       the given env: set the wall clock, reseed the kernel RNG, drop the
//       cached gateway MAC, and posix_spawn argv. Allowed once per boot.
//       With rootfs=, first mount that disk read-only and switch root into
//       it, so argv runs from the tenant's filesystem. rootfs_overlay=1 (the
//       default) puts a tmpfs overlay on top so the whole tree is writable;
//       with 0 only /tmp, /run and /dev are, and the image needs those
//       directories.
//   cmd=PING
//
// Boot parameters (passed to init as environment variables by the kernel):
//   sv_ip, sv_mask, sv_gw   guest address (default 172.16.0.2/30 via .1)
//   sv_port                 vsock port to listen on (default 1024)
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <linux/random.h>
#include <linux/vm_sockets.h>
#include <net/if.h>
#include <net/if_arp.h>
#include <net/route.h>
#include <netinet/in.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAX_FRAME (1 << 20)
#define MAX_ITEMS 4096
#define DEFAULT_PATH "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

static const char *guest_ip, *guest_mask, *gateway;
static int console_fd = -1;
static int started;
static volatile sig_atomic_t child_exited;

static const char *env_or(const char *key, const char *fallback) {
    const char *v = getenv(key);
    return v && *v ? v : fallback;
}

static void logf_(const char *fmt, ...) {
    if (console_fd < 0) return;
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 0 && write(console_fd, buf, n < (int)sizeof(buf) ? n : (int)sizeof(buf) - 1) < 0) console_fd = -1;
}

static long long mono_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000000LL + ts.tv_nsec / 1000;
}

// ------------------------------------------------------------------ boot setup

static void mount_basics(void) {
    mkdir("/dev", 0755);
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
    mkdir("/proc", 0555);
    mount("proc", "/proc", "proc", 0, NULL);
    mkdir("/sys", 0555);
    mount("sysfs", "/sys", "sysfs", 0, NULL);
    mkdir("/run", 0755);
    mount("tmpfs", "/run", "tmpfs", 0, "mode=0755");
    mkdir("/tmp", 01777);
    mount("tmpfs", "/tmp", "tmpfs", 0, "mode=1777");
}

static void set_sin(struct sockaddr *sa, const char *ip) {
    struct sockaddr_in *sin = (struct sockaddr_in *)sa;
    memset(sin, 0, sizeof(*sin));
    sin->sin_family = AF_INET;
    inet_pton(AF_INET, ip, &sin->sin_addr);
}

static int if_up(int fd, const char *name, const char *ip, const char *mask) {
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
    for (int i = 0; i < 2000 && ioctl(fd, SIOCGIFFLAGS, &ifr) < 0; i++) usleep(500);
    if (ip) {
        set_sin(&ifr.ifr_addr, ip);
        if (ioctl(fd, SIOCSIFADDR, &ifr) < 0) return -1;
        set_sin(&ifr.ifr_netmask, mask);
        if (ioctl(fd, SIOCSIFNETMASK, &ifr) < 0) return -1;
    }
    if (ioctl(fd, SIOCGIFFLAGS, &ifr) < 0) return -1;
    ifr.ifr_flags |= IFF_UP | IFF_RUNNING;
    return ioctl(fd, SIOCSIFFLAGS, &ifr);
}

static void setup_network(void) {
    int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if_up(fd, "lo", NULL, NULL);
    if (if_up(fd, "eth0", guest_ip, guest_mask) < 0) logf_("supervisor: eth0 setup failed: %s\n", strerror(errno));
    struct rtentry rt;
    memset(&rt, 0, sizeof(rt));
    set_sin(&rt.rt_dst, "0.0.0.0");
    set_sin(&rt.rt_genmask, "0.0.0.0");
    set_sin(&rt.rt_gateway, gateway);
    rt.rt_flags = RTF_UP | RTF_GATEWAY;
    rt.rt_dev = "eth0";
    if (ioctl(fd, SIOCADDRT, &rt) < 0 && errno != EEXIST) logf_("supervisor: default route failed: %s\n", strerror(errno));
    close(fd);
}

// A restored clone may sit behind a different host TAP, with a different MAC
// than the one the guest cached before the snapshot.
static void forget_gateway_mac(void) {
    int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    struct arpreq req;
    memset(&req, 0, sizeof(req));
    set_sin(&req.arp_pa, gateway);
    strncpy(req.arp_dev, "eth0", sizeof(req.arp_dev) - 1);
    ioctl(fd, SIOCDARP, &req);
    close(fd);
}

// --------------------------------------------------------------------- framing

static int io_full(int fd, void *buf, size_t n, int writing) {
    char *p = buf;
    while (n) {
        ssize_t r = writing ? write(fd, p, n) : read(fd, p, n);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return -1;
        p += r;
        n -= r;
    }
    return 0;
}

static char *recv_frame(int fd, size_t *len) {
    uint32_t be;
    if (io_full(fd, &be, 4, 0) < 0) return NULL;
    *len = ntohl(be);
    if (*len > MAX_FRAME) return NULL;
    char *buf = malloc(*len + 1);
    if (io_full(fd, buf, *len, 0) < 0) {
        free(buf);
        return NULL;
    }
    buf[*len] = 0;
    return buf;
}

struct reply {
    char buf[8192];
    size_t len;
};

static void reply_add(struct reply *r, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(r->buf + r->len, sizeof(r->buf) - r->len - 1, fmt, ap);
    va_end(ap);
    if (n > 0 && r->len + n + 1 < sizeof(r->buf)) r->len += n + 1;  // keep the NUL
}

static void send_reply(int fd, struct reply *r) {
    uint32_t be = htonl(r->len);
    io_full(fd, &be, 4, 1);
    io_full(fd, r->buf, r->len, 1);
}

// Calls fn(key, value) for each "key=value" record in buf[0..len).
#define FOR_EACH_RECORD(buf, len, key, val, body)                     \
    for (char *_p = (buf); _p < (buf) + (len); _p += strlen(_p) + 1) { \
        char *val = strchr(_p, '=');                                   \
        if (!val) continue;                                            \
        *val++ = 0;                                                    \
        const char *key = _p;                                          \
        body;                                                          \
        val[-1] = '=';                                                 \
    }

// -------------------------------------------------------------------- PREPARE

static long long warm_path(const char *path) {
    struct stat st;
    if (lstat(path, &st) < 0) return 0;
    if (S_ISDIR(st.st_mode)) {
        DIR *d = opendir(path);
        if (!d) return 0;
        long long total = 0;
        struct dirent *e;
        while ((e = readdir(d))) {
            if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
            char child[4096];
            snprintf(child, sizeof(child), "%s/%s", path, e->d_name);
            total += warm_path(child);
        }
        closedir(d);
        return total;
    }
    if (!S_ISREG(st.st_mode)) return 0;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    static char buf[1 << 20];
    long long total = 0;
    ssize_t r;
    while ((r = read(fd, buf, sizeof(buf))) > 0) total += r;
    close(fd);
    return total;
}

static int run_and_wait(const char *cmd) {
    char *argv[] = {"/bin/sh", "-c", (char *)cmd, NULL};
    char *envp[] = {"PATH=" DEFAULT_PATH, "HOME=/root", NULL};
    pid_t pid;
    if (posix_spawn(&pid, argv[0], NULL, NULL, argv, envp) != 0) return -1;
    int status;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static void handle_prepare(char *buf, size_t len, struct reply *r) {
    long long t0 = mono_us(), bytes = 0;
    int failed = 0;
    FOR_EACH_RECORD(buf, len, key, val, {
        if (!strcmp(key, "warm")) bytes += warm_path(val);
        else if (!strcmp(key, "warmrun") && run_and_wait(val) != 0) failed++;
    });
    sync();
    reply_add(r, "status=%s", failed ? "error" : "ok");
    if (failed) reply_add(r, "error=%d warmrun command(s) failed", failed);
    reply_add(r, "warm_bytes=%lld", bytes);
    reply_add(r, "prepare_us=%lld", mono_us() - t0);
}

// ---------------------------------------------------------------------- START

static int reseed_kernel_rng(const char *hex) {
    size_t n = strlen(hex) / 2;
    if (n == 0 || n > 512) return -1;
    struct {
        struct rand_pool_info info;
        unsigned char bytes[512];
    } req;
    for (size_t i = 0; i < n; i++) sscanf(hex + 2 * i, "%2hhx", &req.bytes[i]);
    req.info.entropy_count = n * 8;
    req.info.buf_size = n;
    int fd = open("/dev/urandom", O_WRONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    int rc = ioctl(fd, RNDADDENTROPY, &req.info);
    if (rc == 0) rc = ioctl(fd, RNDRESEEDCRNG);
    close(fd);
    return rc;
}

struct rootfs_times {
    long long wait_us, mount_us, overlay_us, switch_us;
};

// Mounts the tenant disk read-only, optionally under a tmpfs overlay, then
// moves it to / the way switch_root does. The disk is either new (a hot-added
// device), swapped under an existing device (shown as a capacity change), or
// in place since the snapshot with its backing replaced on the host. Returns
// NULL or an error message.
static const char *enter_rootfs(const char *dev, const char *fstype, const char *opts, int overlay,
                                unsigned long long size, struct rootfs_times *t) {
    static char err[160];
    long long t0 = mono_us();
    int fd = -1;
    for (int i = 0; i < 100000; i++) {  // up to ~10 s for a hot-added disk to appear
        fd = open(dev, O_RDONLY | O_CLOEXEC);
        if (fd >= 0) break;
        usleep(100);
    }
    if (fd < 0) return "rootfs device never appeared";
    unsigned long long cur = 0;
    for (int i = 0; size && i < 100000; i++) {
        if (ioctl(fd, BLKGETSIZE64, &cur) == 0 && cur == size) break;
        usleep(100);
    }
    if (size && cur != size) {
        close(fd);
        snprintf(err, sizeof(err), "rootfs size %llu, expected %llu", cur, size);
        return err;
    }
    ioctl(fd, BLKFLSBUF, 0);  // drop blocks cached from the placeholder
    close(fd);
    long long t1 = mono_us();

    const char *root = overlay ? "/lower" : "/newroot";
    mkdir(root, 0755);
    if (mount(dev, root, fstype, MS_RDONLY, opts) < 0) {
        snprintf(err, sizeof(err), "mount %s: %s", dev, strerror(errno));
        return err;
    }
    long long t2 = mono_us();
    if (overlay) {
        mkdir("/overlay", 0755);
        mkdir("/newroot", 0755);
        if (mount("tmpfs", "/overlay", "tmpfs", 0, "mode=0755") < 0) return "mount overlay tmpfs failed";
        mkdir("/overlay/upper", 0755);
        mkdir("/overlay/work", 0755);
        if (mount("overlay", "/newroot", "overlay", 0, "lowerdir=/lower,upperdir=/overlay/upper,workdir=/overlay/work") < 0) {
            snprintf(err, sizeof(err), "mount overlay: %s", strerror(errno));
            return err;
        }
    }
    long long t3 = mono_us();
    static const char *keep[] = {"/dev", "/proc", "/sys", "/run", "/tmp"};
    for (size_t i = 0; i < sizeof(keep) / sizeof(keep[0]); i++) {
        char target[64];
        snprintf(target, sizeof(target), "/newroot%s", keep[i]);
        if (overlay) mkdir(target, 0755);
        if (mount(keep[i], target, NULL, MS_MOVE, NULL) < 0) {
            snprintf(err, sizeof(err), "move %s: %s", keep[i], strerror(errno));
            return err;
        }
    }
    if (chdir("/newroot") < 0 || mount(".", "/", NULL, MS_MOVE, NULL) < 0 || chroot(".") < 0 || chdir("/") < 0) {
        snprintf(err, sizeof(err), "switch root: %s", strerror(errno));
        return err;
    }
    *t = (struct rootfs_times){t1 - t0, t2 - t1, t3 - t2, mono_us() - t3};
    return NULL;
}

static void handle_start(char *buf, size_t len, struct reply *r) {
    if (started) {
        reply_add(r, "status=error");
        reply_add(r, "error=already started");
        return;
    }
    long long t0 = mono_us();
    static char *envp[MAX_ITEMS + 2], *argv[MAX_ITEMS + 1];
    int nenv = 0, narg = 0, have_path = 0;
    const char *time_ns = NULL, *seed = NULL, *cwd = NULL, *hostname = NULL;
    const char *rootfs = NULL, *rootfs_fs = "ext4", *rootfs_opts = NULL;
    int rootfs_overlay = 1;
    unsigned long long rootfs_size = 0;
    struct rootfs_times rt = {0};
    const char *path = DEFAULT_PATH;

    // Records stay in buf, so split them in place and keep pointers.
    for (char *p = buf; p < buf + len; p += strlen(p) + 1) {
        char *eq = strchr(p, '=');
        if (!eq) continue;
        size_t klen = eq - p;
        char *val = eq + 1;
        if (klen == 3 && !strncmp(p, "env", 3) && nenv < MAX_ITEMS) {
            envp[nenv++] = val;
            if (!strncmp(val, "PATH=", 5)) {
                have_path = 1;
                path = val + 5;
            }
        } else if (klen == 3 && !strncmp(p, "arg", 3) && narg < MAX_ITEMS) {
            argv[narg++] = val;
        } else if (klen == 7 && !strncmp(p, "time_ns", 7)) {
            time_ns = val;
        } else if (klen == 4 && !strncmp(p, "seed", 4)) {
            seed = val;
        } else if (klen == 3 && !strncmp(p, "cwd", 3)) {
            cwd = val;
        } else if (klen == 8 && !strncmp(p, "hostname", 8)) {
            hostname = val;
        } else if (klen == 6 && !strncmp(p, "rootfs", 6)) {
            rootfs = val;
        } else if (klen == 11 && !strncmp(p, "rootfs_size", 11)) {
            rootfs_size = strtoull(val, NULL, 10);
        } else if (klen == 9 && !strncmp(p, "rootfs_fs", 9)) {
            rootfs_fs = val;
        } else if (klen == 11 && !strncmp(p, "rootfs_opts", 11)) {
            rootfs_opts = val;
        } else if (klen == 14 && !strncmp(p, "rootfs_overlay", 14)) {
            rootfs_overlay = atoi(val);
        }
    }
    if (!have_path) envp[nenv++] = "PATH=" DEFAULT_PATH;
    envp[nenv] = NULL;
    argv[narg] = NULL;
    if (narg == 0) {
        reply_add(r, "status=error");
        reply_add(r, "error=no arg= records");
        return;
    }

    long long t_clock = t0, skew_us = 0;
    if (time_ns) {
        long long ns = atoll(time_ns);
        struct timespec now, ts = {.tv_sec = ns / 1000000000LL, .tv_nsec = ns % 1000000000LL};
        clock_gettime(CLOCK_REALTIME, &now);
        skew_us = (now.tv_sec - ts.tv_sec) * 1000000LL + (now.tv_nsec - ts.tv_nsec) / 1000;
        clock_settime(CLOCK_REALTIME, &ts);
        t_clock = mono_us();
    }
    int reseeded = seed ? reseed_kernel_rng(seed) == 0 : 0;
    long long t_seed = mono_us();
    forget_gateway_mac();
    if (hostname && sethostname(hostname, strlen(hostname)) < 0) logf_("supervisor: sethostname failed: %s\n", strerror(errno));
    long long t_net = mono_us();
    if (rootfs) {
        const char *err = enter_rootfs(rootfs, rootfs_fs, rootfs_opts, rootfs_overlay, rootfs_size, &rt);
        if (err) {
            reply_add(r, "status=error");
            reply_add(r, "error=%s", err);
            return;
        }
    }
    long long t_rootfs = mono_us();

    // posix_spawnp searches the supervisor's own PATH.
    setenv("PATH", path, 1);
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    int out = console_fd >= 0 ? console_fd : open("/dev/null", O_WRONLY | O_CLOEXEC);
    posix_spawn_file_actions_adddup2(&fa, out, 1);
    posix_spawn_file_actions_adddup2(&fa, out, 2);
    if (cwd) posix_spawn_file_actions_addchdir_np(&fa, cwd);
    posix_spawnattr_t at;
    posix_spawnattr_init(&at);
    sigset_t none, all;
    sigemptyset(&none);
    sigfillset(&all);
    posix_spawnattr_setsigmask(&at, &none);
    posix_spawnattr_setsigdefault(&at, &all);
    posix_spawnattr_setflags(&at, POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
    pid_t pid;
    int err = posix_spawnp(&pid, argv[0], &fa, &at, argv, envp);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&at);
    long long t_spawn = mono_us();

    if (err) {
        reply_add(r, "status=error");
        reply_add(r, "error=spawn %s: %s", argv[0], strerror(err));
        return;
    }
    started = 1;
    logf_("supervisor: started %s as pid %d\n", argv[0], pid);
    reply_add(r, "status=ok");
    reply_add(r, "pid=%d", pid);
    reply_add(r, "clock_skew_us=%lld", skew_us);
    reply_add(r, "reseeded=%d", reseeded);
    reply_add(r, "clock_us=%lld", t_clock - t0);
    reply_add(r, "reseed_us=%lld", t_seed - t_clock);
    reply_add(r, "net_us=%lld", t_net - t_seed);
    reply_add(r, "rootfs_us=%lld", t_rootfs - t_net);
    reply_add(r, "rootfs_wait_us=%lld", rt.wait_us);
    reply_add(r, "rootfs_mount_us=%lld", rt.mount_us);
    reply_add(r, "rootfs_overlay_us=%lld", rt.overlay_us);
    reply_add(r, "rootfs_switch_us=%lld", rt.switch_us);
    reply_add(r, "spawn_us=%lld", t_spawn - t_rootfs);
}

// ----------------------------------------------------------------------- main

static void on_sigchld(int sig) {
    (void)sig;
    child_exited = 1;
}

static void reap(void) {
    int status;
    pid_t pid;
    child_exited = 0;
    while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
        if (WIFEXITED(status)) logf_("supervisor: pid %d exited %d\n", pid, WEXITSTATUS(status));
        else if (WIFSIGNALED(status)) logf_("supervisor: pid %d killed by signal %d\n", pid, WTERMSIG(status));
    }
}

int main(void) {
    guest_ip = env_or("sv_ip", "172.16.0.2");
    guest_mask = env_or("sv_mask", "255.255.255.252");
    gateway = env_or("sv_gw", "172.16.0.1");
    unsigned port = atoi(env_or("sv_port", "1024"));

    mount_basics();
    console_fd = open("/dev/console", O_WRONLY | O_NOCTTY | O_CLOEXEC);
    setup_network();

    struct sigaction sa = {.sa_handler = on_sigchld};  // no SA_RESTART: wake accept()
    sigaction(SIGCHLD, &sa, NULL);

    int l = socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_vm addr = {.svm_family = AF_VSOCK, .svm_cid = VMADDR_CID_ANY, .svm_port = port};
    if (l < 0 || bind(l, (struct sockaddr *)&addr, sizeof(addr)) < 0 || listen(l, 16) < 0) {
        logf_("supervisor: vsock listen on port %u failed: %s\n", port, strerror(errno));
        for (;;) pause();
    }
    logf_("supervisor: listening on vsock port %u\n", port);

    for (;;) {
        if (child_exited) reap();
        int c = accept4(l, NULL, NULL, SOCK_CLOEXEC);
        if (c < 0) continue;
        size_t len;
        char *buf;
        while ((buf = recv_frame(c, &len))) {
            struct reply r = {.len = 0};
            const char *cmd = "";
            FOR_EACH_RECORD(buf, len, key, val, {
                if (!strcmp(key, "cmd")) cmd = val;
            });
            if (!strcmp(cmd, "PREPARE")) handle_prepare(buf, len, &r);
            else if (!strcmp(cmd, "START")) handle_start(buf, len, &r);
            else if (!strcmp(cmd, "PING")) reply_add(&r, "status=ok");
            else {
                reply_add(&r, "status=error");
                reply_add(&r, "error=unknown cmd");
            }
            send_reply(c, &r);
            free(buf);
        }
        close(c);
    }
}
