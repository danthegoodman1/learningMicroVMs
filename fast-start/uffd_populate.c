// Firecracker UFFD backend handler that copies the whole memory snapshot into
// guest memory as soon as Firecracker hands over the userfaultfd, then stays
// alive holding the fd. Prints "populated <ms>" when done.
// usage: uffd_populate <socket> <memory-file>
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/userfaultfd.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

static uint64_t field(const char *obj, const char *key) {
    const char *p = strstr(obj, key);
    if (!p) return 0;
    p = strchr(p, ':');
    return strtoull(p + 1, NULL, 10);
}

int main(int argc, char **argv) {
    int srv = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    strncpy(a.sun_path, argv[1], sizeof(a.sun_path) - 1);
    unlink(argv[1]);
    if (bind(srv, (struct sockaddr *)&a, sizeof(a)) || listen(srv, 1)) { perror("listen"); return 1; }
    int mfd = open(argv[2], O_RDONLY);
    struct stat st;
    fstat(mfd, &st);
    char *mem = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE | MAP_POPULATE, mfd, 0);
    printf("listening\n");
    fflush(stdout);

    int c = accept(srv, NULL, NULL);
    char buf[65536] = {0};
    char cbuf[CMSG_SPACE(sizeof(int))];
    struct iovec iov = {buf, sizeof(buf) - 1};
    struct msghdr msg = {.msg_iov = &iov, .msg_iovlen = 1, .msg_control = cbuf, .msg_controllen = sizeof(cbuf)};
    if (recvmsg(c, &msg, 0) < 0) { perror("recvmsg"); return 1; }
    int uffd;
    memcpy(&uffd, CMSG_DATA(CMSG_FIRSTHDR(&msg)), sizeof(int));

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    // buf is a JSON array of {"base_host_virt_addr":..,"size":..,"offset":..,"page_size":..}
    for (char *o = strchr(buf, '{'); o; o = strchr(o + 1, '{')) {
        uint64_t base = field(o, "\"base_host_virt_addr\"");
        uint64_t size = field(o, "\"size\"");
        uint64_t off = field(o, "\"offset\"");
        uint64_t done = 0;
        while (done < size) {
            struct uffdio_copy cp = {.dst = base + done, .src = (uint64_t)(mem + off + done), .len = size - done};
            if (ioctl(uffd, UFFDIO_COPY, &cp) < 0 && cp.copy <= 0) {
                if (cp.copy == -EEXIST) { done += 4096; continue; }
                perror("UFFDIO_COPY");
                return 1;
            }
            done += cp.copy > 0 ? (uint64_t)cp.copy : 0;
        }
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    printf("populated %.2f\n", (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6);
    fflush(stdout);
    for (;;) pause();
}
