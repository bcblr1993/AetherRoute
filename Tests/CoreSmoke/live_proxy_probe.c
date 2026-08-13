/*
 * Live proxy probe.
 *
 * Starts the Direct core with a real profile and a loopback SOCKS5/HTTP
 * listener, then reports the selector state for a group. This is the missing
 * end-to-end seam: it exercises core routing without a Network Extension, a
 * signature, or notarization, so "does the proxy actually egress" becomes a
 * question answerable in seconds instead of a 40-minute signed build cycle.
 *
 * It binds loopback only and never changes system proxy, DNS, or routes.
 */

#include "clashrs.h"

#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>

struct engine_arguments {
    char *profile;
    const char *runtime_path;
    const clash_packet_local_proxy_v1_t *local_proxy;
    char *result;
};

static void *run_engine(void *raw) {
    struct engine_arguments *a = raw;
    a->result = clash_start_packet_flow_with_policy_and_local_proxy_v1(
        a->profile,
        "",
        a->runtime_path,
        1500,
        0,
        NULL,
        a->local_proxy,
        1
    );
    return NULL;
}

static char *read_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { return NULL; }
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long size = ftell(f);
    if (size < 0 || size > 64L * 1024 * 1024) { fclose(f); return NULL; }
    rewind(f);
    char *buffer = malloc((size_t)size + 1);
    if (!buffer) { fclose(f); return NULL; }
    size_t read = fread(buffer, 1, (size_t)size, f);
    fclose(f);
    buffer[read] = '\0';
    return buffer;
}

static uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16)
        | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

/* ARS1: magic, selected index (u32 BE, UINT32_MAX = none), member count,
 * then repeated (u32 BE length, UTF-8 bytes). */
static void print_selector(const char *group) {
    uint8_t buffer[64 * 1024];
    size_t required = 0;
    int32_t status = clash_packet_selector_snapshot_v1(
        (const uint8_t *)group,
        strlen(group),
        buffer,
        sizeof(buffer),
        &required
    );
    if (status != 0) {
        printf("SELECTOR group=%s status=%d (see clash_flow_status_message)\n",
               group, status);
        return;
    }
    if (required < 12 || memcmp(buffer, "ARS1", 4) != 0) {
        printf("SELECTOR group=%s malformed snapshot bytes=%zu\n",
               group, required);
        return;
    }
    uint32_t selected = be32(buffer + 4);
    uint32_t count = be32(buffer + 8);
    size_t offset = 12;
    printf("SELECTOR group=%s members=%u\n", group, count);
    for (uint32_t i = 0; i < count && offset + 4 <= required; i += 1) {
        uint32_t length = be32(buffer + offset);
        offset += 4;
        if (offset + length > required) { break; }
        printf("  [%u] %.*s%s\n",
               i,
               (int)length,
               (const char *)(buffer + offset),
               i == selected ? "   <== SELECTED" : "");
        offset += length;
    }
    if (selected == UINT32_MAX) {
        printf("  (no member selected)\n");
    }
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr,
                "usage: %s PROFILE RUNTIME_DIR SOCKS_PORT [GROUP] [SELECT_MEMBER]\n",
                argv[0]);
        return 64;
    }
    const char *profile_path = argv[1];
    const char *runtime_path = argv[2];
    int socks_port = atoi(argv[3]);
    const char *group = argc > 4 ? argv[4] : NULL;
    const char *member = argc > 5 ? argv[5] : NULL;

    if (socks_port < 1024 || socks_port > 65535) {
        fprintf(stderr, "SOCKS port must be 1024...65535\n");
        return 64;
    }

    char *profile = read_file(profile_path);
    if (!profile) {
        fprintf(stderr, "cannot read profile: %s\n", profile_path);
        return 66;
    }

    clash_packet_local_proxy_v1_t local_proxy = {
        .struct_size = sizeof(local_proxy),
        .enabled = 1,
        .http_port = (uint32_t)(socks_port + 1),
        .socks_port = (uint32_t)socks_port,
    };
    struct engine_arguments arguments = {
        .profile = profile,
        .runtime_path = runtime_path,
        .local_proxy = &local_proxy,
        .result = NULL,
    };

    pthread_t thread;
    if (pthread_create(&thread, NULL, run_engine, &arguments) != 0) {
        fprintf(stderr, "cannot start engine thread\n");
        return 1;
    }

    /* The core needs a moment to parse the profile and bind listeners. */
    sleep(3);

    if (arguments.result) {
        printf("ENGINE FAILED: %s\n", arguments.result);
        clash_free_string(arguments.result);
        return 1;
    }

    if (member && group) {
        int32_t status = clash_packet_selector_select_v1(
            (const uint8_t *)group,
            strlen(group),
            (const uint8_t *)member,
            strlen(member)
        );
        printf("SELECT group=%s member=%s status=%d\n", group, member, status);
    }
    if (group) {
        print_selector(group);
    }

    printf("READY socks=127.0.0.1:%d http=127.0.0.1:%d\n",
           socks_port, socks_port + 1);
    fflush(stdout);

    /* Stay alive so a caller can drive traffic through the listener. */
    for (;;) { sleep(3600); }
}
