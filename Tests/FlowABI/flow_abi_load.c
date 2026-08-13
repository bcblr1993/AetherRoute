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
    return v3.engine_set_routing_mode != NULL ? 0 : 3;
}
