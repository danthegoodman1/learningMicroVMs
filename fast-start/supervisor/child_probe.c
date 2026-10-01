// Test child for the supervisor. Reports, over UDP, the INSTANCE_ID it got
// from its environment, eight bytes from getrandom(), and its wall clock, so
// the host can check that each restored clone is distinct and on time.
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

int main(void) {
    const char *id = getenv("INSTANCE_ID");
    const char *host = getenv("REPORT_HOST");
    const char *port = getenv("REPORT_PORT");
    unsigned char rnd[8] = {0};
    if (getrandom(rnd, sizeof(rnd), 0) != sizeof(rnd)) return 1;
    struct timespec rt;
    clock_gettime(CLOCK_REALTIME, &rt);

    char msg[256];
    int n = snprintf(msg, sizeof(msg), "child id=%s rnd=%02x%02x%02x%02x%02x%02x%02x%02x rt=%lld",
                     id ? id : "", rnd[0], rnd[1], rnd[2], rnd[3], rnd[4], rnd[5], rnd[6], rnd[7],
                     (long long)rt.tv_sec * 1000000000LL + rt.tv_nsec);
    struct sockaddr_in to = {.sin_family = AF_INET, .sin_port = htons(port ? atoi(port) : 7777)};
    inet_pton(AF_INET, host ? host : "172.16.0.1", &to.sin_addr);
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    return sendto(s, msg, n, 0, (struct sockaddr *)&to, sizeof(to)) == n ? 0 : 1;
}
