#include "clashrs.h"

#include <arpa/inet.h>
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

enum {
    TEST_DATAGRAMS = 10000,
    WARMUP_DATAGRAMS = 32,
    SEND_WINDOW = 1,
    WAIT_TIMEOUT_MS = 5000,
    PAYLOAD_BYTES = 12,
    IPV4_HEADER_BYTES = 20,
    UDP_HEADER_BYTES = 8,
    PACKET_BYTES = IPV4_HEADER_BYTES + UDP_HEADER_BYTES + PAYLOAD_BYTES,
    CLIENT_PORT = 42000,
};

typedef struct engine_arguments {
    const char *profile;
    const char *runtime_path;
    char *result;
} engine_arguments_t;

typedef struct udp_echo_server {
    int descriptor;
    uint16_t port;
    pthread_t thread;
    int expected;
    int received;
    int sent;
    int error;
} udp_echo_server_t;

typedef struct output_state {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    uint8_t seen[TEST_DATAGRAMS];
    uint8_t warmup_seen[WARMUP_DATAGRAMS];
    int received;
    int warmup_received;
    int duplicates;
    int malformed;
    uint16_t server_port;
} output_state_t;

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

static void write_be16(uint8_t *bytes, uint16_t value) {
    bytes[0] = (uint8_t)(value >> 8U);
    bytes[1] = (uint8_t)value;
}

static void write_be32(uint8_t *bytes, uint32_t value) {
    bytes[0] = (uint8_t)(value >> 24U);
    bytes[1] = (uint8_t)(value >> 16U);
    bytes[2] = (uint8_t)(value >> 8U);
    bytes[3] = (uint8_t)value;
}

static uint16_t read_be16(const uint8_t *bytes) {
    return (uint16_t)(((uint16_t)bytes[0] << 8U) | (uint16_t)bytes[1]);
}

static uint32_t read_be32(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24U) |
           ((uint32_t)bytes[1] << 16U) |
           ((uint32_t)bytes[2] << 8U) | (uint32_t)bytes[3];
}

static uint16_t ipv4_checksum(const uint8_t *header, size_t length) {
    uint32_t sum = 0U;
    for (size_t offset = 0U; offset < length; offset += 2U) {
        sum += ((uint32_t)header[offset] << 8U) |
               (uint32_t)header[offset + 1U];
    }
    while ((sum >> 16U) != 0U) {
        sum = (sum & 0xffffU) + (sum >> 16U);
    }
    return (uint16_t)(~sum);
}

static void make_payload(uint8_t payload[PAYLOAD_BYTES], uint32_t sequence) {
    (void)memcpy(payload, "ARUP", 4U);
    write_be32(payload + 4U, sequence);
    write_be32(payload + 8U, sequence ^ 0x5D28A4E3U);
}

static int validate_payload(const uint8_t *payload, size_t length,
                            uint32_t *sequence) {
    if (length != PAYLOAD_BYTES || memcmp(payload, "ARUP", 4U) != 0) {
        return 0;
    }
    const uint32_t value = read_be32(payload + 4U);
    if (read_be32(payload + 8U) != (value ^ 0x5D28A4E3U)) {
        return 0;
    }
    *sequence = value;
    return 1;
}

static void make_packet(uint8_t packet[PACKET_BYTES], uint16_t server_port,
                        uint32_t sequence) {
    (void)memset(packet, 0, PACKET_BYTES);
    packet[0] = 0x45U;
    write_be16(packet + 2U, PACKET_BYTES);
    write_be16(packet + 4U, (uint16_t)sequence);
    write_be16(packet + 6U, 0x4000U);
    packet[8] = 64U;
    packet[9] = 17U;
    packet[12] = 198U;
    packet[13] = 18U;
    packet[14] = 0U;
    packet[15] = 2U;
    packet[16] = 127U;
    packet[17] = 0U;
    packet[18] = 0U;
    packet[19] = 1U;
    write_be16(packet + 10U, ipv4_checksum(packet, IPV4_HEADER_BYTES));

    uint8_t *udp = packet + IPV4_HEADER_BYTES;
    write_be16(udp, CLIENT_PORT);
    write_be16(udp + 2U, server_port);
    write_be16(udp + 4U, UDP_HEADER_BYTES + PAYLOAD_BYTES);
    write_be16(udp + 6U, 0U);
    make_payload(udp + UDP_HEADER_BYTES, sequence);
}

static void packet_output(const uint8_t *packet, size_t length,
                          uint8_t ip_version, void *context) {
    output_state_t *state = (output_state_t *)context;
    int valid = packet != NULL && ip_version == 4U &&
                length >= IPV4_HEADER_BYTES + UDP_HEADER_BYTES;
    uint32_t sequence = 0U;
    if (valid) {
        const size_t header_length = (size_t)(packet[0] & 0x0fU) * 4U;
        valid = (packet[0] >> 4U) == 4U && header_length >= IPV4_HEADER_BYTES &&
                length >= header_length + UDP_HEADER_BYTES && packet[9] == 17U;
        if (valid) {
            const uint8_t *udp = packet + header_length;
            const uint16_t udp_length = read_be16(udp + 4U);
            valid = read_be16(udp) == state->server_port &&
                    read_be16(udp + 2U) == CLIENT_PORT &&
                    udp_length == UDP_HEADER_BYTES + PAYLOAD_BYTES &&
                    length >= header_length + udp_length &&
                    validate_payload(udp + UDP_HEADER_BYTES,
                                     udp_length - UDP_HEADER_BYTES, &sequence);
        }
    }

    (void)pthread_mutex_lock(&state->mutex);
    if (!valid) {
        state->malformed += 1;
    } else if (sequence < TEST_DATAGRAMS) {
        if (state->seen[sequence] != 0U) {
            state->duplicates += 1;
        } else {
            state->seen[sequence] = 1U;
            state->received += 1;
        }
    } else if (sequence >= 0x80000000U &&
               sequence < 0x80000000U + WARMUP_DATAGRAMS) {
        const uint32_t index = sequence - 0x80000000U;
        if (state->warmup_seen[index] != 0U) {
            state->duplicates += 1;
        } else {
            state->warmup_seen[index] = 1U;
            state->warmup_received += 1;
        }
    } else {
        state->malformed += 1;
    }
    (void)pthread_cond_broadcast(&state->condition);
    (void)pthread_mutex_unlock(&state->mutex);
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

static void *run_engine(void *raw_arguments) {
    engine_arguments_t *arguments = (engine_arguments_t *)raw_arguments;
    arguments->result = clash_start_packet_flow_with_mode(
        arguments->profile, "", arguments->runtime_path, 1500, 0, 1);
    return NULL;
}

static int wait_for_output(output_state_t *state, int expected, int warmup) {
    const struct timespec deadline = deadline_after_ms(WAIT_TIMEOUT_MS);
    int status = 0;
    (void)pthread_mutex_lock(&state->mutex);
    while ((warmup ? state->warmup_received : state->received) < expected &&
           state->duplicates == 0 && state->malformed == 0 && status == 0) {
        status = pthread_cond_timedwait(&state->condition, &state->mutex,
                                        &deadline);
    }
    const int valid = status == 0 && state->duplicates == 0 &&
                      state->malformed == 0 &&
                      (warmup ? state->warmup_received : state->received) >=
                          expected;
    (void)pthread_mutex_unlock(&state->mutex);
    return valid ? 0 : -1;
}

static int inject_sequence(uint16_t server_port, uint32_t sequence) {
    uint8_t packet[PACKET_BYTES];
    make_packet(packet, server_port, sequence);
    for (int attempt = 0; attempt < 5000; ++attempt) {
        if (clash_packet_input(packet, sizeof(packet)) == 1) {
            return 0;
        }
        usleep(1000);
    }
    return -1;
}

int main(int argc, char **argv) {
    if (argc != 2 || argv[1][0] != '/') {
        fprintf(stderr, "usage: %s /absolute/temporary/directory\n", argv[0]);
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

    udp_echo_server_t server;
    if (udp_echo_server_start(&server, TEST_DATAGRAMS + WARMUP_DATAGRAMS) != 0) {
        fprintf(stderr, "could not start PacketFlow UDP integrity echo server\n");
        return 1;
    }

    output_state_t state;
    (void)memset(&state, 0, sizeof(state));
    state.server_port = server.port;
    (void)pthread_mutex_init(&state.mutex, NULL);
    (void)pthread_cond_init(&state.condition, NULL);
    if (clash_install_packet_flow(packet_output, &state) != 1) {
        fprintf(stderr, "could not install PacketFlow callback\n");
        return 2;
    }

    engine_arguments_t arguments = {
        .profile = profile,
        .runtime_path = argv[1],
        .result = NULL,
    };
    pthread_t engine_thread;
    if (pthread_create(&engine_thread, NULL, run_engine, &arguments) != 0) {
        fprintf(stderr, "could not start PacketFlow engine thread\n");
        return 3;
    }
    int ready = 0;
    for (int attempt = 0; attempt < 400; ++attempt) {
        if (clash_packet_flow_ready() == 1) {
            ready = 1;
            break;
        }
        usleep(25000);
    }
    if (!ready) {
        fprintf(stderr, "PacketFlow UDP integrity engine was not ready\n");
        return 4;
    }

    for (uint32_t index = 0U; index < WARMUP_DATAGRAMS; ++index) {
        if (inject_sequence(server.port, 0x80000000U + index) != 0 ||
            ((index + 1U) % SEND_WINDOW == 0U &&
             wait_for_output(&state, (int)index + 1, 1) != 0)) {
            fprintf(stderr, "PacketFlow UDP warm-up failed at sequence=%u\n",
                    index);
            return 5;
        }
    }
    if (wait_for_output(&state, WARMUP_DATAGRAMS, 1) != 0) {
        fprintf(stderr, "PacketFlow UDP warm-up did not drain\n");
        return 5;
    }

    for (uint32_t index = 0U; index < TEST_DATAGRAMS; ++index) {
        if (inject_sequence(server.port, index) != 0 ||
            ((index + 1U) % SEND_WINDOW == 0U &&
             wait_for_output(&state, (int)index + 1, 0) != 0)) {
            fprintf(stderr, "PacketFlow UDP integrity failed at sequence=%u\n",
                    index);
            return 6;
        }
    }
    if (wait_for_output(&state, TEST_DATAGRAMS, 0) != 0) {
        fprintf(stderr, "PacketFlow UDP output did not drain\n");
        return 6;
    }

    usleep(100000);
    (void)pthread_mutex_lock(&state.mutex);
    const int output_valid = state.received == TEST_DATAGRAMS &&
                             state.warmup_received == WARMUP_DATAGRAMS &&
                             state.duplicates == 0 && state.malformed == 0;
    (void)pthread_mutex_unlock(&state.mutex);

    const int stopped = clash_shutdown();
    (void)pthread_join(engine_thread, NULL);
    const int server_joined = pthread_join(server.thread, NULL);
    const int engine_valid = stopped == 1 && arguments.result != NULL &&
                             strlen(arguments.result) == 0;
    clash_free_string(arguments.result);

    if (!output_valid || !engine_valid || server_joined != 0 ||
        server.error != 0 ||
        server.received != TEST_DATAGRAMS + WARMUP_DATAGRAMS ||
        server.sent != TEST_DATAGRAMS + WARMUP_DATAGRAMS) {
        fprintf(stderr,
                "PacketFlow UDP final state invalid: output=%d engine=%d "
                "received=%d sent=%d error=%d\n",
                output_valid, engine_valid, server.received, server.sent,
                server.error);
        return 7;
    }

    (void)pthread_cond_destroy(&state.condition);
    (void)pthread_mutex_destroy(&state.mutex);
    printf("packet_udp_integrity=pass warmup=%d datagrams=%d missing=0 duplicates=0\n",
           WARMUP_DATAGRAMS, TEST_DATAGRAMS);
    return 0;
}
