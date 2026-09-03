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
    return v4.selector_active_latency != NULL ? 0 : 5;
}
