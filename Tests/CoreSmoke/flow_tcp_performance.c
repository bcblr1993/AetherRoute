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
    CALLBACK_TIMEOUT_SECONDS = 10,
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

typedef struct callback_state {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    int completed;
    int32_t status;
    size_t data_length;
    int32_t end_of_stream;
    uint8_t byte;
} callback_state_t;

static double monotonic_seconds(void) {
    struct timespec value;
    (void)clock_gettime(CLOCK_MONOTONIC, &value);
    return (double)value.tv_sec + (double)value.tv_nsec / 1000000000.0;
}

static int configure_socket(int descriptor) {
    struct timeval timeout = {.tv_sec = CALLBACK_TIMEOUT_SECONDS, .tv_usec = 0};
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

static int callback_state_init(callback_state_t *state) {
    (void)memset(state, 0, sizeof(*state));
    return pthread_mutex_init(&state->mutex, NULL) == 0 &&
                   pthread_cond_init(&state->condition, NULL) == 0
               ? 0
               : -1;
}

static void callback_state_reset(callback_state_t *state) {
    (void)pthread_mutex_lock(&state->mutex);
    state->completed = 0;
    state->status = CLASH_FLOW_INTERNAL_ERROR;
    state->data_length = 0U;
    state->end_of_stream = 0;
    state->byte = 0U;
    (void)pthread_mutex_unlock(&state->mutex);
}

static void completion_callback(uint64_t token, int32_t status, void *context) {
    (void)token;
    callback_state_t *state = (callback_state_t *)context;
    (void)pthread_mutex_lock(&state->mutex);
    state->status = status;
    state->completed = 1;
    (void)pthread_cond_broadcast(&state->condition);
    (void)pthread_mutex_unlock(&state->mutex);
}

static void read_callback(uint64_t token, int32_t status, const uint8_t *data,
                          size_t data_length, int32_t end_of_stream,
                          void *context) {
    (void)token;
    callback_state_t *state = (callback_state_t *)context;
    (void)pthread_mutex_lock(&state->mutex);
    state->status = status;
    state->data_length = data_length;
    state->end_of_stream = end_of_stream;
    if (data != NULL && data_length > 0U) {
        state->byte = data[0];
    }
    state->completed = 1;
    (void)pthread_cond_broadcast(&state->condition);
    (void)pthread_mutex_unlock(&state->mutex);
}

static int callback_state_wait(callback_state_t *state) {
    struct timespec deadline;
    (void)clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += CALLBACK_TIMEOUT_SECONDS;
    int result = 0;
    (void)pthread_mutex_lock(&state->mutex);
    while (!state->completed && result == 0) {
        result = pthread_cond_timedwait(&state->condition, &state->mutex,
                                        &deadline);
    }
    int valid = result == 0 && state->completed && state->status == CLASH_FLOW_OK;
    (void)pthread_mutex_unlock(&state->mutex);
    return valid ? 0 : -1;
}

static void callback_state_destroy(callback_state_t *state) {
    (void)pthread_cond_destroy(&state->condition);
    (void)pthread_mutex_destroy(&state->mutex);
}

static int create_engine(const char *runtime_path,
                         clash_flow_engine_t **engine) {
    static const uint8_t profile[] =
        "mode: direct\n"
        "proxies: []\n"
        "rules:\n"
        "  - MATCH,DIRECT\n";
    const clash_flow_engine_options_v1_t options = {
        .struct_size = (uint32_t)sizeof(options),
        .worker_threads = 2,
        .queue_depth = 64,
        .maximum_tcp_chunk_bytes = CHUNK_BYTES,
        .maximum_udp_payload_bytes = 65507U,
    };
    return clash_flow_engine_create(profile, sizeof(profile) - 1U,
                                    (const uint8_t *)runtime_path,
                                    strlen(runtime_path), &options, engine);
}

static int create_flow(clash_flow_engine_t *engine, uint16_t port,
                       clash_flow_t **flow) {
    uint8_t endpoint[] = {1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 4, 127, 0, 0, 1};
    endpoint[3] = (uint8_t)(port >> 8U);
    endpoint[4] = (uint8_t)port;
    return clash_flow_tcp_create(engine, NULL, 0U, endpoint, sizeof(endpoint),
                                 flow);
}

static int direct_throughput_once(const uint8_t *payload, double *seconds) {
    loopback_server_t server;
    if (server_start(&server, SERVER_SINK, PAYLOAD_BYTES) != 0) {
        return -1;
    }
    int descriptor = connect_loopback(server.port);
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

static int flow_throughput_once(clash_flow_engine_t *engine,
                                const uint8_t *payload, double *seconds) {
    loopback_server_t server;
    clash_flow_t *flow = NULL;
    callback_state_t state;
    if (server_start(&server, SERVER_SINK, PAYLOAD_BYTES) != 0 ||
        create_flow(engine, server.port, &flow) != CLASH_FLOW_OK || flow == NULL ||
        clash_flow_activate(flow) != CLASH_FLOW_OK ||
        callback_state_init(&state) != 0) {
        return -1;
    }
    double started = monotonic_seconds();
    for (size_t offset = 0U; offset < PAYLOAD_BYTES; offset += CHUNK_BYTES) {
        callback_state_reset(&state);
        if (clash_flow_tcp_write(flow, payload, CHUNK_BYTES, offset + 1U,
                                 completion_callback, &state) != CLASH_FLOW_OK ||
            callback_state_wait(&state) != 0) {
            return -1;
        }
    }
    callback_state_reset(&state);
    if (clash_flow_tcp_finish_write(flow, PAYLOAD_BYTES + 1U,
                                    completion_callback, &state) !=
            CLASH_FLOW_OK ||
        callback_state_wait(&state) != 0 || server_join(&server) != 0) {
        return -1;
    }
    *seconds = monotonic_seconds() - started;
    callback_state_destroy(&state);
    return clash_flow_destroy(flow) == CLASH_FLOW_OK ? 0 : -1;
}

static int direct_latency(double samples[LATENCY_SAMPLES]) {
    loopback_server_t server;
    if (server_start(&server, SERVER_ECHO, LATENCY_SAMPLES) != 0) {
        return -1;
    }
    int descriptor = connect_loopback(server.port);
    uint8_t byte = 0x5aU;
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

static int flow_latency(clash_flow_engine_t *engine,
                        double samples[LATENCY_SAMPLES]) {
    loopback_server_t server;
    clash_flow_t *flow = NULL;
    callback_state_t state;
    uint8_t byte = 0x5aU;
    if (server_start(&server, SERVER_ECHO, LATENCY_SAMPLES) != 0 ||
        create_flow(engine, server.port, &flow) != CLASH_FLOW_OK || flow == NULL ||
        clash_flow_activate(flow) != CLASH_FLOW_OK ||
        callback_state_init(&state) != 0) {
        return -1;
    }
    for (size_t index = 0U; index < LATENCY_SAMPLES; ++index) {
        double started = monotonic_seconds();
        callback_state_reset(&state);
        if (clash_flow_tcp_write(flow, &byte, 1U, index * 2U,
                                 completion_callback, &state) != CLASH_FLOW_OK ||
            callback_state_wait(&state) != 0) {
            return -1;
        }
        callback_state_reset(&state);
        if (clash_flow_tcp_read(flow, 1U, index * 2U + 1U, read_callback,
                                &state) != CLASH_FLOW_OK ||
            callback_state_wait(&state) != 0 || state.data_length != 1U ||
            state.byte != byte || state.end_of_stream != 0) {
            return -1;
        }
        samples[index] = (monotonic_seconds() - started) * 1000.0;
    }
    callback_state_destroy(&state);
    if (clash_flow_destroy(flow) != CLASH_FLOW_OK || server_join(&server) != 0) {
        return -1;
    }
    return 0;
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
    uint8_t *payload = malloc(CHUNK_BYTES);
    clash_flow_engine_t *engine = NULL;
    if (payload == NULL || create_engine(argv[1], &engine) != CLASH_FLOW_OK ||
        engine == NULL) {
        fprintf(stderr, "could not create FlowOnly performance engine\n");
        return 1;
    }
    for (size_t index = 0U; index < CHUNK_BYTES; ++index) {
        payload[index] = (uint8_t)(index * 31U + 7U);
    }

    double direct_seconds[REPETITIONS];
    double flow_seconds[REPETITIONS];
    for (size_t index = 0U; index < REPETITIONS; ++index) {
        if (direct_throughput_once(payload, &direct_seconds[index]) != 0 ||
            flow_throughput_once(engine, payload, &flow_seconds[index]) != 0) {
            fprintf(stderr, "FlowOnly throughput repetition %zu failed\n", index);
            return 2;
        }
    }
    double direct_latency_ms[LATENCY_SAMPLES];
    double flow_latency_ms[LATENCY_SAMPLES];
    if (direct_latency(direct_latency_ms) != 0 ||
        flow_latency(engine, flow_latency_ms) != 0) {
        fprintf(stderr, "FlowOnly latency sampling failed\n");
        return 3;
    }

    double direct_median_seconds = median(direct_seconds);
    double flow_median_seconds = median(flow_seconds);
    double mebibytes = (double)PAYLOAD_BYTES / (1024.0 * 1024.0);
    double direct_mibps = mebibytes / direct_median_seconds;
    double flow_mibps = mebibytes / flow_median_seconds;
    double throughput_percent = flow_mibps / direct_mibps * 100.0;
    double direct_p95_ms = p95(direct_latency_ms);
    double flow_p95_ms = p95(flow_latency_ms);
    double added_p95_ms = flow_p95_ms - direct_p95_ms;
    if (added_p95_ms < 0.0) {
        added_p95_ms = 0.0;
    }

    int destroyed = clash_flow_engine_destroy(engine) == CLASH_FLOW_OK;
    free(payload);
    printf("flow_tcp_performance repetitions=%d payload_bytes=%d "
           "direct_mibps=%.3f engine_mibps=%.3f ratio_percent=%.3f "
           "direct_p95_ms=%.3f engine_p95_ms=%.3f added_p95_ms=%.3f\n",
           REPETITIONS, PAYLOAD_BYTES, direct_mibps, flow_mibps,
           throughput_percent, direct_p95_ms, flow_p95_ms, added_p95_ms);
    if (!destroyed || !isfinite(throughput_percent) ||
        !isfinite(added_p95_ms)) {
        return 4;
    }
    return 0;
}
