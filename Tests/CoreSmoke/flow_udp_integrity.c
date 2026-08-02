#include "clashrs.h"

#include <arpa/inet.h>
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

enum {
    TEST_DATAGRAMS = 10000,
    WARMUP_DATAGRAMS = 32,
    CALLBACK_TIMEOUT_MS = 5000,
    PAYLOAD_BYTES = 12,
};

typedef struct udp_echo_server {
    int descriptor;
    uint16_t port;
    pthread_t thread;
    int expected;
    int received;
    int sent;
    int error;
} udp_echo_server_t;

typedef struct operation_state {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    int read_done;
    int write_done;
    int duplicate_callback;
    int32_t read_status;
    int32_t write_status;
    uint64_t read_token;
    uint64_t write_token;
    size_t datagram_count;
    uint8_t payload[PAYLOAD_BYTES];
    size_t payload_length;
} operation_state_t;

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

static void write_be32(uint8_t *bytes, uint32_t value) {
    bytes[0] = (uint8_t)(value >> 24U);
    bytes[1] = (uint8_t)(value >> 16U);
    bytes[2] = (uint8_t)(value >> 8U);
    bytes[3] = (uint8_t)value;
}

static uint32_t read_be32(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24U) |
           ((uint32_t)bytes[1] << 16U) |
           ((uint32_t)bytes[2] << 8U) | (uint32_t)bytes[3];
}

static void make_payload(uint8_t payload[PAYLOAD_BYTES], uint32_t sequence) {
    (void)memcpy(payload, "ARUD", 4U);
    write_be32(payload + 4U, sequence);
    write_be32(payload + 8U, sequence ^ 0xA37E5C19U);
}

static int validate_payload(const uint8_t *payload, size_t length,
                            uint32_t expected) {
    return length == PAYLOAD_BYTES && memcmp(payload, "ARUD", 4U) == 0 &&
           read_be32(payload + 4U) == expected &&
           read_be32(payload + 8U) == (expected ^ 0xA37E5C19U);
}

static void *udp_echo_server_main(void *raw_server) {
    udp_echo_server_t *server = (udp_echo_server_t *)raw_server;
    struct timeval timeout = {.tv_sec = 10, .tv_usec = 0};
    (void)setsockopt(server->descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                     (socklen_t)sizeof(timeout));

    while (server->received < server->expected) {
        struct sockaddr_storage peer;
        socklen_t peer_length = (socklen_t)sizeof(peer);
        uint8_t payload[PAYLOAD_BYTES];
        ssize_t count;
        do {
            count = recvfrom(server->descriptor, payload, sizeof(payload), 0,
                             (struct sockaddr *)&peer, &peer_length);
        } while (count < 0 && errno == EINTR);
        if (count != PAYLOAD_BYTES) {
            server->error = count < 0 ? errno : EMSGSIZE;
            break;
        }
        server->received += 1;

        ssize_t sent;
        do {
            sent = sendto(server->descriptor, payload, (size_t)count, 0,
                          (const struct sockaddr *)&peer, peer_length);
        } while (sent < 0 && errno == EINTR);
        if (sent != count) {
            server->error = sent < 0 ? errno : EIO;
            break;
        }
        server->sent += 1;
    }
    (void)close(server->descriptor);
    return NULL;
}

static int udp_echo_server_start(udp_echo_server_t *server, int expected) {
    struct sockaddr_in address;
    socklen_t address_length = (socklen_t)sizeof(address);
    (void)memset(server, 0, sizeof(*server));
    server->descriptor = socket(AF_INET, SOCK_DGRAM, 0);
    server->expected = expected;
    if (server->descriptor < 0) {
        return -1;
    }
    (void)memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (bind(server->descriptor, (const struct sockaddr *)&address,
             (socklen_t)sizeof(address)) != 0 ||
        getsockname(server->descriptor, (struct sockaddr *)&address,
                    &address_length) != 0) {
        (void)close(server->descriptor);
        return -1;
    }
    server->port = ntohs(address.sin_port);
    if (pthread_create(&server->thread, NULL, udp_echo_server_main, server) != 0) {
        (void)close(server->descriptor);
        return -1;
    }
    return 0;
}

static void operation_state_init(operation_state_t *state) {
    (void)memset(state, 0, sizeof(*state));
    (void)pthread_mutex_init(&state->mutex, NULL);
    (void)pthread_cond_init(&state->condition, NULL);
}

static void operation_state_reset(operation_state_t *state) {
    (void)pthread_mutex_lock(&state->mutex);
    state->read_done = 0;
    state->write_done = 0;
    state->duplicate_callback = 0;
    state->read_status = -1;
    state->write_status = -1;
    state->read_token = 0U;
    state->write_token = 0U;
    state->datagram_count = 0U;
    state->payload_length = 0U;
    (void)pthread_mutex_unlock(&state->mutex);
}

static int operation_state_wait(operation_state_t *state, int require_write,
                                unsigned int milliseconds) {
    const struct timespec deadline = deadline_after_ms(milliseconds);
    int status = 0;
    (void)pthread_mutex_lock(&state->mutex);
    while ((!state->read_done || (require_write && !state->write_done)) &&
           status == 0) {
        status = pthread_cond_timedwait(&state->condition, &state->mutex,
                                        &deadline);
    }
    (void)pthread_mutex_unlock(&state->mutex);
    return status;
}

static void completion_callback(uint64_t token, int32_t status, void *context) {
    operation_state_t *state = (operation_state_t *)context;
    (void)pthread_mutex_lock(&state->mutex);
    if (state->write_done) {
        state->duplicate_callback = 1;
    }
    state->write_done = 1;
    state->write_token = token;
    state->write_status = status;
    (void)pthread_cond_broadcast(&state->condition);
    (void)pthread_mutex_unlock(&state->mutex);
}

static void read_callback(uint64_t token, int32_t status,
                          const clash_flow_datagram_v1_t *datagrams,
                          size_t datagram_count, int32_t end_of_stream,
                          void *context) {
    operation_state_t *state = (operation_state_t *)context;
    (void)pthread_mutex_lock(&state->mutex);
    if (state->read_done) {
        state->duplicate_callback = 1;
    }
    state->read_done = 1;
    state->read_token = token;
    state->read_status = status;
    state->datagram_count = datagram_count;
    if (end_of_stream != 0 || datagram_count > 1U ||
        (datagram_count == 1U && datagrams == NULL)) {
        state->duplicate_callback = 1;
    } else if (datagram_count == 1U) {
        const clash_flow_datagram_v1_t *datagram = &datagrams[0];
        if (datagram->payload == NULL ||
            datagram->payload_length > sizeof(state->payload)) {
            state->duplicate_callback = 1;
        } else {
            (void)memcpy(state->payload, datagram->payload,
                         datagram->payload_length);
            state->payload_length = datagram->payload_length;
        }
    }
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
        .queue_depth = 64,
        .maximum_tcp_chunk_bytes = 64U * 1024U,
        .maximum_udp_payload_bytes = 65507U,
    };
    return clash_flow_engine_create(profile, sizeof(profile) - 1U,
                                    (const uint8_t *)directory,
                                    strlen(directory), &options, engine);
}

static void make_ipv4_endpoint(uint8_t endpoint[15], uint16_t port) {
    static const uint8_t prefix[] = {1, 2, 1, 0, 0, 0, 0, 0, 0, 0, 4,
                                     127, 0, 0, 1};
    (void)memcpy(endpoint, prefix, sizeof(prefix));
    endpoint[3] = (uint8_t)(port >> 8U);
    endpoint[4] = (uint8_t)(port & 0xffU);
}

static int send_and_receive(clash_flow_t *flow, operation_state_t *state,
                            const uint8_t endpoint[15], uint32_t sequence) {
    uint8_t payload[PAYLOAD_BYTES];
    make_payload(payload, sequence);
    clash_flow_datagram_v1_t datagram = {
        .payload = payload,
        .payload_length = sizeof(payload),
        .remote_endpoint = endpoint,
        .remote_endpoint_length = 15U,
    };
    const uint64_t read_token = (uint64_t)sequence + 1U;
    const uint64_t write_token = (uint64_t)sequence + 100000U;

    operation_state_reset(state);
    if (clash_flow_udp_read(flow, 1U, PAYLOAD_BYTES, read_token,
                            read_callback, state) != CLASH_FLOW_OK ||
        clash_flow_udp_write(flow, &datagram, 1U, write_token,
                             completion_callback, state) != CLASH_FLOW_OK ||
        operation_state_wait(state, 1, CALLBACK_TIMEOUT_MS) != 0) {
        return -1;
    }

    int valid;
    (void)pthread_mutex_lock(&state->mutex);
    valid = !state->duplicate_callback &&
            state->read_status == CLASH_FLOW_OK &&
            state->write_status == CLASH_FLOW_OK &&
            state->read_token == read_token &&
            state->write_token == write_token &&
            state->datagram_count == 1U &&
            validate_payload(state->payload, state->payload_length, sequence);
    (void)pthread_mutex_unlock(&state->mutex);
    return valid ? 0 : -1;
}

int main(int argc, char **argv) {
    if (argc != 2 || argv[1][0] != '/') {
        fprintf(stderr, "usage: %s /absolute/temporary/directory\n", argv[0]);
        return 64;
    }

    udp_echo_server_t server;
    if (udp_echo_server_start(&server, TEST_DATAGRAMS + WARMUP_DATAGRAMS) != 0) {
        fprintf(stderr, "could not start UDP integrity echo server\n");
        return 1;
    }

    clash_flow_engine_t *engine = NULL;
    clash_flow_t *flow = NULL;
    uint8_t source[15];
    uint8_t destination[15];
    make_ipv4_endpoint(source, 49152U);
    make_ipv4_endpoint(destination, server.port);
    source[3] = (uint8_t)(49152U >> 8U);
    source[4] = (uint8_t)(49152U & 0xffU);

    if (create_engine(argv[1], &engine) != CLASH_FLOW_OK || engine == NULL ||
        clash_flow_udp_create(engine, source, sizeof(source), &flow) !=
            CLASH_FLOW_OK ||
        flow == NULL || clash_flow_activate(flow) != CLASH_FLOW_OK) {
        fprintf(stderr, "could not start FlowOnly UDP integrity path\n");
        return 2;
    }

    operation_state_t state;
    operation_state_init(&state);
    for (uint32_t index = 0U;
         index < (uint32_t)(TEST_DATAGRAMS + WARMUP_DATAGRAMS); ++index) {
        if (send_and_receive(flow, &state, destination, index) != 0) {
            fprintf(stderr, "FlowOnly UDP integrity failed at sequence=%u\n",
                    index);
            return 3;
        }
    }

    operation_state_reset(&state);
    if (clash_flow_udp_read(flow, 1U, PAYLOAD_BYTES, 900000U,
                            read_callback, &state) != CLASH_FLOW_OK ||
        operation_state_wait(&state, 0, 100U) == 0) {
        fprintf(stderr, "FlowOnly UDP emitted an unexpected duplicate\n");
        return 4;
    }
    if (clash_flow_cancel(flow) != CLASH_FLOW_OK ||
        operation_state_wait(&state, 0, CALLBACK_TIMEOUT_MS) != 0) {
        fprintf(stderr, "FlowOnly UDP cancellation did not drain final read\n");
        return 5;
    }

    int read_cancelled;
    (void)pthread_mutex_lock(&state.mutex);
    read_cancelled = state.read_status == CLASH_FLOW_CANCELLED &&
                     state.datagram_count == 0U;
    (void)pthread_mutex_unlock(&state.mutex);
    if (!read_cancelled || clash_flow_destroy(flow) != CLASH_FLOW_OK ||
        clash_flow_engine_destroy(engine) != CLASH_FLOW_OK ||
        pthread_join(server.thread, NULL) != 0 || server.error != 0 ||
        server.received != TEST_DATAGRAMS + WARMUP_DATAGRAMS ||
        server.sent != TEST_DATAGRAMS + WARMUP_DATAGRAMS) {
        fprintf(stderr,
                "FlowOnly UDP final state invalid: cancelled=%d received=%d "
                "sent=%d error=%d\n",
                read_cancelled, server.received, server.sent, server.error);
        return 6;
    }

    (void)pthread_cond_destroy(&state.condition);
    (void)pthread_mutex_destroy(&state.mutex);
    printf("flow_udp_integrity=pass warmup=%d datagrams=%d missing=0 duplicates=0\n",
           WARMUP_DATAGRAMS, TEST_DATAGRAMS);
    return 0;
}
