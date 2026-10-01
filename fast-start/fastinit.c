// Minimal PID 1 for start-time benchmarks.
// Configures eth0 (unless the kernel ip= option already did), sends
// "ready" to the host over UDP, then answers every UDP datagram with "pong".
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/io.h>
#include <sys/ioctl.h>
#include <sys/klog.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define GUEST_IP "172.16.0.2"
#define HOST_IP "172.16.0.1"
#define NETMASK "255.255.255.252"
#define PORT 7777

static long long now_ns(clockid_t c) {
    struct timespec ts;
    clock_gettime(c, &ts);
    return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static void set_addr(struct ifreq *ifr, const char *ip) {
    struct sockaddr_in *sin = (struct sockaddr_in *)&ifr->ifr_addr;
    memset(sin, 0, sizeof(*sin));
    sin->sin_family = AF_INET;
    inet_pton(AF_INET, ip, &sin->sin_addr);
}

static int config_eth0(void) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strcpy(ifr.ifr_name, "eth0");
    for (int i = 0; i < 2000; i++) {
        if (ioctl(fd, SIOCGIFFLAGS, &ifr) == 0) break;
        usleep(500);
    }
    set_addr(&ifr, GUEST_IP);
    if (ioctl(fd, SIOCSIFADDR, &ifr) < 0) { perror("SIOCSIFADDR"); return -1; }
    set_addr(&ifr, NETMASK);
    if (ioctl(fd, SIOCSIFNETMASK, &ifr) < 0) { perror("SIOCSIFNETMASK"); return -1; }
    ioctl(fd, SIOCGIFFLAGS, &ifr);
    ifr.ifr_flags |= IFF_UP | IFF_RUNNING;
    if (ioctl(fd, SIOCSIFFLAGS, &ifr) < 0) { perror("SIOCSIFFLAGS"); return -1; }
    close(fd);
    return 0;
}

int main(int argc, char **argv) {
    long long t_init = now_ns(CLOCK_BOOTTIME);
    const char *net = getenv("fi_net");
    const char *bt = getenv("fi_bt");

    if (bt && strcmp(bt, "1") == 0 && ioperm(0x3f0, 1, 1) == 0) outb(123, 0x3f0);
    if (!net || strcmp(net, "kernel") != 0) config_eth0();

    int s = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in me = {.sin_family = AF_INET, .sin_port = htons(PORT)};
    bind(s, (struct sockaddr *)&me, sizeof(me));

    struct sockaddr_in host = {.sin_family = AF_INET, .sin_port = htons(PORT)};
    inet_pton(AF_INET, HOST_IP, &host.sin_addr);

    long long t_net = now_ns(CLOCK_BOOTTIME);
    char buf[256];
    int n = snprintf(buf, sizeof(buf), "ready init_us=%lld net_us=%lld",
                     t_init / 1000, t_net / 1000);
    if (sendto(s, buf, n, 0, (struct sockaddr *)&host, sizeof(host)) < 0) perror("sendto ready");

    const char *dm = getenv("fi_dmesg");
    if (dm && strcmp(dm, "1") == 0) {
        static char log[1 << 20];
        int len = klogctl(3, log, sizeof(log));
        for (int off = 0; len > 0 && off < len; off += 1200) {
            char pkt[1300];
            int chunk = len - off < 1200 ? len - off : 1200;
            memcpy(pkt, "dmesg", 5);
            memcpy(pkt + 5, log + off, chunk);
            sendto(s, pkt, chunk + 5, 0, (struct sockaddr *)&host, sizeof(host));
            usleep(200);
        }
    }

    for (;;) {
        struct sockaddr_in from;
        socklen_t fl = sizeof(from);
        char in[256];
        ssize_t r = recvfrom(s, in, sizeof(in) - 1, 0, (struct sockaddr *)&from, &fl);
        if (r < 0) continue;
        in[r] = 0;
        n = snprintf(buf, sizeof(buf), "pong %s", in);
        sendto(s, buf, n, 0, (struct sockaddr *)&from, fl);
    }
}
