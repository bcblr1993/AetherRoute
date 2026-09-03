#include <errno.h>
#include <libproc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>

static int parse_pid(const char *value, pid_t *pid) {
    errno = 0;
    char *end = NULL;
    long parsed = strtol(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || parsed <= 0 ||
        parsed > INT32_MAX) {
        return 0;
    }
    *pid = (pid_t)parsed;
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: process_footprint_probe PID\n");
        return 64;
    }

    pid_t pid = 0;
    if (!parse_pid(argv[1], &pid)) {
        fprintf(stderr, "invalid PID\n");
        return 64;
    }

    struct rusage_info_v4 usage = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0) {
        perror("proc_pid_rusage");
        return 1;
    }

    int fd_bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    long fd_count = fd_bytes >= 0
        ? fd_bytes / (long)sizeof(struct proc_fdinfo)
        : -1;

    printf(
        "{\"schema\":1,\"pid\":%d,\"physical_footprint_bytes\":%llu,"
        "\"lifetime_max_footprint_bytes\":%llu,\"user_time_ns\":%llu,"
        "\"system_time_ns\":%llu,\"fd_count\":%ld}\n",
        pid,
        usage.ri_phys_footprint,
        usage.ri_lifetime_max_phys_footprint,
        usage.ri_user_time,
        usage.ri_system_time,
        fd_count
    );
    return 0;
}
