#include "clashrs.h"

#include <libproc.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/proc_info.h>
#include <unistd.h>

struct engine_arguments {
    const char *profile;
    const char *log_path;
    const char *runtime_path;
    int32_t routing_mode;
    char *result;
};

enum { DEFAULT_FD_GROWTH_BUDGET = 4 };

static int open_file_descriptor_count(void) {
    int required = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, NULL, 0);
    if (required <= 0) {
        return -1;
    }
    size_t capacity = (size_t)required + (16U * PROC_PIDLISTFD_SIZE);
    if (capacity > (size_t)INT32_MAX) {
        return -1;
    }
    void *buffer = malloc(capacity);
    if (buffer == NULL) {
        return -1;
    }
    int actual = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, buffer,
                              (int)capacity);
    free(buffer);
    if (actual < 0 || actual % (int)PROC_PIDLISTFD_SIZE != 0) {
        return -1;
    }
    return actual / (int)PROC_PIDLISTFD_SIZE;
}

static int file_descriptor_growth_budget(void) {
    const char *value = getenv("AETHER_SMOKE_FD_GROWTH_BUDGET");
    if (value == NULL) {
        return DEFAULT_FD_GROWTH_BUDGET;
    }
    char *end = NULL;
    long parsed = strtol(value, &end, 10);
    if (end == value || *end != '\0' || parsed < 0 || parsed > 64) {
        return -1;
    }
    return (int)parsed;
}

static void packet_output(
    const uint8_t *packet,
    size_t length,
    uint8_t ip_version,
    void *context
) {
    (void)packet;
    (void)length;
    (void)ip_version;
    (void)context;
}

static void *run_engine(void *raw_arguments) {
    struct engine_arguments *arguments = raw_arguments;
    arguments->result = clash_start_packet_flow_with_mode(
        arguments->profile,
        arguments->log_path,
        arguments->runtime_path,
        1500,
        arguments->routing_mode,
        1
    );
    return NULL;
}

static uint32_t read_be32(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24)
        | ((uint32_t)bytes[1] << 16)
        | ((uint32_t)bytes[2] << 8)
        | (uint32_t)bytes[3];
}

static int verify_selector_snapshot(uint32_t expected_index) {
    static const uint8_t group[] = "Route";
    size_t required = 0;
    int32_t status = clash_packet_selector_snapshot_v1(
        group,
        sizeof(group) - 1,
        NULL,
        0,
        &required
    );
    if (status != CLASH_FLOW_OK || required < 12 || required > 1024) {
        return 0;
    }
    uint8_t *snapshot = malloc(required);
    if (snapshot == NULL) {
        return 0;
    }
    size_t copied = required;
    status = clash_packet_selector_snapshot_v1(
        group,
        sizeof(group) - 1,
        snapshot,
        required,
        &copied
    );
    int valid = status == CLASH_FLOW_OK
        && copied == required
        && memcmp(snapshot, "ARS1", 4) == 0
        && read_be32(snapshot + 4) == expected_index
        && read_be32(snapshot + 8) == 2;
    free(snapshot);
    return valid;
}

static int verify_selector_control(void) {
    static const uint8_t group[] = "Route";
    static const uint8_t member[] = "REJECT";
    if (!verify_selector_snapshot(0)) {
        return 0;
    }
    if (clash_packet_selector_select_v1(
            group,
            sizeof(group) - 1,
            member,
            sizeof(member) - 1
        ) != CLASH_FLOW_OK) {
        return 0;
    }
    return verify_selector_snapshot(1);
}

static int verify_telemetry_snapshot(void) {
    size_t required = 0;
    int32_t status = clash_packet_telemetry_snapshot_v1(
        50,
        NULL,
        0,
        &required
    );
    if (status != CLASH_FLOW_OK || required != 48) {
        return 0;
    }
    uint8_t snapshot[48];
    size_t copied = sizeof(snapshot);
    status = clash_packet_telemetry_snapshot_v1(
        50,
        snapshot,
        sizeof(snapshot),
        &copied
    );
    return status == CLASH_FLOW_OK
        && copied == sizeof(snapshot)
        && memcmp(snapshot, "ART1", 4) == 0
        && read_be32(snapshot + 44) == 0;
}

static int run_cycle(
    const char *profile,
    const char *runtime_path,
    const char *log_path,
    long cycle
) {
    if (clash_install_packet_flow(packet_output, NULL) != 1) {
        fprintf(stderr, "cycle %ld: packet bridge installation failed\n", cycle);
        return 1;
    }

    struct engine_arguments arguments = {
        .profile = profile,
        .log_path = log_path,
        .runtime_path = runtime_path,
        .routing_mode = (int32_t)((cycle - 1) % 3),
        .result = NULL,
    };
    pthread_t engine_thread;
    if (pthread_create(&engine_thread, NULL, run_engine, &arguments) != 0) {
        clash_uninstall_packet_flow();
        fprintf(stderr, "cycle %ld: engine thread creation failed\n", cycle);
        return 1;
    }

    int ready = 0;
    for (int attempt = 0; attempt < 400; attempt += 1) {
        if (clash_packet_flow_ready() == 1) {
            ready = 1;
            break;
        }
        usleep(25000);
    }

    int selector_verified = ready && verify_selector_control();
    int telemetry_verified = ready && verify_telemetry_snapshot();
    int stopped = clash_shutdown();
    pthread_join(engine_thread, NULL);

    if (!ready) {
        fprintf(stderr, "cycle %ld: packet flow did not become ready\n", cycle);
        if (arguments.result != NULL) {
            fprintf(stderr, "engine result: %s\n", arguments.result);
        }
        clash_free_string(arguments.result);
        return 1;
    }
    if (!selector_verified) {
        fprintf(stderr, "cycle %ld: selector control was not verified\n", cycle);
        clash_free_string(arguments.result);
        return 1;
    }
    if (!telemetry_verified) {
        fprintf(stderr, "cycle %ld: telemetry snapshot was not verified\n", cycle);
        clash_free_string(arguments.result);
        return 1;
    }
    if (stopped != 1 || arguments.result == NULL || strlen(arguments.result) != 0) {
        fprintf(stderr, "cycle %ld: engine did not stop cleanly\n", cycle);
        if (arguments.result != NULL) {
            fprintf(stderr, "engine result: %s\n", arguments.result);
        }
        clash_free_string(arguments.result);
        return 1;
    }
    if (clash_packet_flow_ready() != 0) {
        fprintf(stderr, "cycle %ld: readiness remained set after shutdown\n", cycle);
        clash_free_string(arguments.result);
        return 1;
    }

    clash_free_string(arguments.result);
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: core_smoke RUNTIME_DIR LOG_PATH\n");
        return 64;
    }

    const char *profile =
        "port: 0\n"
        "socks-port: 0\n"
        "mixed-port: 0\n"
        "allow-lan: false\n"
        "mode: direct\n"
        "log-level: error\n"
        "external-controller: ''\n"
        "dns:\n"
        "  enable: false\n"
        "proxies: []\n"
        "proxy-groups:\n"
        "  - name: Route\n"
        "    type: select\n"
        "    proxies:\n"
        "      - DIRECT\n"
        "      - REJECT\n"
        "rules:\n"
        "  - MATCH,Route\n";

    char *legacy_result = clash_start(NULL, NULL, NULL, 1);
    const char *expected_legacy_error =
        "Error: legacy launcher is unavailable in embedded mode";
    if (legacy_result == NULL
        || strcmp(legacy_result, expected_legacy_error) != 0) {
        fprintf(stderr, "embedded legacy launcher was not disabled\n");
        clash_free_string(legacy_result);
        return 1;
    }
    clash_free_string(legacy_result);

    int fd_growth_budget = file_descriptor_growth_budget();
    int baseline_fd_count = open_file_descriptor_count();
    int warmed_fd_count = -1;
    if (fd_growth_budget < 0 || baseline_fd_count < 0) {
        fprintf(stderr, "could not establish the file-descriptor baseline\n");
        return 64;
    }

    long cycles = 1;
    const char *cycles_value = getenv("AETHER_SMOKE_CYCLES");
    if (cycles_value != NULL) {
        char *end = NULL;
        cycles = strtol(cycles_value, &end, 10);
        if (end == cycles_value || *end != '\0' || cycles < 1 || cycles > 1000) {
            fprintf(stderr, "AETHER_SMOKE_CYCLES must be between 1 and 1000\n");
            return 64;
        }
    }

    for (long cycle = 1; cycle <= cycles; cycle += 1) {
        if (run_cycle(profile, argv[1], argv[2], cycle) != 0) {
            return 1;
        }
        if (cycle == 1) {
            warmed_fd_count = open_file_descriptor_count();
            if (warmed_fd_count < 0) {
                fprintf(stderr, "could not sample warmed file descriptors\n");
                return 1;
            }
        }
    }

    int final_fd_count = open_file_descriptor_count();
    int fd_growth = final_fd_count - warmed_fd_count;
    if (final_fd_count < 0 || fd_growth > fd_growth_budget) {
        fprintf(stderr,
                "file-descriptor growth exceeded budget: "
                "warmed=%d final=%d budget=%d\n",
                warmed_fd_count, final_fd_count, fd_growth_budget);
        return 1;
    }

    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0) {
        perror("getrusage");
        return 1;
    }

    long rss_budget = 0;
    const char *rss_budget_value = getenv("AETHER_SMOKE_RSS_BUDGET_BYTES");
    if (rss_budget_value != NULL) {
        char *end = NULL;
        rss_budget = strtol(rss_budget_value, &end, 10);
        if (end == rss_budget_value || *end != '\0' || rss_budget < 1) {
            fprintf(stderr, "AETHER_SMOKE_RSS_BUDGET_BYTES must be positive\n");
            return 64;
        }
        if (usage.ru_maxrss > rss_budget) {
            fprintf(
                stderr,
                "max RSS exceeded budget: measured=%ld budget=%ld\n",
                usage.ru_maxrss,
                rss_budget
            );
            return 1;
        }
    }

    printf(
        "isolated packet-flow startup, selector, telemetry, and shutdown passed: cycles=%ld "
        "max_rss_bytes=%ld rss_budget_bytes=%ld "
        "fd_baseline=%d fd_warmed=%d fd_final=%d fd_growth=%d "
        "fd_growth_budget=%d\n",
        cycles,
        usage.ru_maxrss,
        rss_budget,
        baseline_fd_count,
        warmed_fd_count,
        final_fd_count,
        fd_growth,
        fd_growth_budget
    );
    return 0;
}
