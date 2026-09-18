#include "clashrs.h"

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum { MAXIMUM_PROFILE_BYTES = 10 * 1024 * 1024 };

static uint8_t *read_profile(const char *path, size_t *length) {
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
    uint8_t *bytes = malloc((size_t)size + 1U);
    if (bytes == NULL
        || fread(bytes, 1U, (size_t)size, file) != (size_t)size) {
        free(bytes);
        (void)fclose(file);
        return NULL;
    }
    (void)fclose(file);
    bytes[size] = 0;
    *length = (size_t)size;
    return bytes;
}

#if defined(AETHER_EXTERNAL_FLOW_ONLY)

static int run_profile(
    const uint8_t *profile,
    size_t profile_length,
    const char *runtime_path
) {
    const clash_flow_engine_options_v1_t options = {
        .struct_size = (uint32_t)sizeof(clash_flow_engine_options_v1_t),
        .worker_threads = 2,
        .queue_depth = 32,
        .maximum_tcp_chunk_bytes = 65536,
        .maximum_udp_payload_bytes = 65507,
    };
    clash_flow_engine_t *engine = NULL;
    int32_t status = clash_flow_engine_create(
        profile,
        profile_length,
        (const uint8_t *)runtime_path,
        strlen(runtime_path),
        &options,
        &engine
    );
    if (status != CLASH_FLOW_OK || engine == NULL) {
        fprintf(stderr, "flow-only create status=%d\n", status);
        return 1;
    }

    size_t telemetry_length = 0;
    status = clash_flow_telemetry_snapshot_v1(
        engine,
        50,
        NULL,
        0,
        &telemetry_length
    );
    int destroy_status = clash_flow_engine_destroy(engine);
    if (status != CLASH_FLOW_OK
        || telemetry_length < 48U
        || destroy_status != CLASH_FLOW_OK) {
        fprintf(
            stderr,
            "flow-only lifecycle status=%d telemetry=%zu destroy=%d\n",
            status,
            telemetry_length,
            destroy_status
        );
        return 1;
    }
    return 0;
}

#elif defined(AETHER_EXTERNAL_PACKET)

struct engine_arguments {
    const char *profile;
    const char *runtime_path;
    const char *log_path;
    char *result;
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

static void *start_packet_engine(void *raw_arguments) {
    struct engine_arguments *arguments = raw_arguments;
    arguments->result = clash_start_packet_flow_with_mode(
        arguments->profile,
        arguments->log_path,
        arguments->runtime_path,
        1500,
        0,
        1
    );
    return NULL;
}

static int run_profile(
    const uint8_t *profile,
    size_t profile_length,
    const char *runtime_path
) {
    (void)profile_length;
    if (clash_install_packet_flow(packet_output, NULL) != 1) {
        return 1;
    }

    struct engine_arguments arguments = {
        .profile = (const char *)profile,
        .runtime_path = runtime_path,
        .log_path = "",
        .result = NULL,
    };
    pthread_t thread;
    if (pthread_create(&thread, NULL, start_packet_engine, &arguments) != 0) {
        clash_uninstall_packet_flow();
        return 1;
    }

    int ready = 0;
    for (int attempt = 0; attempt < 600; attempt += 1) {
        if (clash_packet_flow_ready() == 1) {
            ready = 1;
            break;
        }
        usleep(25000);
    }

    size_t telemetry_length = 0;
    int telemetry_status = ready ? clash_packet_telemetry_snapshot_v1(
        50,
        NULL,
        0,
        &telemetry_length
    ) : CLASH_FLOW_INVALID_STATE;
    int stopped = clash_shutdown();
    (void)pthread_join(thread, NULL);
    clash_uninstall_packet_flow();

    int success = ready
        && telemetry_status == CLASH_FLOW_OK
        && telemetry_length >= 48U
        && stopped == 1
        && arguments.result != NULL
        && strlen(arguments.result) == 0U
        && clash_packet_flow_ready() == 0;
    if (!success) {
        fprintf(
            stderr,
            "packet lifecycle ready=%d telemetry=%d bytes=%zu stopped=%d result=%s\n",
            ready,
            telemetry_status,
            telemetry_length,
            stopped,
            arguments.result == NULL ? "missing" : "present"
        );
        if (arguments.result != NULL) {
            fprintf(stderr, "engine error: %s\n", arguments.result);
        }
    }
    clash_free_string(arguments.result);
    return success ? 0 : 1;
}

#else
#error "Select exactly one external profile smoke surface"
#endif

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: external_profile_smoke PROFILE RUNTIME_DIR\n");
        return 64;
    }

    size_t profile_length = 0;
    uint8_t *profile = read_profile(argv[1], &profile_length);
    if (profile == NULL) {
        fprintf(stderr, "could not read bounded profile fixture\n");
        return 1;
    }
    int result = run_profile(profile, profile_length, argv[2]);
    (void)memset(profile, 0, profile_length);
    free(profile);
    if (result != 0) {
        fprintf(stderr, "isolated profile core validation failed\n");
        return 1;
    }
    puts("isolated profile core validation passed");
    return 0;
}
