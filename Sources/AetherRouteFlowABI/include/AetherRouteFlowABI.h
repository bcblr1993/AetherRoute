#ifndef AETHERROUTE_FLOW_ABI_H
#define AETHERROUTE_FLOW_ABI_H

#include <stddef.h>
#include <stdint.h>

#include "clashrs.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * A versioned function table keeps Swift isolated from raw symbol ownership.
 * Every build strongly force-loads the reviewed arm64 FlowOnly archive; a
 * missing function is therefore a link failure, never a runtime fallback.
 */
typedef struct aetherroute_flow_abi_v2 {
    uint32_t struct_size;

    int32_t (*engine_create)(
        const uint8_t *,
        size_t,
        const uint8_t *,
        size_t,
        const clash_flow_engine_options_v1_t *,
        void **
    );
    int32_t (*engine_destroy)(void *);
    int32_t (*selector_snapshot)(
        void *,
        const uint8_t *,
        size_t,
        uint8_t *,
        size_t,
        size_t *
    );
    int32_t (*selector_select)(
        void *,
        const uint8_t *,
        size_t,
        const uint8_t *,
        size_t
    );
    int32_t (*selector_latency)(
        void *,
        const uint8_t *,
        size_t,
        const uint8_t *,
        size_t,
        uint32_t,
        uint8_t *,
        size_t,
        size_t *
    );
    int32_t (*telemetry_snapshot)(
        void *,
        uint32_t,
        uint8_t *,
        size_t,
        size_t *
    );
    int32_t (*tcp_create)(
        void *,
        const uint8_t *,
        size_t,
        const uint8_t *,
        size_t,
        void **
    );
    int32_t (*udp_create)(void *, const uint8_t *, size_t, void **);
    int32_t (*activate)(void *);
    int32_t (*tcp_write)(
        void *,
        const uint8_t *,
        size_t,
        uint64_t,
        clash_flow_completion_t,
        void *
    );
    int32_t (*tcp_finish_write)(
        void *,
        uint64_t,
        clash_flow_completion_t,
        void *
    );
    int32_t (*tcp_read)(
        void *,
        size_t,
        uint64_t,
        clash_flow_tcp_read_completion_t,
        void *
    );
    int32_t (*udp_write)(
        void *,
        const clash_flow_datagram_v1_t *,
        size_t,
        uint64_t,
        clash_flow_completion_t,
        void *
    );
    int32_t (*udp_read)(
        void *,
        size_t,
        size_t,
        uint64_t,
        clash_flow_udp_read_completion_t,
        void *
    );
    int32_t (*cancel)(void *);
    int32_t (*destroy)(void *);
} aetherroute_flow_abi_v2_t;

/* Returns 1 only when the caller and the strongly linked table fit exactly. */
int32_t aetherroute_flow_abi_load_v2(aetherroute_flow_abi_v2_t *output);

typedef struct aetherroute_flow_abi_v3 {
    uint32_t struct_size;
    aetherroute_flow_abi_v2_t v2;
    int32_t (*engine_set_routing_mode)(void *, int32_t);
} aetherroute_flow_abi_v3_t;

/* V3 retains the complete V2 table and adds a per-engine routing override. */
int32_t aetherroute_flow_abi_load_v3(aetherroute_flow_abi_v3_t *output);

typedef struct aetherroute_flow_abi_v4 {
    uint32_t struct_size;
    aetherroute_flow_abi_v3_t v3;
    int32_t (*selector_active_latency)(
        void *,
        const uint8_t *,
        size_t,
        const uint8_t *,
        size_t,
        uint32_t,
        uint8_t *,
        size_t,
        size_t *
    );
} aetherroute_flow_abi_v4_t;

int32_t aetherroute_flow_abi_load_v4(aetherroute_flow_abi_v4_t *output);

#ifdef __cplusplus
}
#endif

#endif
