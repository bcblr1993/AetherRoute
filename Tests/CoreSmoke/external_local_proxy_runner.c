#include "clashrs.h"

#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum { MAXIMUM_PROFILE_BYTES = 10 * 1024 * 1024 };

struct engine_arguments {
    const char *profile;
    const char *runtime_path;
    const clash_packet_local_proxy_v1_t *local_proxy;
    char *result;
    volatile sig_atomic_t finished;
};

static volatile sig_atomic_t stop_requested = 0;

static void request_stop(int signal_number) {
    (void)signal_number;
    stop_requested = 1;
}

static char *read_profile(const char *path) {
    FILE *file = fopen(path, "rb");
    if (file == NULL || fseek(file, 0, SEEK_END) != 0) {
        if (file != NULL) {
            (void)fclose(file);
        }
        return NULL;
    }
    long size = ftell(file);
    if (size <= 0 || size > MAXIMUM_PROFILE_BYTES
        || fseek(file, 0, SEEK_SET) != 0) {
        (void)fclose(file);
        return NULL;
    }
    char *profile = malloc((size_t)size + 1U);
    if (profile == NULL
        || fread(profile, 1U, (size_t)size, file) != (size_t)size) {
        free(profile);
        (void)fclose(file);
        return NULL;
    }
    (void)fclose(file);
    profile[size] = '\0';
    return profile;
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
    arguments->result = clash_start_packet_flow_with_policy_and_local_proxy_v1(
        arguments->profile,
        "",
        arguments->runtime_path,
        1500,
        0,
        NULL,
        arguments->local_proxy,
        1
    );
    arguments->finished = 1;
    return NULL;
}

static int parse_port(const char *value, uint32_t *port) {
    char *end = NULL;
    unsigned long parsed = strtoul(value, &end, 10);
    if (end == value || *end != '\0' || parsed < 1024 || parsed > 65535) {
        return 0;
    }
    *port = (uint32_t)parsed;
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 5) {
        fprintf(
            stderr,
            "usage: external_local_proxy_runner PROFILE RUNTIME_DIR HTTP_PORT SOCKS_PORT\n"
        );
        return 64;
    }

    clash_packet_local_proxy_v1_t local_proxy = {
        .struct_size = sizeof(local_proxy),
        .enabled = 1,
        .http_port = 0,
        .socks_port = 0,
    };
    if (!parse_port(argv[3], &local_proxy.http_port)
        || !parse_port(argv[4], &local_proxy.socks_port)
        || local_proxy.http_port == local_proxy.socks_port) {
        fprintf(stderr, "local proxy ports must be distinct values from 1024 to 65535\n");
        return 64;
    }

    char *profile = read_profile(argv[1]);
    if (profile == NULL) {
        fprintf(stderr, "profile is missing, empty, unreadable, or too large\n");
        return 66;
    }

    if (signal(SIGINT, request_stop) == SIG_ERR
        || signal(SIGTERM, request_stop) == SIG_ERR
        || clash_install_packet_flow(packet_output, NULL) != 1) {
        free(profile);
        fprintf(stderr, "failed to prepare isolated packet-flow core\n");
        return 1;
    }

    struct engine_arguments arguments = {
        .profile = profile,
        .runtime_path = argv[2],
        .local_proxy = &local_proxy,
        .result = NULL,
        .finished = 0,
    };
    pthread_t thread;
    if (pthread_create(&thread, NULL, run_engine, &arguments) != 0) {
        clash_uninstall_packet_flow();
        free(profile);
        fprintf(stderr, "failed to start isolated packet-flow core\n");
        return 1;
    }

    int ready = 0;
    for (int attempt = 0; attempt < 600 && !arguments.finished; attempt += 1) {
        if (clash_packet_flow_ready() == 1) {
            ready = 1;
            break;
        }
        usleep(25000);
    }
    if (!ready) {
        (void)clash_shutdown();
        (void)pthread_join(thread, NULL);
        clash_uninstall_packet_flow();
        clash_free_string(arguments.result);
        free(profile);
        fprintf(stderr, "isolated local proxy core did not become ready\n");
        return 1;
    }

    printf(
        "READY http=127.0.0.1:%u socks=127.0.0.1:%u\n",
        local_proxy.http_port,
        local_proxy.socks_port
    );
    (void)fflush(stdout);
    while (!stop_requested && !arguments.finished) {
        usleep(100000);
    }

    int stopped = clash_shutdown();
    (void)pthread_join(thread, NULL);
    clash_uninstall_packet_flow();
    int success = stopped == 1
        && arguments.result != NULL
        && strlen(arguments.result) == 0U;
    clash_free_string(arguments.result);
    free(profile);
    if (!success) {
        fprintf(stderr, "isolated local proxy core did not stop cleanly\n");
        return 1;
    }
    puts("STOPPED cleanly");
    return 0;
}
