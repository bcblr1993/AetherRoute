#include "clashrs.h"

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum {
    MAXIMUM_PROFILE_BYTES = 10 * 1024 * 1024,
    CALLBACK_TIMEOUT_SECONDS = 30,
    MAXIMUM_RESPONSE_BYTES = 4096,
};

typedef struct callback_state {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    int complete;
    int32_t status;
    uint8_t bytes[MAXIMUM_RESPONSE_BYTES];
    size_t length;
    int32_t end_of_stream;
} callback_state_t;

static uint8_t *read_profile(const char *path, size_t *length) {
    FILE *file = fopen(path, "rb");
    if (file == NULL || fseek(file, 0, SEEK_END) != 0) {
        if (file != NULL) {
            (void)fclose(file);
        }
        return NULL;
    }
    long size = ftell(file);
    if (size <= 0 || size > MAXIMUM_PROFILE_BYTES ||
        fseek(file, 0, SEEK_SET) != 0) {
        (void)fclose(file);
        return NULL;
    }
    uint8_t *bytes = malloc((size_t)size + 1U);
    if (bytes == NULL ||
        fread(bytes, 1U, (size_t)size, file) != (size_t)size) {
        free(bytes);
        (void)fclose(file);
        return NULL;
    }
    (void)fclose(file);
    bytes[size] = 0;
    *length = (size_t)size;
    return bytes;
}

static void callback_state_init(callback_state_t *state) {
    (void)memset(state, 0, sizeof(*state));
    (void)pthread_mutex_init(&state->mutex, NULL);
    (void)pthread_cond_init(&state->condition, NULL);
}

static void callback_state_destroy(callback_state_t *state) {
    (void)pthread_cond_destroy(&state->condition);
    (void)pthread_mutex_destroy(&state->mutex);
}

static int callback_state_wait(callback_state_t *state) {
    struct timespec deadline;
    (void)clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += CALLBACK_TIMEOUT_SECONDS;
    int result = 0;
    (void)pthread_mutex_lock(&state->mutex);
    while (state->complete == 0 && result == 0) {
        result = pthread_cond_timedwait(
            &state->condition,
            &state->mutex,
            &deadline
        );
    }
    int complete = state->complete;
    (void)pthread_mutex_unlock(&state->mutex);
    return complete == 1 ? 0 : -1;
}

static void completion_callback(
    uint64_t token,
    int32_t status,
    void *context
) {
    (void)token;
    callback_state_t *state = context;
    (void)pthread_mutex_lock(&state->mutex);
    state->status = status;
    state->complete = 1;
    (void)pthread_cond_broadcast(&state->condition);
    (void)pthread_mutex_unlock(&state->mutex);
}

static void read_callback(
    uint64_t token,
    int32_t status,
    const uint8_t *data,
    size_t data_length,
    int32_t end_of_stream,
    void *context
) {
    (void)token;
    callback_state_t *state = context;
    (void)pthread_mutex_lock(&state->mutex);
    if (data != NULL && data_length <= sizeof(state->bytes)) {
        (void)memcpy(state->bytes, data, data_length);
        state->length = data_length;
    } else if (data_length != 0U) {
        status = CLASH_FLOW_TOO_LARGE;
    }
    state->status = status;
    state->end_of_stream = end_of_stream;
    state->complete = 1;
    (void)pthread_cond_broadcast(&state->condition);
    (void)pthread_mutex_unlock(&state->mutex);
}

static size_t make_domain_endpoint(
    uint8_t *endpoint,
    size_t capacity,
    const char *domain,
    uint16_t port
) {
    size_t domain_length = strlen(domain);
    size_t required = 11U + domain_length;
    if (domain_length == 0U || domain_length > UINT16_MAX ||
        required > capacity) {
        return 0;
    }
    endpoint[0] = 1U;
    endpoint[1] = 1U;
    endpoint[2] = 3U;
    endpoint[3] = (uint8_t)(port >> 8U);
    endpoint[4] = (uint8_t)(port & 0xffU);
    endpoint[5] = 0U;
    endpoint[6] = 0U;
    endpoint[7] = 0U;
    endpoint[8] = 0U;
    endpoint[9] = (uint8_t)(domain_length >> 8U);
    endpoint[10] = (uint8_t)(domain_length & 0xffU);
    (void)memcpy(endpoint + 11U, domain, domain_length);
    return required;
}

int main(int argc, char **argv) {
    static const char group_default[] = "";
    static const char member_default[] = "";
    static const char domain[] = "www.google.com";
    static const uint8_t request[] =
        "GET /generate_204 HTTP/1.1\r\n"
        "Host: www.google.com\r\n"
        "Connection: close\r\n\r\n";
    if (argc != 3 && argc != 5) {
        fprintf(
            stderr,
            "usage: external_flow_egress_runner PROFILE RUNTIME_DIR [GROUP MEMBER]\n"
        );
        return 64;
    }

    size_t profile_length = 0;
    uint8_t *profile = read_profile(argv[1], &profile_length);
    if (profile == NULL) {
        fprintf(stderr, "could not read bounded profile\n");
        return 66;
    }
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
        (const uint8_t *)argv[2],
        strlen(argv[2]),
        &options,
        &engine
    );
    (void)memset(profile, 0, profile_length);
    free(profile);
    if (status != CLASH_FLOW_OK || engine == NULL) {
        fprintf(stderr, "flow engine create status=%d\n", status);
        return 1;
    }

    const char *group = argc == 5 ? argv[3] : group_default;
    const char *member = argc == 5 ? argv[4] : member_default;
    if (argc == 5) {
        status = clash_flow_selector_select_v1(
            engine,
            (const uint8_t *)group,
            strlen(group),
            (const uint8_t *)member,
            strlen(member)
        );
        if (status != CLASH_FLOW_OK) {
            (void)clash_flow_engine_destroy(engine);
            fprintf(stderr, "selector update status=%d\n", status);
            return 2;
        }
    }

    uint8_t endpoint[256];
    size_t endpoint_length = make_domain_endpoint(
        endpoint,
        sizeof(endpoint),
        domain,
        80U
    );
    clash_flow_t *flow = NULL;
    status = clash_flow_tcp_create(
        engine,
        NULL,
        0,
        endpoint,
        endpoint_length,
        &flow
    );
    if (status != CLASH_FLOW_OK || flow == NULL ||
        clash_flow_activate(flow) != CLASH_FLOW_OK) {
        (void)clash_flow_engine_destroy(engine);
        fprintf(stderr, "flow activation failed\n");
        return 3;
    }

    callback_state_t write_state;
    callback_state_init(&write_state);
    status = clash_flow_tcp_write(
        flow,
        request,
        sizeof(request) - 1U,
        0U,
        completion_callback,
        &write_state
    );
    int write_ok = status == CLASH_FLOW_OK &&
        callback_state_wait(&write_state) == 0 &&
        write_state.status == CLASH_FLOW_OK;
    callback_state_destroy(&write_state);
    if (!write_ok) {
        (void)clash_flow_cancel(flow);
        (void)clash_flow_destroy(flow);
        (void)clash_flow_engine_destroy(engine);
        fprintf(stderr, "flow write failed\n");
        return 4;
    }

    callback_state_t read_state;
    callback_state_init(&read_state);
    status = clash_flow_tcp_read(
        flow,
        MAXIMUM_RESPONSE_BYTES,
        2U,
        read_callback,
        &read_state
    );
    int32_t read_admission_status = status;
    int read_wait_status = callback_state_wait(&read_state);
    int32_t read_callback_status = read_state.status;
    size_t read_length = read_state.length;
    int32_t read_end_of_stream = read_state.end_of_stream;
    int read_ok = read_admission_status == CLASH_FLOW_OK &&
        read_wait_status == 0 &&
        read_state.status == CLASH_FLOW_OK &&
        read_state.length >= 9U &&
        memcmp(read_state.bytes, "HTTP/1.", 7U) == 0;
    callback_state_destroy(&read_state);

    (void)clash_flow_cancel(flow);
    int destroy_flow = clash_flow_destroy(flow);
    int destroy_engine = clash_flow_engine_destroy(engine);
    if (!read_ok || destroy_flow != CLASH_FLOW_OK ||
        destroy_engine != CLASH_FLOW_OK) {
        fprintf(
            stderr,
            "flow read or shutdown failed admission=%d wait=%d callback=%d "
            "bytes=%zu eos=%d flow_destroy=%d engine_destroy=%d\n",
            read_admission_status,
            read_wait_status,
            read_callback_status,
            read_length,
            read_end_of_stream,
            destroy_flow,
            destroy_engine
        );
        return 5;
    }
    puts("FLOW_EGRESS_OK target=www.google.com:80 protocol=http");
    return 0;
}

