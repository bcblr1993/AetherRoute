#include "AetherRouteFlowABI.h"

#include <string.h>

extern int32_t clash_flow_engine_create(
    const uint8_t *,
    size_t,
    const uint8_t *,
    size_t,
    const clash_flow_engine_options_v1_t *,
    clash_flow_engine_t **
);
extern int32_t clash_flow_engine_destroy(
    clash_flow_engine_t *
);
extern int32_t clash_flow_selector_snapshot_v1(
    clash_flow_engine_t *,
    const uint8_t *,
    size_t,
    uint8_t *,
    size_t,
    size_t *
);
extern int32_t clash_flow_selector_select_v1(
    clash_flow_engine_t *,
    const uint8_t *,
    size_t,
    const uint8_t *,
    size_t
);
extern int32_t clash_flow_selector_latency_v1(
    clash_flow_engine_t *,
    const uint8_t *,
    size_t,
    const uint8_t *,
    size_t,
    uint32_t,
    uint8_t *,
    size_t,
    size_t *
);
extern int32_t clash_flow_telemetry_snapshot_v1(
    clash_flow_engine_t *,
    uint32_t,
    uint8_t *,
    size_t,
    size_t *
);
extern int32_t clash_flow_tcp_create(
    clash_flow_engine_t *,
    const uint8_t *,
    size_t,
    const uint8_t *,
    size_t,
    clash_flow_t **
);
extern int32_t clash_flow_udp_create(
    clash_flow_engine_t *,
    const uint8_t *,
    size_t,
    clash_flow_t **
);
extern int32_t clash_flow_activate(clash_flow_t *);
extern int32_t clash_flow_tcp_write(
    clash_flow_t *,
    const uint8_t *,
    size_t,
    uint64_t,
    clash_flow_completion_t,
    void *
);
extern int32_t clash_flow_tcp_finish_write(
    clash_flow_t *,
    uint64_t,
    clash_flow_completion_t,
    void *
);
extern int32_t clash_flow_tcp_read(
    clash_flow_t *,
    size_t,
    uint64_t,
    clash_flow_tcp_read_completion_t,
    void *
);
extern int32_t clash_flow_udp_write(
    clash_flow_t *,
    const clash_flow_datagram_v1_t *,
    size_t,
    uint64_t,
    clash_flow_completion_t,
    void *
);
extern int32_t clash_flow_udp_read(
    clash_flow_t *,
    size_t,
    size_t,
    uint64_t,
    clash_flow_udp_read_completion_t,
    void *
);
extern int32_t clash_flow_cancel(clash_flow_t *);
extern int32_t clash_flow_destroy(clash_flow_t *);

static int32_t engine_create_adapter(
    const uint8_t *profile,
    size_t profile_length,
    const uint8_t *cwd,
    size_t cwd_length,
    const clash_flow_engine_options_v1_t *options,
    void **output
) {
    return clash_flow_engine_create(
        profile,
        profile_length,
        cwd,
        cwd_length,
        options,
        (clash_flow_engine_t **)output
    );
}

static int32_t engine_destroy_adapter(void *engine) {
    return clash_flow_engine_destroy((clash_flow_engine_t *)engine);
}

static int32_t selector_snapshot_adapter(
    void *engine,
    const uint8_t *group,
    size_t group_length,
    uint8_t *output,
    size_t output_capacity,
    size_t *required_length
) {
    return clash_flow_selector_snapshot_v1(
        (clash_flow_engine_t *)engine,
        group,
        group_length,
        output,
        output_capacity,
        required_length
    );
}

static int32_t selector_select_adapter(
    void *engine,
    const uint8_t *group,
    size_t group_length,
    const uint8_t *member,
    size_t member_length
) {
    return clash_flow_selector_select_v1(
        (clash_flow_engine_t *)engine,
        group,
        group_length,
        member,
        member_length
    );
}

static int32_t selector_latency_adapter(
    void *engine,
    const uint8_t *group,
    size_t group_length,
    const uint8_t *url,
    size_t url_length,
    uint32_t timeout_millis,
    uint8_t *output,
    size_t output_capacity,
    size_t *required_length
) {
    return clash_flow_selector_latency_v1(
        (clash_flow_engine_t *)engine,
        group,
        group_length,
        url,
        url_length,
        timeout_millis,
        output,
        output_capacity,
        required_length
    );
}

static int32_t telemetry_snapshot_adapter(
    void *engine,
    uint32_t maximum_connections,
    uint8_t *output,
    size_t output_capacity,
    size_t *required_length
) {
    return clash_flow_telemetry_snapshot_v1(
        (clash_flow_engine_t *)engine,
        maximum_connections,
        output,
        output_capacity,
        required_length
    );
}

static int32_t tcp_create_adapter(
    void *engine,
    const uint8_t *source,
    size_t source_length,
    const uint8_t *destination,
    size_t destination_length,
    void **output
) {
    return clash_flow_tcp_create(
        (clash_flow_engine_t *)engine,
        source,
        source_length,
        destination,
        destination_length,
        (clash_flow_t **)output
    );
}

static int32_t udp_create_adapter(
    void *engine,
    const uint8_t *source,
    size_t source_length,
    void **output
) {
    return clash_flow_udp_create(
        (clash_flow_engine_t *)engine,
        source,
        source_length,
        (clash_flow_t **)output
    );
}

static int32_t activate_adapter(void *flow) {
    return clash_flow_activate((clash_flow_t *)flow);
}

static int32_t tcp_write_adapter(
    void *flow,
    const uint8_t *data,
    size_t length,
    uint64_t token,
    clash_flow_completion_t completion,
    void *context
) {
    return clash_flow_tcp_write(
        (clash_flow_t *)flow,
        data,
        length,
        token,
        completion,
        context
    );
}

static int32_t tcp_finish_write_adapter(
    void *flow,
    uint64_t token,
    clash_flow_completion_t completion,
    void *context
) {
    return clash_flow_tcp_finish_write(
        (clash_flow_t *)flow,
        token,
        completion,
        context
    );
}

static int32_t tcp_read_adapter(
    void *flow,
    size_t maximum_bytes,
    uint64_t token,
    clash_flow_tcp_read_completion_t completion,
    void *context
) {
    return clash_flow_tcp_read(
        (clash_flow_t *)flow,
        maximum_bytes,
        token,
        completion,
        context
    );
}

static int32_t udp_write_adapter(
    void *flow,
    const clash_flow_datagram_v1_t *datagrams,
    size_t count,
    uint64_t token,
    clash_flow_completion_t completion,
    void *context
) {
    return clash_flow_udp_write(
        (clash_flow_t *)flow,
        datagrams,
        count,
        token,
        completion,
        context
    );
}

static int32_t udp_read_adapter(
    void *flow,
    size_t maximum_datagrams,
    size_t maximum_bytes,
    uint64_t token,
    clash_flow_udp_read_completion_t completion,
    void *context
) {
    return clash_flow_udp_read(
        (clash_flow_t *)flow,
        maximum_datagrams,
        maximum_bytes,
        token,
        completion,
        context
    );
}

static int32_t cancel_adapter(void *flow) {
    return clash_flow_cancel((clash_flow_t *)flow);
}

static int32_t destroy_adapter(void *flow) {
    return clash_flow_destroy((clash_flow_t *)flow);
}

int32_t aetherroute_flow_abi_load_v2(aetherroute_flow_abi_v2_t *output) {
    if (output == NULL || output->struct_size != sizeof(*output)) {
        return 0;
    }
    const uint32_t struct_size = output->struct_size;
    memset(output, 0, sizeof(*output));
    output->struct_size = struct_size;
    output->engine_create = engine_create_adapter;
    output->engine_destroy = engine_destroy_adapter;
    output->selector_snapshot = selector_snapshot_adapter;
    output->selector_select = selector_select_adapter;
    output->selector_latency = selector_latency_adapter;
    output->telemetry_snapshot = telemetry_snapshot_adapter;
    output->tcp_create = tcp_create_adapter;
    output->udp_create = udp_create_adapter;
    output->activate = activate_adapter;
    output->tcp_write = tcp_write_adapter;
    output->tcp_finish_write = tcp_finish_write_adapter;
    output->tcp_read = tcp_read_adapter;
    output->udp_write = udp_write_adapter;
    output->udp_read = udp_read_adapter;
    output->cancel = cancel_adapter;
    output->destroy = destroy_adapter;
    return 1;
}
