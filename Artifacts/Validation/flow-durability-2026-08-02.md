# Flow durability evidence — 2026-08-02

- Status: passed
- Started: 2026-08-02T06:25:52Z
- Finished: 2026-08-02T06:46:27Z
- Rounds: 1,000
- Lifecycle cycles: 500,000
- Longest round: 2 seconds
- Peak RSS: 9,371,648 bytes
- RSS budget: 67,108,864 bytes
- Per-round timeout: 30 seconds
- Flow core SHA-256: `3b35d4b775736a5ddce85fdf2d29597f84432f6675f9f6c38d006ab95a7492f3`
- Harness SHA-256: `3c409844c5e2ab619482cd822da55dd786524c154b56aaa5240390c2cc12e03d`
- Network Extension: disabled
- System network settings: unchanged
- Runtime directory persistence: none

## Evidence digests

- `metadata.txt`: `13d50bac4ecb85866a9b268b80eb1c839c86c87ccebabafc8853a879f26901b9`
- `rounds.tsv`: `af077143db58f557b5f883b98998034422c6881abf5f88f16b27f251ca2e3223`
- `result.txt`: `5a62006dec21902034067ef73c48c426f933efa66e1b1491aee4ae3536346334`

An earlier run exposed a test-fixture race: its UDP echo socket closed immediately after three successful sends and one client read timed out. The fixture now holds the server socket for a 100 ms drain period without retrying the client or relaxing the 5-second callback deadline. A separate 500-process reproduction run had zero failures, followed by a clean 100-round gate and this clean 1,000-round durability gate.
