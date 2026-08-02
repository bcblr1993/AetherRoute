#include "clashrs.h"

#include <arpa/inet.h>
#include <errno.h>
#include <libproc.h>
#include <pthread.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

_Static_assert(sizeof(clash_flow_engine_options_v1_t) == 20U,
               "flow options v1 ABI changed");
_Static_assert(sizeof(clash_flow_datagram_v1_t) == 32U,
               "arm64 datagram descriptor ABI changed");

enum {
    STAGED_FLOW_CYCLES = 500,
    CALLBACK_TIMEOUT_MS = 5000,
    UDP_PROBE_DATAGRAMS = 3,
    DEFAULT_FD_GROWTH_BUDGET = 4,
};

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

typedef enum server_mode {
    SERVER_ECHO_UNTIL_EOF,
    SERVER_HOLD_OPEN,
} server_mode_t;

typedef struct loopback_server {
    int listener;
    uint16_t port;
    server_mode_t mode;
    pthread_t thread;
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    int accepted;
    int release;
    int error;
} loopback_server_t;

typedef struct udp_echo_server {
    int socket_descriptor;
    uint16_t port;
    pthread_t thread;
    atomic_int received;
    atomic_int sent;
    atomic_int error;
} udp_echo_server_t;

typedef struct callback_state {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    unsigned int count;
    uint64_t token;
    int32_t status;
    int32_t end_of_stream;
    int32_t inline_destroy_status;
    int failed;
    int attempt_inline_destroy;
    clash_flow_t *flow;
    uint8_t copied[128];
    size_t copied_length;
    uint8_t copied_endpoint[64];
    size_t copied_endpoint_length;
    size_t datagram_count;
} callback_state_t;

static struct timespec deadline_after_ms(unsigned int milliseconds) {
    struct timespec deadline;
    (void)clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += (time_t)(milliseconds / 1000U);
    deadline.tv_nsec += (long)(milliseconds % 1000U) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_sec += 1;
        deadline.tv_nsec -= 1000000000L;
    }
    return deadline;
}

static int wait_for_flag(pthread_mutex_t *mutex, pthread_cond_t *condition,
                         const int *flag, unsigned int milliseconds) {
    const struct timespec deadline = deadline_after_ms(milliseconds);
    int result = 0;
    (void)pthread_mutex_lock(mutex);
    while (*flag == 0 && result == 0) {
        result = pthread_cond_timedwait(condition, mutex, &deadline);
    }
    (void)pthread_mutex_unlock(mutex);
    return result;
}

static void *loopback_server_main(void *raw_server) {
    loopback_server_t *server = (loopback_server_t *)raw_server;
    uint8_t received[128];
    size_t received_length = 0U;
    int client = accept(server->listener, NULL, NULL);

    (void)pthread_mutex_lock(&server->mutex);
    if (client < 0) {
        server->error = errno;
    } else {
        server->accepted = 1;
    }
    (void)pthread_cond_broadcast(&server->condition);
    (void)pthread_mutex_unlock(&server->mutex);

    if (client < 0) {
        (void)close(server->listener);
        return NULL;
    }

    if (server->mode == SERVER_ECHO_UNTIL_EOF) {
        for (;;) {
            ssize_t count = recv(client, received + received_length,
                                 sizeof(received) - received_length, 0);
            if (count == 0) {
                break;
            }
            if (count < 0) {
                if (errno == EINTR) {
                    continue;
                }
                server->error = errno;
                break;
            }
            received_length += (size_t)count;
            if (received_length == sizeof(received)) {
                break;
            }
        }
        for (size_t offset = 0U; offset < received_length;) {
            ssize_t count = send(client, received + offset,
                                 received_length - offset, 0);
            if (count < 0 && errno == EINTR) {
                continue;
            }
            if (count <= 0) {
                server->error = errno == 0 ? EIO : errno;
                break;
            }
            offset += (size_t)count;
        }
        (void)shutdown(client, SHUT_WR);
    } else {
        (void)pthread_mutex_lock(&server->mutex);
        while (server->release == 0) {
            (void)pthread_cond_wait(&server->condition, &server->mutex);
        }
        (void)pthread_mutex_unlock(&server->mutex);
    }

    (void)close(client);
    (void)close(server->listener);
    return NULL;
}

static int loopback_server_start(loopback_server_t *server, server_mode_t mode) {
    struct sockaddr_in address;
    socklen_t address_length = (socklen_t)sizeof(address);
    int reuse = 1;

    (void)memset(server, 0, sizeof(*server));
    server->listener = -1;
    server->mode = mode;
    if (pthread_mutex_init(&server->mutex, NULL) != 0 ||
        pthread_cond_init(&server->condition, NULL) != 0) {
        return -1;
    }
    server->listener = socket(AF_INET, SOCK_STREAM, 0);
    if (server->listener < 0) {
        return -1;
    }
    (void)setsockopt(server->listener, SOL_SOCKET, SO_REUSEADDR, &reuse,
                     (socklen_t)sizeof(reuse));
    (void)memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (bind(server->listener, (const struct sockaddr *)&address,
             (socklen_t)sizeof(address)) != 0 ||
        listen(server->listener, 1) != 0 ||
        getsockname(server->listener, (struct sockaddr *)&address,
                    &address_length) != 0) {
        (void)close(server->listener);
        return -1;
    }
    server->port = ntohs(address.sin_port);
    if (pthread_create(&server->thread, NULL, loopback_server_main, server) != 0) {
        (void)close(server->listener);
        return -1;
    }
    return 0;
}

static int loopback_server_wait_accepted(loopback_server_t *server) {
    int result = wait_for_flag(&server->mutex, &server->condition,
                               &server->accepted, CALLBACK_TIMEOUT_MS);
    return result == 0 && server->error == 0 ? 0 : -1;
}

static void loopback_server_release(loopback_server_t *server) {
    (void)pthread_mutex_lock(&server->mutex);
    server->release = 1;
    (void)pthread_cond_broadcast(&server->condition);
    (void)pthread_mutex_unlock(&server->mutex);
}

static int loopback_server_join(loopback_server_t *server) {
    int result = pthread_join(server->thread, NULL);
    int server_error = server->error;
    (void)pthread_cond_destroy(&server->condition);
    (void)pthread_mutex_destroy(&server->mutex);
    return result == 0 && server_error == 0 ? 0 : -1;
}

static void *udp_echo_server_main(void *raw_server) {
    udp_echo_server_t *server = (udp_echo_server_t *)raw_server;
    struct sockaddr_storage peer;
    socklen_t peer_length = (socklen_t)sizeof(peer);
    uint8_t payload[128];
    const struct timespec drain_period = {
        .tv_sec = 0,
        .tv_nsec = 100000000L,
    };
    ssize_t count;

    do {
        count = recvfrom(server->socket_descriptor, payload, sizeof(payload), 0,
                         (struct sockaddr *)&peer, &peer_length);
    } while (count < 0 && errno == EINTR);
    if (count < 0) {
        atomic_store(&server->error, errno);
    } else {
        atomic_store(&server->received, 1);
        for (int index = 0; index < UDP_PROBE_DATAGRAMS; ++index) {
            ssize_t sent;
            do {
                sent = sendto(server->socket_descriptor, payload, (size_t)count,
                              0, (const struct sockaddr *)&peer, peer_length);
            } while (sent < 0 && errno == EINTR);
            if (sent != count) {
                atomic_store(&server->error, sent < 0 ? errno : EIO);
                break;
            }
            atomic_fetch_add(&server->sent, 1);
        }
        /* Keep the loopback server alive briefly after the final send. A UDP
         * send succeeding immediately before close does not guarantee the
         * peer's asynchronous receive task has been scheduled yet. This
         * removes an artificial server-close race without retrying the client
         * operation or relaxing its callback deadline. */
        if (atomic_load(&server->error) == 0) {
            (void)nanosleep(&drain_period, NULL);
        }
    }
    (void)close(server->socket_descriptor);
    return NULL;
}

static int udp_echo_server_start(udp_echo_server_t *server) {
    struct sockaddr_in address;
    socklen_t address_length = (socklen_t)sizeof(address);

    (void)memset(server, 0, sizeof(*server));
    atomic_init(&server->received, 0);
    atomic_init(&server->sent, 0);
    atomic_init(&server->error, 0);
    server->socket_descriptor = socket(AF_INET, SOCK_DGRAM, 0);
    if (server->socket_descriptor < 0) {
        return -1;
    }
    (void)memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (bind(server->socket_descriptor, (const struct sockaddr *)&address,
             (socklen_t)sizeof(address)) != 0 ||
        getsockname(server->socket_descriptor, (struct sockaddr *)&address,
                    &address_length) != 0) {
        (void)close(server->socket_descriptor);
        return -1;
    }
    server->port = ntohs(address.sin_port);
    if (pthread_create(&server->thread, NULL, udp_echo_server_main, server) != 0) {
        (void)close(server->socket_descriptor);
        return -1;
    }
    return 0;
}

static int udp_echo_server_join(udp_echo_server_t *server) {
    return pthread_join(server->thread, NULL) == 0 &&
                   atomic_load(&server->error) == 0
               ? 0
               : -1;
}

static void report_udp_server(const udp_echo_server_t *server) {
    fprintf(stderr, "UDP echo server: received=%d sent=%d error=%d\n",
            atomic_load(&server->received), atomic_load(&server->sent),
            atomic_load(&server->error));
}

static void callback_state_init(callback_state_t *state, clash_flow_t *flow,
                                int attempt_inline_destroy) {
    (void)memset(state, 0, sizeof(*state));
    state->flow = flow;
    state->attempt_inline_destroy = attempt_inline_destroy;
    state->inline_destroy_status = -1;
    (void)pthread_mutex_init(&state->mutex, NULL);
    (void)pthread_cond_init(&state->condition, NULL);
}

static void callback_state_destroy(callback_state_t *state) {
    (void)pthread_cond_destroy(&state->condition);
    (void)pthread_mutex_destroy(&state->mutex);
}

static int callback_state_wait(callback_state_t *state, unsigned int count,
                               unsigned int milliseconds) {
    const struct timespec deadline = deadline_after_ms(milliseconds);
    int result = 0;
    (void)pthread_mutex_lock(&state->mutex);
    while (state->count < count && result == 0) {
        result = pthread_cond_timedwait(&state->condition, &state->mutex,
                                        &deadline);
    }
    (void)pthread_mutex_unlock(&state->mutex);
    return result;
}

static int callback_state_count(callback_state_t *state) {
    int count;
    (void)pthread_mutex_lock(&state->mutex);
    count = (int)state->count;
    (void)pthread_mutex_unlock(&state->mutex);
    return count;
}

static int completion_state_matches(callback_state_t *state, uint64_t token) {
    int matches;
    (void)pthread_mutex_lock(&state->mutex);
    matches = state->failed == 0 && state->count == 1U &&
              state->token == token && state->status == CLASH_FLOW_OK;
    (void)pthread_mutex_unlock(&state->mutex);
    return matches;
}

static int udp_read_state_matches(callback_state_t *state, uint64_t token,
                                  const uint8_t *payload,
                                  size_t payload_length,
                                  const uint8_t *endpoint,
                                  size_t endpoint_length) {
    int matches;
    (void)pthread_mutex_lock(&state->mutex);
    matches = state->failed == 0 && state->count == 1U &&
              state->token == token && state->status == CLASH_FLOW_OK &&
              state->end_of_stream == 0 && state->datagram_count == 1U &&
              state->copied_length == payload_length &&
              memcmp(state->copied, payload, payload_length) == 0 &&
              state->copied_endpoint_length == endpoint_length &&
              memcmp(state->copied_endpoint, endpoint, endpoint_length) == 0;
    (void)pthread_mutex_unlock(&state->mutex);
    return matches;
}

static void report_callback_state(const char *name, callback_state_t *state,
                                  int wait_status) {
    (void)pthread_mutex_lock(&state->mutex);
    fprintf(stderr,
            "%s: wait=%d failed=%d count=%u token=%llu status=%d "
            "eof=%d datagrams=%zu payload=%zu endpoint=%zu\n",
            name, wait_status, state->failed, state->count,
            (unsigned long long)state->token, state->status,
            state->end_of_stream, state->datagram_count,
            state->copied_length, state->copied_endpoint_length);
    (void)pthread_mutex_unlock(&state->mutex);
}

static void callback_record(callback_state_t *state, uint64_t token,
                            int32_t status) {
    (void)pthread_mutex_lock(&state->mutex);
    if (state->count != 0U) {
        state->failed = 1;
    }
    state->count += 1U;
    state->token = token;
    state->status = status;
    (void)pthread_cond_broadcast(&state->condition);
    (void)pthread_mutex_unlock(&state->mutex);
}

static void completion_callback(uint64_t token, int32_t status, void *context) {
    callback_record((callback_state_t *)context, token, status);
}

static void tcp_read_callback(uint64_t token, int32_t status,
                              const uint8_t *data, size_t data_length,
                              int32_t end_of_stream, void *context) {
    callback_state_t *state = (callback_state_t *)context;
    int32_t inline_destroy_status = -1;
    int invalid_buffer = data_length > sizeof(state->copied) ||
                         (data_length != 0U && data == NULL);

    if (state->attempt_inline_destroy != 0) {
        inline_destroy_status = clash_flow_destroy(state->flow);
    }
    (void)pthread_mutex_lock(&state->mutex);
    if (state->count != 0U || invalid_buffer != 0) {
        state->failed = 1;
    }
    if (invalid_buffer == 0 && data_length != 0U) {
        (void)memcpy(state->copied, data, data_length);
        state->copied_length = data_length;
    }
    state->count += 1U;
    state->token = token;
    state->status = status;
    state->end_of_stream = end_of_stream;
    state->inline_destroy_status = inline_destroy_status;
    (void)pthread_cond_broadcast(&state->condition);
    (void)pthread_mutex_unlock(&state->mutex);
}

static void udp_read_callback(uint64_t token, int32_t status,
                              const clash_flow_datagram_v1_t *datagrams,
                              size_t datagram_count, int32_t end_of_stream,
                              void *context) {
    callback_state_t *state = (callback_state_t *)context;
    int invalid = datagram_count > 1U ||
                  (datagram_count != 0U && datagrams == NULL);

    (void)pthread_mutex_lock(&state->mutex);
    if (state->count != 0U || invalid != 0) {
        state->failed = 1;
    }
    if (invalid == 0 && datagram_count == 1U) {
        const clash_flow_datagram_v1_t *datagram = &datagrams[0];
        if (datagram->payload_length > sizeof(state->copied) ||
            datagram->remote_endpoint_length > sizeof(state->copied_endpoint) ||
            (datagram->payload_length != 0U && datagram->payload == NULL) ||
            (datagram->remote_endpoint_length != 0U &&
             datagram->remote_endpoint == NULL)) {
            state->failed = 1;
        } else {
            (void)memcpy(state->copied, datagram->payload,
                         datagram->payload_length);
            state->copied_length = datagram->payload_length;
            (void)memcpy(state->copied_endpoint, datagram->remote_endpoint,
                         datagram->remote_endpoint_length);
            state->copied_endpoint_length = datagram->remote_endpoint_length;
        }
    }
    state->count += 1U;
    state->token = token;
    state->status = status;
    state->end_of_stream = end_of_stream;
    state->datagram_count = datagram_count;
    (void)pthread_cond_broadcast(&state->condition);
    (void)pthread_mutex_unlock(&state->mutex);
}

static int create_engine(const char *directory, clash_flow_engine_t **engine) {
    static const uint8_t profile[] =
        "mode: direct\n"
        "proxies: []\n"
        "rules: []\n";
    const clash_flow_engine_options_v1_t options = {
        .struct_size = (uint32_t)sizeof(clash_flow_engine_options_v1_t),
        .worker_threads = 2,
        .queue_depth = 32,
        .maximum_tcp_chunk_bytes = 64U * 1024U,
        .maximum_udp_payload_bytes = 65507U,
    };
    return clash_flow_engine_create(profile, sizeof(profile) - 1U,
                                    (const uint8_t *)directory,
                                    strlen(directory), &options, engine);
}

static int create_tcp_flow(clash_flow_engine_t *engine, uint16_t port,
                           clash_flow_t **flow) {
    uint8_t destination[] = {
        1, 1, 1, 0, 0,
        0, 0, 0, 0,
        0, 4,
        127, 0, 0, 1,
    };
    destination[3] = (uint8_t)(port >> 8U);
    destination[4] = (uint8_t)(port & 0xffU);
    return clash_flow_tcp_create(engine, NULL, 0U, destination,
                                 sizeof(destination), flow);
}

static void make_ipv4_endpoint(uint8_t endpoint[15], uint8_t transport,
                               uint16_t port) {
    static const uint8_t prefix[] = {1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 4,
                                     127, 0, 0, 1};
    (void)memcpy(endpoint, prefix, sizeof(prefix));
    endpoint[1] = transport;
    endpoint[3] = (uint8_t)(port >> 8U);
    endpoint[4] = (uint8_t)(port & 0xffU);
}

static int create_udp_flow(clash_flow_engine_t *engine, clash_flow_t **flow) {
    uint8_t source[15];
    make_ipv4_endpoint(source, 2U, 49152U);
    return clash_flow_udp_create(engine, source, sizeof(source), flow);
}

static int require_status(const char *operation, int32_t actual,
                          int32_t expected) {
    if (actual == expected) {
        return 0;
    }
    fprintf(stderr, "%s: expected %s, got %s\n", operation,
            clash_flow_status_message(expected),
            clash_flow_status_message(actual));
    return -1;
}

/*
 * This release harness links the real arm64 static library. It creates two
 * independent flow-only engines, performs 500 staged flow lifecycles, then
 * exercises callbacks through process-local 127.0.0.1 sockets only. It never
 * installs a TUN, listener owned by Clash, route, DNS, or system proxy.
 */
int main(int argc, char **argv) {
    static const uint8_t request[] = "aetherroute-flow-abi";
    clash_flow_engine_t *first = NULL;
    clash_flow_engine_t *second = NULL;
    clash_flow_t *flow = NULL;
    loopback_server_t server;
    callback_state_t write_state;
    callback_state_t finish_state;
    callback_state_t read_state;
    udp_echo_server_t udp_server;
    clash_flow_datagram_v1_t datagrams[UDP_PROBE_DATAGRAMS];
    uint8_t udp_destination[15];
    struct timespec quiet_period = {.tv_sec = 0, .tv_nsec = 100000000L};
    int32_t status;
    int fd_growth_budget = file_descriptor_growth_budget();
    int baseline_fd_count = open_file_descriptor_count();
    int warmed_fd_count = -1;

    if (argc != 2 || argv[1][0] != '/') {
        fprintf(stderr, "usage: %s /absolute/temporary/directory\n", argv[0]);
        return 64;
    }
    if (fd_growth_budget < 0 || baseline_fd_count < 0) {
        fprintf(stderr, "could not establish the file-descriptor baseline\n");
        return 64;
    }
    if (require_status("first engine create", create_engine(argv[1], &first),
                       CLASH_FLOW_OK) != 0 || first == NULL ||
        require_status("second engine create", create_engine(argv[1], &second),
                       CLASH_FLOW_OK) != 0 || second == NULL) {
        return 1;
    }

    for (unsigned int index = 0U; index < STAGED_FLOW_CYCLES; ++index) {
        clash_flow_engine_t *engine = (index & 1U) == 0U ? first : second;
        flow = NULL;
        status = create_tcp_flow(engine, 9U, &flow);
        if (status != CLASH_FLOW_OK || flow == NULL ||
            clash_flow_destroy(flow) != CLASH_FLOW_OK) {
            fprintf(stderr, "staged lifecycle failed at %u\n", index);
            return 2;
        }
        if (index == 0U) {
            warmed_fd_count = open_file_descriptor_count();
            if (warmed_fd_count < 0) {
                fprintf(stderr, "could not sample warmed file descriptors\n");
                return 22;
            }
        }
    }
    int staged_fd_count = open_file_descriptor_count();
    if (staged_fd_count < 0 ||
        staged_fd_count - warmed_fd_count > fd_growth_budget) {
        fprintf(stderr,
                "staged file-descriptor growth exceeded budget: "
                "warmed=%d final=%d budget=%d\n",
                warmed_fd_count, staged_fd_count, fd_growth_budget);
        return 22;
    }

    if (require_status("first engine destroy", clash_flow_engine_destroy(first),
                       CLASH_FLOW_OK) != 0) {
        return 3;
    }
    first = NULL;
    flow = NULL;
    if (require_status("surviving engine flow create",
                       create_tcp_flow(second, 9U, &flow), CLASH_FLOW_OK) != 0 ||
        flow == NULL ||
        require_status("surviving engine flow destroy", clash_flow_destroy(flow),
                       CLASH_FLOW_OK) != 0) {
        return 4;
    }

    if (loopback_server_start(&server, SERVER_ECHO_UNTIL_EOF) != 0) {
        fprintf(stderr, "could not start isolated echo server\n");
        return 5;
    }
    flow = NULL;
    if (require_status("echo flow create",
                       create_tcp_flow(second, server.port, &flow),
                       CLASH_FLOW_OK) != 0 || flow == NULL ||
        require_status("echo flow activate", clash_flow_activate(flow),
                       CLASH_FLOW_OK) != 0 ||
        loopback_server_wait_accepted(&server) != 0) {
        return 6;
    }

    callback_state_init(&write_state, flow, 0);
    status = clash_flow_tcp_write(flow, request, sizeof(request) - 1U, 100U,
                                  completion_callback, &write_state);
    if (require_status("TCP write admission", status, CLASH_FLOW_OK) != 0 ||
        callback_state_wait(&write_state, 1U, CALLBACK_TIMEOUT_MS) != 0 ||
        write_state.failed != 0 || write_state.count != 1U ||
        write_state.token != 100U || write_state.status != CLASH_FLOW_OK) {
        return 7;
    }
    callback_state_destroy(&write_state);

    callback_state_init(&finish_state, flow, 0);
    status = clash_flow_tcp_finish_write(flow, 101U, completion_callback,
                                         &finish_state);
    if (require_status("TCP finish admission", status, CLASH_FLOW_OK) != 0 ||
        callback_state_wait(&finish_state, 1U, CALLBACK_TIMEOUT_MS) != 0 ||
        finish_state.failed != 0 || finish_state.count != 1U ||
        finish_state.token != 101U || finish_state.status != CLASH_FLOW_OK) {
        return 8;
    }
    callback_state_destroy(&finish_state);

    callback_state_init(&read_state, flow, 1);
    status = clash_flow_tcp_read(flow, sizeof(read_state.copied), 102U,
                                 tcp_read_callback, &read_state);
    if (require_status("TCP read admission", status, CLASH_FLOW_OK) != 0 ||
        callback_state_wait(&read_state, 1U, CALLBACK_TIMEOUT_MS) != 0 ||
        read_state.failed != 0 || read_state.count != 1U ||
        read_state.token != 102U || read_state.status != CLASH_FLOW_OK ||
        read_state.end_of_stream != 0 ||
        read_state.inline_destroy_status != CLASH_FLOW_INVALID_STATE ||
        read_state.copied_length != sizeof(request) - 1U ||
        memcmp(read_state.copied, request, sizeof(request) - 1U) != 0) {
        return 9;
    }
    (void)nanosleep(&quiet_period, NULL);
    if (callback_state_count(&read_state) != 1) {
        fprintf(stderr, "TCP read callback was not exactly once\n");
        return 10;
    }
    callback_state_destroy(&read_state);
    if (require_status("echo flow destroy", clash_flow_destroy(flow),
                       CLASH_FLOW_OK) != 0 ||
        loopback_server_join(&server) != 0) {
        return 11;
    }

    if (udp_echo_server_start(&udp_server) != 0) {
        fprintf(stderr, "could not start isolated UDP echo server\n");
        return 12;
    }
    flow = NULL;
    if (require_status("UDP flow create", create_udp_flow(second, &flow),
                       CLASH_FLOW_OK) != 0 || flow == NULL ||
        require_status("UDP flow activate", clash_flow_activate(flow),
                       CLASH_FLOW_OK) != 0) {
        return 13;
    }
    make_ipv4_endpoint(udp_destination, 2U, udp_server.port);
    for (int index = 0; index < UDP_PROBE_DATAGRAMS; ++index) {
        datagrams[index].payload = request;
        datagrams[index].payload_length = sizeof(request) - 1U;
        datagrams[index].remote_endpoint = udp_destination;
        datagrams[index].remote_endpoint_length = sizeof(udp_destination);
    }
    callback_state_init(&read_state, flow, 0);
    status = clash_flow_udp_read(flow, 1U, sizeof(read_state.copied), 300U,
                                 udp_read_callback, &read_state);
    if (require_status("UDP read admission", status, CLASH_FLOW_OK) != 0) {
        return 14;
    }
    callback_state_init(&write_state, flow, 0);
    /* UDP is intentionally best-effort. A three-datagram loopback probe keeps
     * a long stability gate focused on a stuck data path rather than treating
     * one isolated kernel datagram loss as a deterministic core failure. */
    status = clash_flow_udp_write(flow, datagrams, UDP_PROBE_DATAGRAMS, 301U,
                                  completion_callback, &write_state);
    int write_wait = callback_state_wait(&write_state, 1U, CALLBACK_TIMEOUT_MS);
    if (require_status("UDP write admission", status, CLASH_FLOW_OK) != 0 ||
        write_wait != 0 || !completion_state_matches(&write_state, 301U)) {
        report_callback_state("UDP write completion", &write_state, write_wait);
        report_callback_state("UDP read completion", &read_state, 0);
        report_udp_server(&udp_server);
        return 15;
    }
    int read_wait = callback_state_wait(&read_state, 1U, CALLBACK_TIMEOUT_MS);
    if (read_wait != 0 ||
        !udp_read_state_matches(&read_state, 300U, request,
                                sizeof(request) - 1U, udp_destination,
                                sizeof(udp_destination))) {
        report_callback_state("UDP write completion", &write_state, write_wait);
        report_callback_state("UDP read completion", &read_state, read_wait);
        report_udp_server(&udp_server);
        return 15;
    }
    callback_state_destroy(&write_state);
    callback_state_destroy(&read_state);
    if (udp_echo_server_join(&udp_server) != 0 ||
        require_status("UDP flow cancel", clash_flow_cancel(flow),
                       CLASH_FLOW_OK) != 0 ||
        require_status("UDP flow destroy", clash_flow_destroy(flow),
                       CLASH_FLOW_OK) != 0) {
        return 16;
    }

    if (loopback_server_start(&server, SERVER_HOLD_OPEN) != 0) {
        fprintf(stderr, "could not start isolated hold-open server\n");
        return 17;
    }
    flow = NULL;
    if (require_status("cancel flow create",
                       create_tcp_flow(second, server.port, &flow),
                       CLASH_FLOW_OK) != 0 || flow == NULL ||
        require_status("cancel flow activate", clash_flow_activate(flow),
                       CLASH_FLOW_OK) != 0 ||
        loopback_server_wait_accepted(&server) != 0) {
        return 18;
    }
    callback_state_init(&read_state, flow, 0);
    status = clash_flow_tcp_read(flow, sizeof(read_state.copied), 200U,
                                 tcp_read_callback, &read_state);
    if (require_status("first pending read", status, CLASH_FLOW_OK) != 0 ||
        require_status("second pending read",
                       clash_flow_tcp_read(flow, sizeof(read_state.copied), 201U,
                                           tcp_read_callback, &read_state),
                       CLASH_FLOW_BACKPRESSURE) != 0 ||
        require_status("first cancel", clash_flow_cancel(flow), CLASH_FLOW_OK) !=
            0 ||
        require_status("second cancel", clash_flow_cancel(flow), CLASH_FLOW_OK) !=
            0 ||
        callback_state_wait(&read_state, 1U, CALLBACK_TIMEOUT_MS) != 0 ||
        read_state.failed != 0 || read_state.count != 1U ||
        read_state.token != 200U || read_state.status != CLASH_FLOW_CANCELLED) {
        return 19;
    }
    (void)nanosleep(&quiet_period, NULL);
    if (callback_state_count(&read_state) != 1) {
        fprintf(stderr, "cancelled callback was not exactly once\n");
        return 20;
    }
    callback_state_destroy(&read_state);
    loopback_server_release(&server);
    if (loopback_server_join(&server) != 0 ||
        require_status("cancel flow destroy", clash_flow_destroy(flow),
                       CLASH_FLOW_OK) != 0 ||
        require_status("second engine destroy", clash_flow_engine_destroy(second),
                       CLASH_FLOW_OK) != 0) {
        return 21;
    }

    int final_fd_count = open_file_descriptor_count();
    int fd_growth = final_fd_count - baseline_fd_count;
    if (final_fd_count < 0 || fd_growth > fd_growth_budget) {
        fprintf(stderr,
                "final file-descriptor growth exceeded budget: "
                "baseline=%d final=%d budget=%d\n",
                baseline_fd_count, final_fd_count, fd_growth_budget);
        return 23;
    }
    printf("flow_cycles=%u engines=2 active_loopback_flows=3 callbacks=6 "
           "fd_baseline=%d fd_final=%d fd_growth=%d fd_growth_budget=%d\n",
           STAGED_FLOW_CYCLES, baseline_fd_count, final_fd_count, fd_growth,
           fd_growth_budget);
    return 0;
}
