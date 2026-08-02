#include "clashrs.h"

#include <arpa/inet.h>
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

enum {
    REPETITIONS = 5,
    LATENCY_SAMPLES = 200,
    PAYLOAD_BYTES = 32 * 1024 * 1024,
    CHUNK_BYTES = 1024 * 1024,
    SERVER_BUFFER_BYTES = 64 * 1024,
    TIMEOUT_SECONDS = 10,
};

typedef enum server_mode {
    SERVER_SINK,
    SERVER_ECHO,
} server_mode_t;

typedef struct loopback_server {
    int listener;
    uint16_t port;
    server_mode_t mode;
    size_t expected_bytes;
    pthread_t thread;
    size_t received_bytes;
    int error;
} loopback_server_t;

typedef struct engine_arguments {
    const char *profile;
    const char *runtime_path;
    clash_packet_local_proxy_v1_t local_proxy;
    char *result;
} engine_arguments_t;

static double monotonic_seconds(void) {
    struct timespec value;
    (void)clock_gettime(CLOCK_MONOTONIC, &value);
    return (double)value.tv_sec + (double)value.tv_nsec / 1000000000.0;
}

static int configure_socket(int descriptor) {
    struct timeval timeout = {.tv_sec = TIMEOUT_SECONDS, .tv_usec = 0};
    return setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                      (socklen_t)sizeof(timeout)) == 0 &&
           setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                      (socklen_t)sizeof(timeout)) == 0;
}

static int send_all(int descriptor, const uint8_t *bytes, size_t length) {
    size_t offset = 0U;
    while (offset < length) {
        ssize_t count = send(descriptor, bytes + offset, length - offset, 0);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            return -1;
        }
        offset += (size_t)count;
    }
    return 0;
}

static int receive_exact(int descriptor, uint8_t *bytes, size_t length) {
    size_t offset = 0U;
    while (offset < length) {
        ssize_t count = recv(descriptor, bytes + offset, length - offset, 0);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            return -1;
        }
        offset += (size_t)count;
    }
    return 0;
}

static void *server_main(void *raw_server) {
    loopback_server_t *server = (loopback_server_t *)raw_server;
    int client = accept(server->listener, NULL, NULL);
    if (client < 0 || !configure_socket(client)) {
        server->error = client < 0 ? errno : EIO;
        if (client >= 0) {
            (void)close(client);
        }
        (void)close(server->listener);
        return NULL;
    }
    uint8_t buffer[SERVER_BUFFER_BYTES];
    while (server->received_bytes < server->expected_bytes) {
        size_t remaining = server->expected_bytes - server->received_bytes;
        size_t requested = remaining < sizeof(buffer) ? remaining : sizeof(buffer);
        ssize_t count = recv(client, buffer, requested, 0);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            server->error = count < 0 ? errno : EPIPE;
            break;
        }
        server->received_bytes += (size_t)count;
        if (server->mode == SERVER_ECHO &&
            send_all(client, buffer, (size_t)count) != 0) {
            server->error = errno == 0 ? EIO : errno;
            break;
        }
    }
    (void)close(client);
    (void)close(server->listener);
    return NULL;
}

static int server_start(loopback_server_t *server, server_mode_t mode,
                        size_t expected_bytes) {
    (void)memset(server, 0, sizeof(*server));
    server->listener = socket(AF_INET, SOCK_STREAM, 0);
    if (server->listener < 0 || !configure_socket(server->listener)) {
        return -1;
    }
    int reuse = 1;
    (void)setsockopt(server->listener, SOL_SOCKET, SO_REUSEADDR, &reuse,
                     (socklen_t)sizeof(reuse));
    struct sockaddr_in address = {
        .sin_family = AF_INET,
        .sin_port = 0,
        .sin_addr = {.s_addr = htonl(INADDR_LOOPBACK)},
    };
    socklen_t length = (socklen_t)sizeof(address);
    if (bind(server->listener, (const struct sockaddr *)&address, length) != 0 ||
        listen(server->listener, 1) != 0 ||
        getsockname(server->listener, (struct sockaddr *)&address, &length) != 0) {
        (void)close(server->listener);
        return -1;
    }
    server->port = ntohs(address.sin_port);
    server->mode = mode;
    server->expected_bytes = expected_bytes;
    if (pthread_create(&server->thread, NULL, server_main, server) != 0) {
        (void)close(server->listener);
        return -1;
    }
    return 0;
}

static int server_join(loopback_server_t *server) {
    return pthread_join(server->thread, NULL) == 0 && server->error == 0 &&
           server->received_bytes == server->expected_bytes
               ? 0
               : -1;
}

static int connect_loopback(uint16_t port) {
    int descriptor = socket(AF_INET, SOCK_STREAM, 0);
    if (descriptor < 0 || !configure_socket(descriptor)) {
        return -1;
    }
    struct sockaddr_in address = {
        .sin_family = AF_INET,
        .sin_port = htons(port),
        .sin_addr = {.s_addr = htonl(INADDR_LOOPBACK)},
    };
    if (connect(descriptor, (const struct sockaddr *)&address,
                (socklen_t)sizeof(address)) != 0) {
        (void)close(descriptor);
        return -1;
    }
    return descriptor;
}

static uint16_t unused_loopback_port(void) {
    loopback_server_t server;
    (void)memset(&server, 0, sizeof(server));
    server.listener = socket(AF_INET, SOCK_STREAM, 0);
    if (server.listener < 0) {
        return 0;
    }
    struct sockaddr_in address = {
        .sin_family = AF_INET,
        .sin_port = 0,
        .sin_addr = {.s_addr = htonl(INADDR_LOOPBACK)},
    };
    socklen_t length = (socklen_t)sizeof(address);
    if (bind(server.listener, (const struct sockaddr *)&address, length) != 0 ||
        getsockname(server.listener, (struct sockaddr *)&address, &length) != 0) {
        (void)close(server.listener);
        return 0;
    }
    (void)close(server.listener);
    return ntohs(address.sin_port);
}

static int connect_socks5(uint16_t proxy_port, uint16_t target_port) {
    int descriptor = connect_loopback(proxy_port);
    const uint8_t greeting[] = {0x05U, 0x01U, 0x00U};
    uint8_t greeting_response[2];
    if (descriptor < 0 ||
        send_all(descriptor, greeting, sizeof(greeting)) != 0 ||
        receive_exact(descriptor, greeting_response,
                      sizeof(greeting_response)) != 0 ||
        greeting_response[0] != 0x05U || greeting_response[1] != 0x00U) {
        if (descriptor >= 0) {
            (void)close(descriptor);
        }
        return -1;
    }
    uint8_t request[] = {0x05U, 0x01U, 0x00U, 0x01U, 127U,
                         0U,    0U,    1U,    0U,    0U};
    request[8] = (uint8_t)(target_port >> 8U);
    request[9] = (uint8_t)target_port;
    uint8_t response[10];
    if (send_all(descriptor, request, sizeof(request)) != 0 ||
        receive_exact(descriptor, response, sizeof(response)) != 0 ||
        response[0] != 0x05U || response[1] != 0x00U ||
        response[3] != 0x01U) {
        (void)close(descriptor);
        return -1;
    }
    return descriptor;
}

static void packet_output(const uint8_t *packet, size_t length,
                          uint8_t ip_version, void *context) {
    (void)packet;
    (void)length;
    (void)ip_version;
    (void)context;
}

static void *engine_main(void *raw_arguments) {
    engine_arguments_t *arguments = (engine_arguments_t *)raw_arguments;
    arguments->result = clash_start_packet_flow_with_policy_and_local_proxy_v1(
        arguments->profile, "", arguments->runtime_path, 1500, 0, NULL,
        &arguments->local_proxy, 1);
    return NULL;
}

static int start_engine(engine_arguments_t *arguments, pthread_t *thread) {
    if (clash_install_packet_flow(packet_output, NULL) != 1 ||
        pthread_create(thread, NULL, engine_main, arguments) != 0) {
        return -1;
    }
    for (int attempt = 0; attempt < 400; ++attempt) {
        if (clash_packet_flow_ready() == 1) {
            int descriptor = connect_loopback(
                (uint16_t)arguments->local_proxy.socks_port);
            if (descriptor >= 0) {
                (void)close(descriptor);
                return 0;
            }
        }
        usleep(25000);
    }
    return -1;
}

static int stop_engine(engine_arguments_t *arguments, pthread_t thread) {
    int stopped = clash_shutdown();
    int joined = pthread_join(thread, NULL);
    clash_uninstall_packet_flow();
    int valid = stopped == 1 && joined == 0 && arguments->result != NULL &&
                strlen(arguments->result) == 0 &&
                clash_packet_flow_ready() == 0;
    if (!valid && arguments->result != NULL) {
        fprintf(stderr, "PacketFlow engine result: %s\n", arguments->result);
    }
    clash_free_string(arguments->result);
    arguments->result = NULL;
    return valid ? 0 : -1;
}

static int throughput_once(uint16_t proxy_port, const uint8_t *payload,
                           double *seconds) {
    loopback_server_t server;
    if (server_start(&server, SERVER_SINK, PAYLOAD_BYTES) != 0) {
        return -1;
    }
    int descriptor = proxy_port == 0 ? connect_loopback(server.port)
                                     : connect_socks5(proxy_port, server.port);
    if (descriptor < 0) {
        return -1;
    }
    double started = monotonic_seconds();
    for (size_t offset = 0U; offset < PAYLOAD_BYTES; offset += CHUNK_BYTES) {
        if (send_all(descriptor, payload, CHUNK_BYTES) != 0) {
            return -1;
        }
    }
    (void)shutdown(descriptor, SHUT_WR);
    (void)close(descriptor);
    if (server_join(&server) != 0) {
        return -1;
    }
    *seconds = monotonic_seconds() - started;
    return 0;
}

static int latency_samples(uint16_t proxy_port,
                           double samples[LATENCY_SAMPLES]) {
    loopback_server_t server;
    if (server_start(&server, SERVER_ECHO, LATENCY_SAMPLES) != 0) {
        return -1;
    }
    int descriptor = proxy_port == 0 ? connect_loopback(server.port)
                                     : connect_socks5(proxy_port, server.port);
    uint8_t byte = 0xa5U;
    if (descriptor < 0) {
        return -1;
    }
    for (size_t index = 0U; index < LATENCY_SAMPLES; ++index) {
        double started = monotonic_seconds();
        if (send_all(descriptor, &byte, 1U) != 0 ||
            receive_exact(descriptor, &byte, 1U) != 0) {
            return -1;
        }
        samples[index] = (monotonic_seconds() - started) * 1000.0;
    }
    (void)close(descriptor);
    return server_join(&server);
}

static int compare_double(const void *left, const void *right) {
    double a = *(const double *)left;
    double b = *(const double *)right;
    return (a > b) - (a < b);
}

static double median(double values[REPETITIONS]) {
    qsort(values, REPETITIONS, sizeof(values[0]), compare_double);
    return values[REPETITIONS / 2];
}

static double p95(double values[LATENCY_SAMPLES]) {
    qsort(values, LATENCY_SAMPLES, sizeof(values[0]), compare_double);
    return values[((LATENCY_SAMPLES * 95U) + 99U) / 100U - 1U];
}

int main(int argc, char **argv) {
    if (argc != 2 || argv[1][0] != '/') {
        fprintf(stderr, "usage: %s /absolute/runtime/path\n", argv[0]);
        return 64;
    }
    static const char profile[] =
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
        "rules:\n"
        "  - MATCH,DIRECT\n";
    uint16_t socks_port = unused_loopback_port();
    uint16_t http_port = unused_loopback_port();
    if (socks_port < 1024U || http_port < 1024U || socks_port == http_port) {
        fprintf(stderr, "could not reserve PacketFlow loopback ports\n");
        return 1;
    }
    engine_arguments_t arguments = {
        .profile = profile,
        .runtime_path = argv[1],
        .local_proxy = {
            .struct_size = sizeof(clash_packet_local_proxy_v1_t),
            .enabled = 1,
            .http_port = http_port,
            .socks_port = socks_port,
        },
        .result = NULL,
    };
    pthread_t engine_thread;
    if (start_engine(&arguments, &engine_thread) != 0) {
        fprintf(stderr, "could not start PacketFlow performance engine\n");
        return 2;
    }
    uint8_t *payload = malloc(CHUNK_BYTES);
    if (payload == NULL) {
        return 3;
    }
    for (size_t index = 0U; index < CHUNK_BYTES; ++index) {
        payload[index] = (uint8_t)(index * 29U + 11U);
    }

    double direct_seconds[REPETITIONS];
    double packet_seconds[REPETITIONS];
    for (size_t index = 0U; index < REPETITIONS; ++index) {
        if (throughput_once(0, payload, &direct_seconds[index]) != 0 ||
            throughput_once(socks_port, payload, &packet_seconds[index]) != 0) {
            fprintf(stderr, "PacketFlow throughput repetition %zu failed\n", index);
            return 4;
        }
    }
    double direct_latency_ms[LATENCY_SAMPLES];
    double packet_latency_ms[LATENCY_SAMPLES];
    if (latency_samples(0, direct_latency_ms) != 0 ||
        latency_samples(socks_port, packet_latency_ms) != 0) {
        fprintf(stderr, "PacketFlow latency sampling failed\n");
        return 5;
    }

    double direct_median_seconds = median(direct_seconds);
    double packet_median_seconds = median(packet_seconds);
    double mebibytes = (double)PAYLOAD_BYTES / (1024.0 * 1024.0);
    double direct_mibps = mebibytes / direct_median_seconds;
    double packet_mibps = mebibytes / packet_median_seconds;
    double throughput_percent = packet_mibps / direct_mibps * 100.0;
    double direct_p95_ms = p95(direct_latency_ms);
    double packet_p95_ms = p95(packet_latency_ms);
    double added_p95_ms = packet_p95_ms - direct_p95_ms;
    if (added_p95_ms < 0.0) {
        added_p95_ms = 0.0;
    }

    int stopped = stop_engine(&arguments, engine_thread) == 0;
    free(payload);
    printf("packet_tcp_performance repetitions=%d payload_bytes=%d "
           "direct_mibps=%.3f engine_mibps=%.3f ratio_percent=%.3f "
           "direct_p95_ms=%.3f engine_p95_ms=%.3f added_p95_ms=%.3f\n",
           REPETITIONS, PAYLOAD_BYTES, direct_mibps, packet_mibps,
           throughput_percent, direct_p95_ms, packet_p95_ms, added_p95_ms);
    if (!stopped || !isfinite(throughput_percent) ||
        !isfinite(added_p95_ms)) {
        return 6;
    }
    return 0;
}
