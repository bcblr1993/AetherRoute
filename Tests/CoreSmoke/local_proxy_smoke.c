#include "clashrs.h"

#include <arpa/inet.h>
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

struct engine_arguments {
    const char *profile;
    const char *log_path;
    const char *runtime_path;
    const clash_packet_local_proxy_v1_t *local_proxy;
    char *result;
};

struct echo_arguments {
    int listener;
    int result;
};

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
        arguments->log_path,
        arguments->runtime_path,
        1500,
        0,
        NULL,
        arguments->local_proxy,
        1
    );
    return NULL;
}

static int configure_socket(int socket_fd) {
    struct timeval timeout = {.tv_sec = 4, .tv_usec = 0};
    return setsockopt(
        socket_fd,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &timeout,
        sizeof(timeout)
    ) == 0
        && setsockopt(
            socket_fd,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            sizeof(timeout)
        ) == 0;
}

static int create_loopback_listener(uint16_t *port) {
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0 || !configure_socket(listener)) {
        if (listener >= 0) {
            close(listener);
        }
        return -1;
    }
    int reuse = 1;
    (void)setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in address = {
        .sin_family = AF_INET,
        .sin_port = htons(0),
        .sin_addr = {.s_addr = htonl(INADDR_LOOPBACK)},
    };
    if (bind(listener, (const struct sockaddr *)&address, sizeof(address)) != 0
        || listen(listener, 8) != 0) {
        close(listener);
        return -1;
    }
    socklen_t address_length = sizeof(address);
    if (getsockname(
            listener,
            (struct sockaddr *)&address,
            &address_length
        ) != 0) {
        close(listener);
        return -1;
    }
    *port = ntohs(address.sin_port);
    return listener;
}

static uint16_t unused_loopback_port(void) {
    uint16_t port = 0;
    int listener = create_loopback_listener(&port);
    if (listener >= 0) {
        close(listener);
    }
    return port;
}

static int connect_loopback(uint16_t port) {
    int socket_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (socket_fd < 0 || !configure_socket(socket_fd)) {
        if (socket_fd >= 0) {
            close(socket_fd);
        }
        return -1;
    }
    struct sockaddr_in address = {
        .sin_family = AF_INET,
        .sin_port = htons(port),
        .sin_addr = {.s_addr = htonl(INADDR_LOOPBACK)},
    };
    if (connect(
            socket_fd,
            (const struct sockaddr *)&address,
            sizeof(address)
        ) != 0) {
        close(socket_fd);
        return -1;
    }
    return socket_fd;
}

static int wait_for_listener(uint16_t port) {
    for (int attempt = 0; attempt < 400; attempt += 1) {
        int socket_fd = connect_loopback(port);
        if (socket_fd >= 0) {
            close(socket_fd);
            return 1;
        }
        usleep(25000);
    }
    return 0;
}

static int port_is_closed(uint16_t port) {
    int socket_fd = connect_loopback(port);
    if (socket_fd < 0) {
        return 1;
    }
    close(socket_fd);
    return 0;
}

static int send_all(int socket_fd, const void *buffer, size_t length) {
    const uint8_t *bytes = buffer;
    size_t sent = 0;
    while (sent < length) {
        ssize_t count = send(socket_fd, bytes + sent, length - sent, 0);
        if (count <= 0) {
            return 0;
        }
        sent += (size_t)count;
    }
    return 1;
}

static int receive_exact(int socket_fd, void *buffer, size_t length) {
    uint8_t *bytes = buffer;
    size_t received = 0;
    while (received < length) {
        ssize_t count = recv(socket_fd, bytes + received, length - received, 0);
        if (count <= 0) {
            return 0;
        }
        received += (size_t)count;
    }
    return 1;
}

static void *run_echo_server(void *raw_arguments) {
    struct echo_arguments *arguments = raw_arguments;
    arguments->result = 0;
    for (int connection = 0; connection < 2; connection += 1) {
        int client = accept(arguments->listener, NULL, NULL);
        if (client < 0 || !configure_socket(client)) {
            if (client >= 0) {
                close(client);
            }
            return NULL;
        }
        uint8_t payload[128];
        ssize_t count = recv(client, payload, sizeof(payload), 0);
        if (count <= 0 || !send_all(client, payload, (size_t)count)) {
            close(client);
            return NULL;
        }
        close(client);
    }
    arguments->result = 1;
    return NULL;
}

static int start_engine(
    struct engine_arguments *arguments,
    pthread_t *thread,
    int *thread_started
) {
    *thread_started = 0;
    if (clash_install_packet_flow(packet_output, NULL) != 1) {
        return 0;
    }
    if (pthread_create(thread, NULL, run_engine, arguments) != 0) {
        clash_uninstall_packet_flow();
        return 0;
    }
    *thread_started = 1;
    for (int attempt = 0; attempt < 400; attempt += 1) {
        if (clash_packet_flow_ready() == 1) {
            return 1;
        }
        usleep(25000);
    }
    return 0;
}

static int stop_engine(
    struct engine_arguments *arguments,
    pthread_t thread,
    int thread_started
) {
    int stopped = 0;
    if (thread_started) {
        stopped = clash_shutdown();
        pthread_join(thread, NULL);
    }
    clash_uninstall_packet_flow();
    int valid = thread_started
        && stopped == 1
        && arguments->result != NULL
        && strlen(arguments->result) == 0
        && clash_packet_flow_ready() == 0;
    if (!valid && arguments->result != NULL && strlen(arguments->result) > 0) {
        fprintf(stderr, "engine result: %s\n", arguments->result);
    }
    clash_free_string(arguments->result);
    arguments->result = NULL;
    return valid;
}

static int verify_echo(int socket_fd, const char *message) {
    size_t length = strlen(message);
    char response[128];
    if (length > sizeof(response)
        || !send_all(socket_fd, message, length)
        || !receive_exact(socket_fd, response, length)) {
        return 0;
    }
    return memcmp(response, message, length) == 0;
}

static int verify_http_connect(uint16_t proxy_port, uint16_t target_port) {
    int socket_fd = connect_loopback(proxy_port);
    if (socket_fd < 0) {
        return 0;
    }
    char request[256];
    int request_length = snprintf(
        request,
        sizeof(request),
        "CONNECT 127.0.0.1:%u HTTP/1.1\r\nHost: 127.0.0.1:%u\r\n\r\n",
        target_port,
        target_port
    );
    if (request_length <= 0
        || (size_t)request_length >= sizeof(request)
        || !send_all(socket_fd, request, (size_t)request_length)) {
        close(socket_fd);
        return 0;
    }
    char response[1024];
    size_t received = 0;
    int complete = 0;
    while (received + 1 < sizeof(response)) {
        ssize_t count = recv(
            socket_fd,
            response + received,
            sizeof(response) - received - 1,
            0
        );
        if (count <= 0) {
            break;
        }
        received += (size_t)count;
        response[received] = '\0';
        if (strstr(response, "\r\n\r\n") != NULL) {
            complete = 1;
            break;
        }
    }
    int valid = complete
        && (strncmp(response, "HTTP/1.1 200", 12) == 0
            || strncmp(response, "HTTP/1.0 200", 12) == 0)
        && verify_echo(socket_fd, "aether-http-loopback");
    close(socket_fd);
    return valid;
}

static int verify_socks5(uint16_t proxy_port, uint16_t target_port) {
    int socket_fd = connect_loopback(proxy_port);
    if (socket_fd < 0) {
        return 0;
    }
    const uint8_t greeting[] = {0x05, 0x01, 0x00};
    uint8_t greeting_response[2];
    if (!send_all(socket_fd, greeting, sizeof(greeting))
        || !receive_exact(
            socket_fd,
            greeting_response,
            sizeof(greeting_response)
        )
        || greeting_response[0] != 0x05
        || greeting_response[1] != 0x00) {
        close(socket_fd);
        return 0;
    }
    uint8_t request[] = {
        0x05,
        0x01,
        0x00,
        0x01,
        127,
        0,
        0,
        1,
        (uint8_t)(target_port >> 8),
        (uint8_t)(target_port & 0xff),
    };
    uint8_t response[10];
    int valid = send_all(socket_fd, request, sizeof(request))
        && receive_exact(socket_fd, response, sizeof(response))
        && response[0] == 0x05
        && response[1] == 0x00
        && response[3] == 0x01
        && verify_echo(socket_fd, "aether-socks-loopback");
    close(socket_fd);
    return valid;
}

static int distinct_ports(const uint16_t *ports, size_t count) {
    for (size_t outer = 0; outer < count; outer += 1) {
        if (ports[outer] < 1024) {
            return 0;
        }
        for (size_t inner = outer + 1; inner < count; inner += 1) {
            if (ports[outer] == ports[inner]) {
                return 0;
            }
        }
    }
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: local_proxy_smoke RUNTIME_DIR LOG_PATH\n");
        return 64;
    }

    uint16_t ports[5];
    for (size_t index = 0; index < 5; index += 1) {
        ports[index] = unused_loopback_port();
    }
    if (!distinct_ports(ports, 5)) {
        fprintf(stderr, "failed to reserve distinct loopback ports\n");
        return 1;
    }
    uint16_t profile_http_port = ports[0];
    uint16_t profile_socks_port = ports[1];
    uint16_t profile_mixed_port = ports[2];
    uint16_t http_port = ports[3];
    uint16_t socks_port = ports[4];

    char profile[2048];
    int profile_length = snprintf(
        profile,
        sizeof(profile),
        "port: %u\n"
        "socks-port: %u\n"
        "mixed-port: %u\n"
        "allow-lan: true\n"
        "bind-address: 0.0.0.0\n"
        "mode: direct\n"
        "log-level: error\n"
        "external-controller: ''\n"
        "dns:\n"
        "  enable: false\n"
        "proxies: []\n"
        "proxy-groups: []\n"
        "rules:\n"
        "  - MATCH,DIRECT\n",
        profile_http_port,
        profile_socks_port,
        profile_mixed_port
    );
    if (profile_length <= 0 || (size_t)profile_length >= sizeof(profile)) {
        fprintf(stderr, "failed to create isolated profile\n");
        return 1;
    }

    clash_packet_local_proxy_v1_t disabled = {
        .struct_size = sizeof(disabled),
        .enabled = 0,
        .http_port = 0,
        .socks_port = 0,
    };
    struct engine_arguments disabled_arguments = {
        .profile = profile,
        .log_path = argv[2],
        .runtime_path = argv[1],
        .local_proxy = &disabled,
        .result = NULL,
    };
    pthread_t disabled_thread;
    int disabled_thread_started = 0;
    int disabled_ready = start_engine(
        &disabled_arguments,
        &disabled_thread,
        &disabled_thread_started
    );
    int profile_listeners_removed = disabled_ready
        && port_is_closed(profile_http_port)
        && port_is_closed(profile_socks_port)
        && port_is_closed(profile_mixed_port);
    int disabled_stopped = stop_engine(
        &disabled_arguments,
        disabled_thread,
        disabled_thread_started
    );
    if (!profile_listeners_removed || !disabled_stopped) {
        fprintf(stderr, "profile listener removal was not verified\n");
        return 1;
    }

    uint16_t target_port = 0;
    int echo_listener = create_loopback_listener(&target_port);
    if (echo_listener < 0) {
        fprintf(stderr, "failed to create loopback echo listener\n");
        return 1;
    }
    struct echo_arguments echo_arguments = {
        .listener = echo_listener,
        .result = 0,
    };
    pthread_t echo_thread;
    if (pthread_create(&echo_thread, NULL, run_echo_server, &echo_arguments) != 0) {
        close(echo_listener);
        fprintf(stderr, "failed to start loopback echo server\n");
        return 1;
    }

    clash_packet_local_proxy_v1_t enabled = {
        .struct_size = sizeof(enabled),
        .enabled = 1,
        .http_port = http_port,
        .socks_port = socks_port,
    };
    struct engine_arguments enabled_arguments = {
        .profile = profile,
        .log_path = argv[2],
        .runtime_path = argv[1],
        .local_proxy = &enabled,
        .result = NULL,
    };
    pthread_t enabled_thread;
    int enabled_thread_started = 0;
    int enabled_ready = start_engine(
        &enabled_arguments,
        &enabled_thread,
        &enabled_thread_started
    );
    int listeners_ready = enabled_ready
        && wait_for_listener(http_port)
        && wait_for_listener(socks_port);
    int http_verified = listeners_ready
        && verify_http_connect(http_port, target_port);
    int socks_verified = http_verified
        && verify_socks5(socks_port, target_port);
    int still_hardened = port_is_closed(profile_http_port)
        && port_is_closed(profile_socks_port)
        && port_is_closed(profile_mixed_port);
    int enabled_stopped = stop_engine(
        &enabled_arguments,
        enabled_thread,
        enabled_thread_started
    );
    close(echo_listener);
    pthread_join(echo_thread, NULL);

    if (!listeners_ready
        || !http_verified
        || !socks_verified
        || !still_hardened
        || !enabled_stopped
        || !echo_arguments.result) {
        fprintf(
            stderr,
            "local proxy verification failed: ready=%d http=%d socks=%d hardened=%d stopped=%d echo=%d\n",
            listeners_ready,
            http_verified,
            socks_verified,
            still_hardened,
            enabled_stopped,
            echo_arguments.result
        );
        return 1;
    }

    puts(
        "loopback local proxy passed: profile-listeners=removed "
        "http-connect=pass socks5=pass allow-lan=false"
    );
    return 0;
}
