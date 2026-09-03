# VM protocol integration fixtures

These profiles exercise the exact VMess, Hysteria2, and VLESS REALITY/Vision
surfaces used by the cached x2cloud subscription. They contain only fixed test
credentials. VMess and Hysteria2 stay on loopback; the VLESS REALITY server is
bound only to the Tart VM's private NAT address because a Packet Tunnel system
extension cannot reliably reach a host loopback listener.

The VLESS fixture deliberately omits `network` and requests the `safari` client
fingerprint, matching the current x2cloud field shape. The server-side test
harness must remain bound to the private VM interface and route its egress
through a separately audited, temporary canary proxy when the VM cannot reach
the public canary directly.

`manual-pinned.yaml` pins the rule route to a deliberately unavailable first
member and proves that manual mode does not fall back. `automatic-failover.yaml`
uses the same unavailable member plus the working VMess fixture in a `url-test`
group and proves that automatic mode selects a responsive route.

`explicit-automatic-failover.yaml` and `manual-pinned-host.yaml` bind the two
fixed VMess fixtures on the Tart host-only NAT interface. The former exercises
the user-facing automatic toggle on a two-member `select` group: every
provider-responsive candidate must also pass a fresh Google 204 data-plane
probe before the lowest-latency successful candidate is committed. The latter
uses the same routes with automatic mode disabled; stopping the pinned fixture
must produce a visible connection failure without selecting its sibling.

`explicit-automatic-one-unavailable.yaml` and
`manual-pinned-unavailable.yaml` provide the deterministic companion case:
the first member targets an intentionally closed port while the second member
uses the verified Fixture B listener. Automatic mode must commit Fixture B;
manual mode pinned to the unavailable member must fail visibly and must never
select Fixture B.
