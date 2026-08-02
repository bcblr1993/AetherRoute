#include "AetherRouteFlowABI.h"

int main(void) {
    aetherroute_flow_abi_v2_t table = {0};
    table.struct_size = (uint32_t)sizeof(table);
    return aetherroute_flow_abi_load_v2(&table) == 1 ? 0 : 1;
}
