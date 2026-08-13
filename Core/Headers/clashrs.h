#ifndef AETHERROUTE_CLASHRS_H
#define AETHERROUTE_CLASHRS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*clash_packet_callback_t)(
    const uint8_t *packet,
    size_t length,
    uint8_t ip_version,
    void *context
);

/*
 * Flow-only ABI for NETransparentProxyProvider.
 *
 * Every accepted asynchronous operation invokes its completion exactly once.
 * Completion buffer pointers are borrowed only for the duration of the call.
 * A completion function and context must remain valid until it fires or the
 * corresponding destruction barrier returns.
 * clash_flow_destroy/clash_flow_engine_destroy are synchronization barriers:
 * after a successful return no related callback can execute. They deliberately
 * return INVALID_STATE when called inline from a completion callback. The host
 * must serialize either destroy call with new calls using the same raw handle;
 * clash_flow_cancel may race with accepted operations.
 */
typedef struct clash_flow_engine clash_flow_engine_t;
typedef struct clash_flow clash_flow_t;

enum {
    CLASH_FLOW_OK = 0,
    CLASH_FLOW_INVALID_ARGUMENT = 1,
    CLASH_FLOW_INVALID_PROFILE = 2,
    CLASH_FLOW_UNSUPPORTED_PROFILE = 3,
    CLASH_FLOW_INVALID_STATE = 4,
    CLASH_FLOW_BACKPRESSURE = 5,
    CLASH_FLOW_TOO_LARGE = 6,
    CLASH_FLOW_CLOSED = 7,
    CLASH_FLOW_CANCELLED = 8,
    CLASH_FLOW_STARTUP_FAILED = 9,
    CLASH_FLOW_INTERNAL_ERROR = 255
};

typedef struct clash_flow_engine_options_v1 {
    uint32_t struct_size;
    uint32_t worker_threads;
    uint32_t queue_depth;
    uint32_t maximum_tcp_chunk_bytes;
    uint32_t maximum_udp_payload_bytes;
} clash_flow_engine_options_v1_t;

typedef struct clash_flow_datagram_v1 {
    const uint8_t *payload;
    size_t payload_length;
    const uint8_t *remote_endpoint;
    size_t remote_endpoint_length;
} clash_flow_datagram_v1_t;

/*
 * Direct Packet Tunnel DNS policy. Every int32 field uses -1 to inherit the
 * validated profile value. resolution_mode additionally accepts 0 Normal,
 * 1 Fake-IP, and 2 Redir-host; the boolean fields accept 0 false and 1 true.
 * This bounded structure intentionally carries no endpoint or domain bytes.
 */
typedef struct clash_packet_dns_policy_v1 {
    uint32_t struct_size;
    int32_t resolution_mode;
    int32_t ipv6;
    int32_t respect_rules;
} clash_packet_dns_policy_v1_t;

/*
 * Optional host-controlled loopback listeners. Disabled settings must carry
 * zero ports. Enabled settings accept distinct ports 1024...65535 and the core
 * always binds 127.0.0.1 with allow-lan false after discarding profile values.
 */
typedef struct clash_packet_local_proxy_v1 {
    uint32_t struct_size;
    uint32_t enabled;
    uint32_t http_port;
    uint32_t socks_port;
} clash_packet_local_proxy_v1_t;

typedef void (*clash_flow_completion_t)(
    uint64_t token,
    int32_t status,
    void *context
);

typedef void (*clash_flow_tcp_read_completion_t)(
    uint64_t token,
    int32_t status,
    const uint8_t *data,
    size_t data_length,
    int32_t end_of_stream,
    void *context
);

typedef void (*clash_flow_udp_read_completion_t)(
    uint64_t token,
    int32_t status,
    const clash_flow_datagram_v1_t *datagrams,
    size_t datagram_count,
    int32_t end_of_stream,
    void *context
);

char *clash_start(
    const char *config,
    const char *log,
    const char *cwd,
    int32_t multithread
);
char *clash_start_packet_flow(
    const char *profile,
    const char *log,
    const char *cwd,
    int32_t mtu,
    int32_t multithread
);
char *clash_start_packet_flow_with_mode(
    const char *profile,
    const char *log,
    const char *cwd,
    int32_t mtu,
    int32_t routing_mode,
    int32_t multithread
);
char *clash_start_packet_flow_with_policy_v1(
    const char *profile,
    const char *log,
    const char *cwd,
    int32_t mtu,
    int32_t routing_mode,
    const clash_packet_dns_policy_v1_t *dns_policy,
    int32_t multithread
);
char *clash_start_packet_flow_with_policy_and_local_proxy_v1(
    const char *profile,
    const char *log,
    const char *cwd,
    int32_t mtu,
    int32_t routing_mode,
    const clash_packet_dns_policy_v1_t *dns_policy,
    const clash_packet_local_proxy_v1_t *local_proxy,
    int32_t multithread
);
int32_t clash_shutdown(void);
void clash_free_string(char *value);

int32_t clash_install_packet_flow(
    clash_packet_callback_t callback,
    void *context
);
int32_t clash_packet_input(const uint8_t *packet, size_t length);
int32_t clash_packet_flow_ready(void);
void clash_uninstall_packet_flow(void);

/*
 * Packet Tunnel selector control uses the same bounded ARS1 snapshot format
 * and generic CLASH_FLOW_* status values as the flow-only ABI below. Pass
 * NULL/0 for a size query. These symbols exist only in the Direct core.
 */
int32_t clash_packet_selector_snapshot_v1(
    const uint8_t *group,
    size_t group_length,
    uint8_t *output,
    size_t output_capacity,
    size_t *required_length
);
int32_t clash_packet_selector_select_v1(
    const uint8_t *group,
    size_t group_length,
    const uint8_t *member,
    size_t member_length
);
int32_t clash_packet_selector_latency_v1(
    const uint8_t *group,
    size_t group_length,
    const uint8_t *url,
    size_t url_length,
    uint32_t timeout_millis,
    uint8_t *output,
    size_t output_capacity,
    size_t *required_length
);
int32_t clash_packet_telemetry_snapshot_v1(
    uint32_t maximum_connections,
    uint8_t *output,
    size_t output_capacity,
    size_t *required_length
);

const char *clash_flow_status_message(int32_t status);
/* NULL options select 2 workers, queue depth 32, TCP 64 KiB, UDP 65507 bytes. */
int32_t clash_flow_engine_create(
    const uint8_t *profile,
    size_t profile_length,
    const uint8_t *cwd,
    size_t cwd_length,
    const clash_flow_engine_options_v1_t *options,
    clash_flow_engine_t **output
);
int32_t clash_flow_engine_set_routing_mode_v1(
    clash_flow_engine_t *engine,
    int32_t mode
);
int32_t clash_flow_engine_destroy(clash_flow_engine_t *engine);

/*
 * Selector snapshot v1 is a bounded binary value: ASCII `ARS1`, selected
 * index (u32 BE, UINT32_MAX for none), member count (u32 BE), then repeated
 * UTF-8 byte length (u32 BE) and member bytes. Pass NULL/0 to query the exact
 * required length. Group/member inputs are length-delimited UTF-8, at most
 * 1024 bytes, and must not contain NUL. Future flows observe a successful
 * selection immediately; existing flows keep their established outbound.
 */
int32_t clash_flow_selector_snapshot_v1(
    clash_flow_engine_t *engine,
    const uint8_t *group,
    size_t group_length,
    uint8_t *output,
    size_t output_capacity,
    size_t *required_length
);
int32_t clash_flow_selector_select_v1(
    clash_flow_engine_t *engine,
    const uint8_t *group,
    size_t group_length,
    const uint8_t *member,
    size_t member_length
);
int32_t clash_flow_selector_latency_v1(
    clash_flow_engine_t *engine,
    const uint8_t *group,
    size_t group_length,
    const uint8_t *url,
    size_t url_length,
    uint32_t timeout_millis,
    uint8_t *output,
    size_t output_capacity,
    size_t *required_length
);
/*
 * Telemetry snapshot v1 is ASCII `ART1`, five u64 BE counters (upload rate,
 * download rate, upload total, download total, memory), connection count, and
 * bounded active-connection records. It excludes source addresses, users,
 * resolved IPs, and internal UUIDs. Maximum connection count is 128.
 */
int32_t clash_flow_telemetry_snapshot_v1(
    clash_flow_engine_t *engine,
    uint32_t maximum_connections,
    uint8_t *output,
    size_t output_capacity,
    size_t *required_length
);

/*
 * Endpoint v1 is a strict byte string:
 * version, transport, host-kind, port (BE), IPv6 scope-id (u32 BE),
 * payload-length (u16 BE), payload. Transport is 1/TCP or 2/UDP; host-kind is
 * 1/IPv4, 2/IPv6, or 3/ASCII DNS. DNS input is canonicalized to lowercase with
 * one optional trailing dot removed before routing.
 */
int32_t clash_flow_tcp_create(
    clash_flow_engine_t *engine,
    const uint8_t *source_endpoint,
    size_t source_endpoint_length,
    const uint8_t *destination_endpoint,
    size_t destination_endpoint_length,
    clash_flow_t **output
);
int32_t clash_flow_udp_create(
    clash_flow_engine_t *engine,
    const uint8_t *source_endpoint,
    size_t source_endpoint_length,
    clash_flow_t **output
);
int32_t clash_flow_activate(clash_flow_t *flow);

int32_t clash_flow_tcp_write(
    clash_flow_t *flow,
    const uint8_t *data,
    size_t data_length,
    uint64_t token,
    clash_flow_completion_t completion,
    void *context
);
int32_t clash_flow_tcp_finish_write(
    clash_flow_t *flow,
    uint64_t token,
    clash_flow_completion_t completion,
    void *context
);
int32_t clash_flow_tcp_read(
    clash_flow_t *flow,
    size_t maximum_bytes,
    uint64_t token,
    clash_flow_tcp_read_completion_t completion,
    void *context
);

/* UDP batches are capped at 64 datagrams/1 MiB; a failed write is terminal. */
int32_t clash_flow_udp_write(
    clash_flow_t *flow,
    const clash_flow_datagram_v1_t *datagrams,
    size_t datagram_count,
    uint64_t token,
    clash_flow_completion_t completion,
    void *context
);
int32_t clash_flow_udp_read(
    clash_flow_t *flow,
    size_t maximum_datagrams,
    size_t maximum_bytes,
    uint64_t token,
    clash_flow_udp_read_completion_t completion,
    void *context
);

int32_t clash_flow_cancel(clash_flow_t *flow);
int32_t clash_flow_destroy(clash_flow_t *flow);

#ifdef __cplusplus
}
#endif

#endif
