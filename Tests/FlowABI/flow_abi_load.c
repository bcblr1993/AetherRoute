#include "AetherRouteFlowABI.h"

int main(void) {
    aetherroute_flow_abi_v2_t v2 = {0};
    v2.struct_size = (uint32_t)sizeof(v2);
    if (aetherroute_flow_abi_load_v2(&v2) != 1) {
        return 1;
    }
    aetherroute_flow_abi_v3_t v3 = {0};
    v3.struct_size = (uint32_t)sizeof(v3);
    if (aetherroute_flow_abi_load_v3(&v3) != 1) {
        return 2;
    }
    if (v3.engine_set_routing_mode == NULL) {
        return 3;
    }
    aetherroute_flow_abi_v4_t v4 = {0};
    v4.struct_size = (uint32_t)sizeof(v4);
    if (aetherroute_flow_abi_load_v4(&v4) != 1) {
        return 4;
    }
    if (v4.selector_active_latency == NULL) {
        return 5;
    }
    aetherroute_flow_abi_v5_t v5 = {0};
    v5.struct_size = (uint32_t)sizeof(v5);
    if (aetherroute_flow_abi_load_v5(&v5) != 1) {
        return 6;
    }
    if (v5.v4.selector_active_latency == NULL
        || v5.tcp_create_v2 == NULL
        || v5.udp_create_v2 == NULL
        || v5.telemetry_snapshot_v2 == NULL) {
        return 7;
    }
    aetherroute_flow_abi_v6_t v6 = {0};
    v6.struct_size = (uint32_t)sizeof(v6);
    if (aetherroute_flow_abi_load_v6(&v6) != 1) {
        return 9;
    }
    if (v6.v5.telemetry_snapshot_v2 == NULL
        || v6.close_connections_v1 == NULL
        || v6.telemetry_snapshot_v3 == NULL) {
        return 10;
    }
    /* A caller built against a different table size is refused. */
    aetherroute_flow_abi_v5_t mismatched = {0};
    mismatched.struct_size = (uint32_t)sizeof(v4);
    if (aetherroute_flow_abi_load_v5(&mismatched) != 0) {
        return 8;
    }
    aetherroute_flow_abi_v6_t mismatched_v6 = {0};
    mismatched_v6.struct_size = (uint32_t)sizeof(v5);
    return aetherroute_flow_abi_load_v6(&mismatched_v6) == 0 ? 0 : 11;
}
