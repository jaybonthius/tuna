# Tuna Stage-2 full benchmark report

## Status

The full `stage2` profile completed successfully and the retained raw artifact
reports `approvalEligible: true`. Repository-owner approval is recorded as
approved. The eligibility bit is a runner result, not approval.

The owner accepts this Stage-2 benchmark report and its recorded controls. For
buffer integration, the accepted private configuration is SumTree node capacity
`B=32`, text chunk capacity `C=1024` bytes, no automatic threshold-based
compaction, and an explicit full serialize/rebuild maintenance operation when
compaction is requested. This is a Stage-3 integration policy, not a claim of
global optimality or benchmark tuning.

## Artifact, command, and revalidation

Exact benchmark command:

```console
racket sum-tree-bench/sum-tree/run.rkt --seed 20260714 --output .state/sum-tree-benchmark.json
```

The command exited 0 once, with no retry. The artifact was not regenerated or
modified while preparing this report. The reviewed runner's read-only
`read-benchmark-report` validator was run again against the retained file and
accepted its exact Stage-2 schedule and row identities.

| Field | Value |
| --- | --- |
| Raw artifact | `.state/sum-tree-benchmark.json` |
| Raw SHA-256 | `d376a07cfd43a0cbd7c1f8ad2d061f9e1d8adad3a0daf70deedbce027257b986` |
| Staged plan blob | `4ebf2042abe42894cc8980a7d6e0df5c2c40b3d9` (`docs/plans/sum-tree-buffer-plan.md`) |
| Schema / version | `sum-tree-stage2-benchmark` / `2` |
| Internal digest algorithm | `sha1` |
| Profile / status | `stage2` / `complete` |
| Seed | `20260714` |
| Approval eligible | `true` |
| Incomplete reason | JSON `null` |
| Policy budget metadata | `900` seconds |
| Total elapsed | `945293.315042` ms (945.293315042 s) |
| Ordered timed rows | 31, all class `characterization` |
| Per row | 2 warmups, 20 measured samples, policy `timed` |
| Totals | 62 warmups, 620 measured samples |

The global elapsed time includes preparation, process startup, GC, validation,
and untimed structural replays in addition to operation timing. It is not a
620-sample sum or an operation-latency statistic.

## Machine and Racket CS runtime

All 31 rows carry identical host and runtime metadata.

| Field | Raw value |
| --- | --- |
| OS / architecture | `unix` / `x86_64` |
| Machine type | `Linux tungo 6.8.0-47-generic #47-Ubuntu SMP PREEMPT_DYNAMIC Fri Sep 27 21:40:26 UTC 2024 x86_64` |
| Hostname | JSON `null` |
| Racket / family | `9.2` / `racket-cs` |
| VM / GC | `chez-scheme` / `cs` |
| Allocation availability | `available`; unavailable reason JSON `null` |
| Live-memory kind | `post-major-gc-live-memory` |
| Peak-memory kind | `sampled-workload-process-memory` |

Cumulative allocation is the per-sample allocation delta. Live memory is read
after a runner-forced major collection. Peak memory is sampled workload-process
memory, not a continuously observed operating-system high-water mark.

## Workload inventory and result sinks

All rows use `canonical-corpus-and-trace-before-timing`, a fresh process per
row, `runner-major-before-and-after-sample`, and
`canonical-result-barrier-after-timing`. The canonical validation barrier makes
each result observable after timing. The schedule and sinks were:

| # | Workload and full scale | Canonical schedule and timed result sink |
| --: | --- | --- |
| 1–3 | Build/scan/slice/serialize at 1, 10, 100 MiB | Build bounded chunks, scan checksum/lengths/lines, slice the middle half, serialize; sink the length/checksum/coordinate lengths/line count/slice observation. |
| 4–5 | Local insert/backspace at 1 and 10 MiB | 10,000 deterministic cursor positions, each a one-byte insert then delete: 20,000 timed edits; sink and validate restored text. |
| 6–9 | Distributed batch at 10 MiB, 10/100/1,000/10,000 input edits | Simultaneous one-byte insertions at distributed old-snapshot coordinates through one batch; sink final text and change set. |
| 10 | Alternating document ends at 10 MiB | 10,000 alternating-end insert/delete pairs, 20,000 edits; sink final text. |
| 11 | Large paste | Insert 10 MiB at the midpoint of a 1 MiB text; sink final text. |
| 12 | Large delete | Delete `[25 MiB,75 MiB)` from a 100 MiB text; sink final text. |
| 13–14 | Replace-all at 10 MiB | Simultaneous one-byte replacements at 1,000 and 100,000 distributed old-snapshot positions; sink final text and change set. |
| 15 | Coordinate conversions at 10 MiB | 10,000 deterministic byte offsets; each contributes byte→char, byte→UTF-16, byte→line, and byte→position/line to a checksum; sink checksum and text. |
| 16–17 | Line-shape cases at 10 MiB | One multi-mebibyte single line and millions of two-byte short lines; sink line, character, and UTF-16 totals. Raw `operationCount` is 0 because these shape observations have no trace-list operations, although the observation itself is timed. |
| 18–19 | Retained roots at 10 MiB | 1,000 and 10,000 distributed one-byte replacements, retaining every previous root; sink retained population and final text. |
| 20–21 | Retained slices at 10 MiB | Retain 1,000 and 10,000 distributed slices of at most 1,024 bytes; sink retained population and original text. |
| 22–23 | Retained cursors at 10 MiB | Retain 1,000 and 10,000 root-local cursors distributed over chunk indexes; sink retained population and original text. |
| 24 | Sparse/slack/compaction at 10 MiB | Run the same 10,000 local insert/delete pairs as row 5, serialize, then rebuild; retain the edited root and sink the rebuilt text. |
| 25–26 | Generic descriptor / identical hard-coded summary | Extract the same immutable 1 MiB tree topology and reduce it once through descriptor procedures or direct text-summary procedures; sink identical summary fields and 2,080 callback invocations. |
| 27 | Flat immutable UTF-8 bytes | Same 1 MiB build/scan/slice/serialize corpus, trace, barrier, and sink as row 1. |
| 28 | Flat immutable string | Same 1 MiB build/scan/slice/serialize corpus, trace, barrier, and sink as row 1. |
| 29 | Bounded/indexed immutable pieces | Same 1 MiB build/scan/slice/serialize corpus, trace, barrier, and sink as row 1; 1,024-byte pieces with 64-byte indexes. |
| 30 | Mutable gap edit | Same 1 MiB 10,000 insert/backspace pairs as row 4; movement is measured separately in structural replay; sink restored bytes. No snapshot copy is in the timed edit metric. |
| 31 | Mutable gap snapshot copy | Prepare the same 20,000 edits before timing, then time one immutable 1 MiB snapshot copy; sink restored bytes. This is not part of row 30. |

Rows 6–9 and 13–14 are simultaneous batch semantics: all coordinates refer to
the old snapshot. They are not a loop whose later coordinates observe earlier
mutations.

## Canonical identity and comparability

The next table is an exact row-order transcription of the canonical identities.
`Scale / snapshot` is bytes / raw `snapshotPopulation`. Corpus, replay, and
validation digests are SHA-1 because that is the artifact's declared internal
algorithm; SHA-256 above protects the artifact file itself.

| # | Workload ID | Corpus SHA-1 | Replay SHA-1 | Validation SHA-1 | Scale / snapshot | Barrier |
|--:|---|---|---|---|---:|---|
| 1 | `text/build-scan-slice-serialize/1048576/e0/r0` | `7d378cb8be2adc8a26031d77cf4139bbfcc98b7e` | `d30ecfba06bd12fa08e9a15fc5cc854626cd67df` | `310f9c622fbf423f83322f571b5899a5fc101a9a` | 1048576 / 0 | `bytes-length-checksum-slice-serialize-v1` |
| 2 | `text/build-scan-slice-serialize/10485760/e0/r0` | `beebfc9cd54c9412e7db3bb894ed0c241dfa8df3` | `26802af2d8537cadda864b17fbca262f1d13fbe4` | `45c11b36045e3dd625d59e7beca7f04f58b26d17` | 10485760 / 0 | `bytes-length-checksum-slice-serialize-v1` |
| 3 | `text/build-scan-slice-serialize/104857600/e0/r0` | `fba0a6a49d8579ef694ef649298f5c75c6b2318a` | `9b9390c07e4c5344bece0f73665fda454fafb92c` | `7cc4085453e2a09d26f0e44d3c0fcf7fc6e34411` | 104857600 / 0 | `bytes-length-checksum-slice-serialize-v1` |
| 4 | `text/local-insert-backspace/1048576/e0/r0` | `7d378cb8be2adc8a26031d77cf4139bbfcc98b7e` | `a1e07292ba843bb0ee7fe3dae8eb6716fb024963` | `0471eb1c2b13e89dd3a67edae846ecf2608582d1` | 1048576 / 0 | `restored-bytes-checksum-v1` |
| 5 | `text/local-insert-backspace/10485760/e0/r0` | `beebfc9cd54c9412e7db3bb894ed0c241dfa8df3` | `de61695a33d4bd656c66a594ca042b7ffa3acb81` | `5de132d6a8bb349df181b6929ab547d43dfc85af` | 10485760 / 0 | `restored-bytes-checksum-v1` |
| 6 | `text/distributed-batch/10485760/e10/r0` | `beebfc9cd54c9412e7db3bb894ed0c241dfa8df3` | `84aa3adb81376ef44919a39a56297913b5e6f4c0` | `8e059ccbbe385bc2761d47381e189cd89ab822ad` | 10485760 / 0 | `text-result-string-and-lengths-v1` |
| 7 | `text/distributed-batch/10485760/e100/r0` | `beebfc9cd54c9412e7db3bb894ed0c241dfa8df3` | `344b7e78879eb4d23311bbf876635365abb4c3d9` | `3de637b7ae62424eb29998dbae54ad6d7ea8cd2c` | 10485760 / 0 | `text-result-string-and-lengths-v1` |
| 8 | `text/distributed-batch/10485760/e1000/r0` | `beebfc9cd54c9412e7db3bb894ed0c241dfa8df3` | `da1e813bd29d1018f789cf66c19f40292a4c2f90` | `f6861b2cdb566cdc4840e03c4c769a92ccb3ec8c` | 10485760 / 0 | `text-result-string-and-lengths-v1` |
| 9 | `text/distributed-batch/10485760/e10000/r0` | `beebfc9cd54c9412e7db3bb894ed0c241dfa8df3` | `54133bab12cc99ed4e0d22a2e3590c817f0e6f66` | `442204eaf6ecbba5e37880271042d1f22a805a37` | 10485760 / 0 | `text-result-string-and-lengths-v1` |
| 10 | `text/alternating-document-ends/10485760/e0/r0` | `beebfc9cd54c9412e7db3bb894ed0c241dfa8df3` | `2d35f763e7b4cef76249e8bc197c9432ebac4541` | `710566547e96fce35d0a61cfa21340a8c8648841` | 10485760 / 0 | `text-result-string-and-lengths-v1` |
| 11 | `text/large-paste/1048576/e0/r0` | `7d378cb8be2adc8a26031d77cf4139bbfcc98b7e` | `c40836845a33074452ccecb9c3db49ea19c1e945` | `ece42d9d69c2a42a707cae4bcd8dcbde0f6deda1` | 1048576 / 0 | `text-result-string-and-lengths-v1` |
| 12 | `text/large-delete/104857600/e0/r0` | `fba0a6a49d8579ef694ef649298f5c75c6b2318a` | `21ac7da00ee11be77a69f2bd9df03b6ec0790b29` | `631c6a179f5772fb7468f0bfdabee54eca7b840f` | 104857600 / 0 | `text-result-string-and-lengths-v1` |
| 13 | `text/replace-all/10485760/e1000/r0` | `beebfc9cd54c9412e7db3bb894ed0c241dfa8df3` | `8c614f0732235390ae44763f885d090795a0d6fa` | `a198c2bab22cca43052120552e2a886c1d49a02a` | 10485760 / 0 | `text-result-string-and-lengths-v1` |
| 14 | `text/replace-all/10485760/e100000/r0` | `beebfc9cd54c9412e7db3bb894ed0c241dfa8df3` | `ac9f37cadc6c1cf8a9523eeac54ae61e5687350e` | `0bfee58b41823e2a7ef1118e3656a1d1b9f7182e` | 10485760 / 0 | `text-result-string-and-lengths-v1` |
| 15 | `text/coordinate-conversions/10485760/e0/r0` | `beebfc9cd54c9412e7db3bb894ed0c241dfa8df3` | `ac626b428397fe1bcccfbc06208d1091ff2e2265` | `4ad8cd0e8c33b289e102ab2c1036333e2f4c2bb2` | 10485760 / 0 | `text-result-string-and-lengths-v1` |
| 16 | `text/multi-mebibyte-single-line/10485760/e0/r0` | `2a52af65e8f164f44517c94332c3f58670ba2bb5` | `4b28eb9b9ff741f422261c05a6f231a127e0437d` | `7bb911186be5232f11f41094e74685d0db29a9db` | 10485760 / 0 | `text-result-string-and-lengths-v1` |
| 17 | `text/millions-short-lines/10485760/e0/r0` | `b96a42023e50f95e471eb2833b4ecf573a2d26ee` | `4b28eb9b9ff741f422261c05a6f231a127e0437d` | `e01ce2946fa52c2b975982d85209a103d0dd18d7` | 10485760 / 0 | `text-result-string-and-lengths-v1` |
| 18 | `text/retained-roots/10485760/e0/r1000` | `beebfc9cd54c9412e7db3bb894ed0c241dfa8df3` | `358d023506dfef9b52e7f9049cc98dfecd7eb1f3` | `ae7b2d21854c1cbcd5459b190f56daf2058a06f1` | 10485760 / 1000 | `text-result-string-and-lengths-v1` |
| 19 | `text/retained-roots/10485760/e0/r10000` | `beebfc9cd54c9412e7db3bb894ed0c241dfa8df3` | `9506865cb237b09547fa71f73acf29944c6fd4c1` | `e12d082c5181b4fc4c7b563d07054b9937c215c7` | 10485760 / 10000 | `text-result-string-and-lengths-v1` |
| 20 | `text/retained-slices/10485760/e0/r1000` | `beebfc9cd54c9412e7db3bb894ed0c241dfa8df3` | `f26b343eb719c8bb0aa3b4fccf2861304024929f` | `409cd3448d254a67729b0f6894016740b864011f` | 10485760 / 1000 | `text-result-string-and-lengths-v1` |
| 21 | `text/retained-slices/10485760/e0/r10000` | `beebfc9cd54c9412e7db3bb894ed0c241dfa8df3` | `9e3f3251678d42e2be90052e616f44dc2929080e` | `e99f144eca5df50744bb6ec83d52345bab98667f` | 10485760 / 10000 | `text-result-string-and-lengths-v1` |
| 22 | `text/retained-cursors/10485760/e0/r1000` | `beebfc9cd54c9412e7db3bb894ed0c241dfa8df3` | `2c31cb1dd04f6daaaf4328890ca0e6dac2fb5d6d` | `bd77b1425992c3af0367ee0c328c80590d894e10` | 10485760 / 1000 | `text-result-string-and-lengths-v1` |
| 23 | `text/retained-cursors/10485760/e0/r10000` | `beebfc9cd54c9412e7db3bb894ed0c241dfa8df3` | `1c36c4d38870fa52c710a267f5ad563ad3a12954` | `64582ae3d2293aec9f05783625077827fc1304cc` | 10485760 / 10000 | `text-result-string-and-lengths-v1` |
| 24 | `text/sparse-slack-compaction/10485760/e0/r0` | `beebfc9cd54c9412e7db3bb894ed0c241dfa8df3` | `de61695a33d4bd656c66a594ca042b7ffa3acb81` | `6d0ca6d157d8121eae180d61619cd2a4d4b49eb8` | 10485760 / 0 | `text-result-string-and-lengths-v1` |
| 25 | `text/summary-callback/generic/1048576` | `7d378cb8be2adc8a26031d77cf4139bbfcc98b7e` | `ae8002f4f25e30496d149272ab397409e6ea4a8e` | `581b6e5756386c4f4a9a97d21b70516ef762d3ce` | 1048576 / 0 | `text-summary-fields-v1` |
| 26 | `text/summary-callback/hard-coded/1048576` | `7d378cb8be2adc8a26031d77cf4139bbfcc98b7e` | `ae8002f4f25e30496d149272ab397409e6ea4a8e` | `581b6e5756386c4f4a9a97d21b70516ef762d3ce` | 1048576 / 0 | `text-summary-fields-v1` |
| 27 | `text/control/flat-bytes/build/1048576` | `7d378cb8be2adc8a26031d77cf4139bbfcc98b7e` | `d30ecfba06bd12fa08e9a15fc5cc854626cd67df` | `310f9c622fbf423f83322f571b5899a5fc101a9a` | 1048576 / 0 | `bytes-length-checksum-slice-serialize-v1` |
| 28 | `text/control/flat-string/build/1048576` | `7d378cb8be2adc8a26031d77cf4139bbfcc98b7e` | `d30ecfba06bd12fa08e9a15fc5cc854626cd67df` | `310f9c622fbf423f83322f571b5899a5fc101a9a` | 1048576 / 0 | `bytes-length-checksum-slice-serialize-v1` |
| 29 | `text/control/bounded-indexed-piece/build/1048576` | `7d378cb8be2adc8a26031d77cf4139bbfcc98b7e` | `d30ecfba06bd12fa08e9a15fc5cc854626cd67df` | `310f9c622fbf423f83322f571b5899a5fc101a9a` | 1048576 / 0 | `bytes-length-checksum-slice-serialize-v1` |
| 30 | `text/control/mutable-gap-buffer/edit/1048576` | `7d378cb8be2adc8a26031d77cf4139bbfcc98b7e` | `a1e07292ba843bb0ee7fe3dae8eb6716fb024963` | `0471eb1c2b13e89dd3a67edae846ecf2608582d1` | 1048576 / 0 | `restored-bytes-checksum-v1` |
| 31 | `text/control/mutable-gap-buffer/snapshot-copy/1048576` | `7d378cb8be2adc8a26031d77cf4139bbfcc98b7e` | `10a43f656868c0ebc9d67285ef9168d7b4bf5ea9` | `1d8d4f030fa52a28d1efc1f2f8a45cdfc1965c2d` | 1048576 / 1048576 | `restored-bytes-checksum-v1` |

Only rows with matching corpus hash, replay hash, scale, barrier, seed,
snapshot population, schedule, and sink are treated as comparable:

- Rows 1 and 27–29 are the matched 1 MiB build/scan/slice/serialize set.
  The bounded-chunk wall median was 10.984× flat immutable bytes, 1.731×
  flat immutable string, and 0.776× bounded/indexed immutable pieces. These
  are whole-probe ratios, not isolated build costs.
- Rows 4 and 30 are the matched local-edit schedule. The bounded-chunk median
  was 680.286× the mutable-gap edit median. The gap control is mutable and does
  not provide persistent snapshots, so this is a trace comparison, not an
  equal-persistence comparison.
- Row 31 has a different replay and a 1,048,576-byte snapshot population. Its
  median snapshot-copy time was 5.174919 ms and its structural replay copied
  exactly 1,048,576 snapshot bytes. No SumTree snapshot-copy row exists, so no
  snapshot-copy ratio is claimed.
- Rows 25 and 26 match on every comparison key and actual immutable topology.
  The generic median was 0.975× the hard-coded median. The overlapping tails
  (generic p95/p99 0.090753/0.108287 ms; hard-coded
  0.101093/0.117795 ms) do not show a descriptor-dispatch penalty on this run.
  Generic-callback conclusions apply only to this identical comparison.

The gap edit replay reports `movementCopiedBytes=157696065`. That is movement
while replaying the edit schedule, not snapshot copying. The separate snapshot
row reports `snapshotCopiedBytes=1048576` and does not report movement. Their
costs and identities must remain separate.

## Statistics and raw-sample trace

For every row and metric below, `m/p95/p99` is computed directly and
independently from that row's ordered 20-object `rawSamples` array in
`.state/sum-tree-benchmark.json`. The median is the arithmetic mean of sorted
positions 10 and 11. p95 is deterministic nearest-rank position
`ceil(0.95×20)=19`; p99 is position `ceil(0.99×20)=20`, therefore the observed
maximum. No interpolation is used. The recomputed wall medians equal the stored
wall medians exactly; p95 and p99 are not stored fields and were derived by this
method.

`Wall source samples m/p95/p99` gives the 1-based raw-sample ordinals supplying
positions 10+11, 19, and 20 after sorting. CPU, allocation, GC, live, and peak
triples use the same deterministic statistic on their named raw fields, sorted
independently. Values in byte columns are exact bytes; displayed millisecond statistics are rounded to six decimal places.

| # | Wall ms m/p95/p99 | CPU ms m/p95/p99 | Allocation B m/p95/p99 | GC ms m/p95/p99 | Live B m/p95/p99 | Peak B m/p95/p99 | Wall source samples m/p95/p99 |
|--:|---:|---:|---:|---:|---:|---:|---|
| 1 | 18.771785/21.543259/21.8367 | 19/22/22 | 22720272/22785952/22786016 | 2/2/2 | 89286656/89314992/89317632 | 107499432/107530640/107532688 | 16+7/19/10 |
| 2 | 243.652855/267.021445/272.168995 | 243/267/272 | 215121080/215153824/215153888 | 65/75/79 | 100284808/100305024/100307488 | 187310512/187332272/187334720 | 11+9/12/20 |
| 3 | 2508.150668/2514.69404/2526.641804 | 2507.5/2515/2527 | 2050694976/2050761408/2050762160 | 642/651/659 | 209817528/209829824/209830096 | 942967296/943007120/943009712 | 3+19/14/6 |
| 4 | 2015.258889/2035.187916/2035.215057 | 2014.5/2035/2035 | 4587055912/4587063120/4587063152 | 39/40/40 | 91049912/91067312/91067664 | 105262192/105326144/105326384 | 18+6/14/16 |
| 5 | 3260.227388/3288.623652/3300.412146 | 3259.5/3288/3300 | 7876319920/7876323760/7876333232 | 54/56/56 | 102783776/102813248/102813392 | 163795976/164317136/164317472 | 14+15/11/1 |
| 6 | 0.297619/0.317207/0.317296 | 0/1/1 | 488064/488064/488064 | 0/0/0 | 100162352/100188368/100191344 | 142589312/142615040/142618112 | 20+7/1/14 |
| 7 | 6.690186/6.905242/7.286722 | 7/7/7 | 10515984/10581888/10581920 | 0/1/1 | 100211400/100240496/100242816 | 144182592/144268640/144273056 | 10+19/4/17 |
| 8 | 49.453836/51.689055/52.181967 | 49.5/52/52 | 67614592/67684320/67686048 | 2/2/2 | 100661656/100680256/100680736 | 144559488/144640656/144642176 | 1+11/8/7 |
| 9 | 301.810091/304.089379/305.767447 | 302/304/306 | 204442112/204498944/204498944 | 11/11/12 | 105323592/105346944/105347504 | 165870696/166017136/166017696 | 20+16/2/11 |
| 10 | 818.040878/827.997279/828.01314 | 818/828/828 | 2215729920/2215742592/2215743424 | 9/9/9 | 101576480/101580416/101580640 | 150157728/150205056/150207840 | 12+19/2/3 |
| 11 | 2.373638/2.472598/2.56271 | 2/3/3 | 3041232/3041328/3106912 | 0/0/0 | 101371120/101398880/101399920 | 108603488/108630144/108633888 | 17+3/5/12 |
| 12 | 0.086024/0.097787/0.100683 | 0/0/0 | 44688/44688/44688 | 0/0/0 | 155969224/155981280/155981504 | 629313544/629314464/629314640 | 12+8/11/20 |
| 13 | 48.917661/50.172324/51.891601 | 49/50/52 | 69068720/69137008/69139440 | 1.5/2/2 | 100508552/100528896/100530208 | 145932928/146002176/146004976 | 5+6/20/2 |
| 14 | 547.447216/550.85655/551.027176 | 547/551/551 | 506918368/506983984/506984240 | 48/51/51 | 121618536/121646688/121651040 | 251427288/251459920/251460704 | 10+12/5/1 |
| 15 | 440.470954/447.451711/449.991136 | 440.5/448/450 | 1608689368/1608722976/1608722976 | 5/5/6 | 100135608/100149056/100149280 | 146766144/146894032/146894256 | 6+7/3/9 |
| 16 | 0.006392/0.007154/0.007364 | 0/0/0 | 848/848/848 | 0/0/0 | 100159640/100188320/100192000 | 142098504/142126528/142129120 | 5+4/13/17 |
| 17 | 0.006498/0.007064/0.009939 | 0/0/0 | 848/848/848 | 0/0/0 | 100159392/100189616/100190848 | 142099024/142127152/142128352 | 9+13/14/4 |
| 18 | 173.580848/177.349604/180.952913 | 173.5/177/180 | 419306400/419372928/419372928 | 7/7/8 | 106305176/106333440/106335008 | 156209704/156285376/156360512 | 9+7/5/4 |
| 19 | 1616.449215/1621.344178/1625.32576 | 1616/1622/1625 | 3958037792/3958042144/3958086160 | 73.5/75/75 | 156209240/156211376/156230080 | 205129784/205374256/205560416 | 2+15/1/8 |
| 20 | 31.37752/32.429572/34.763364 | 31/33/35 | 92381152/92382960/92383408 | 1/2/2 | 101453592/101477520/101477856 | 143163632/151309696/151367216 | 3+1/5/16 |
| 21 | 312.531422/317.449249/317.644943 | 313/317/317 | 949856072/949891120/949894048 | 17/18/18 | 113637984/113660192/113660800 | 156205232/156268864/156269984 | 7+3/6/20 |
| 22 | 1.962762/2.271523/2.312441 | 2/3/3 | 3070208/3070432/3070464 | 0/0/0 | 100529888/100556816/100557744 | 145181384/145208640/145209504 | 4+19/12/10 |
| 23 | 14.045569/16.46057/20.766413 | 14/16/21 | 31262720/31328432/31328432 | 1/3/3 | 103895368/103922176/103925232 | 151139328/151214944/151227616 | 4+16/7/8 |
| 24 | 3409.459465/3439.503967/3444.250771 | 3409/3439/3443 | 8040251888/8040257344/8040260960 | 113/117/118 | 112672176/112675136/112686752 | 164321984/164340168/164401448 | 17+14/18/19 |
| 25 | 0.069848/0.090753/0.108287 | 0/0/1 | 151680/151680/151712 | 0/0/0 | 88079976/88107104/88109744 | 89377032/89404160/89406800 | 4+12/13/20 |
| 26 | 0.071627/0.101093/0.117795 | 0/0/1 | 151680/151680/151680 | 0/0/0 | 88080784/88107760/88110432 | 89377872/89404816/89407488 | 10+5/17/8 |
| 27 | 1.708988/1.740959/1.837323 | 2/2/2 | 4740512/4740528/4806048 | 0/0/0 | 88980560/89007152/89010896 | 97917296/97943904/97948736 | 5+3/14/10 |
| 28 | 10.842515/11.153173/11.223979 | 11/11/12 | 12111360/12111392/12111392 | 3/4/4 | 92122912/92148528/92149776 | 105122744/105148368/105149600 | 6+16/7/13 |
| 29 | 24.201731/25.410313/29.853677 | 24/25/30 | 2163648/2229136/2229168 | 0/0/0 | 89181228/89212752/89214144 | 95343944/95376544/95378024 | 18+16/5/3 |
| 30 | 2.962369/3.202573/4.996412 | 3/4/5 | 21168/21168/86656 | 0/0/0 | 91032728/91059904/91060528 | 92177028/92204224/92205912 | 17+1/3/11 |
| 31 | 5.174919/5.248013/5.256931 | 5/6/6 | 7383264/7448752/7448784 | 0/0/0 | 90899236/90930224/90933040 | 99537752/99569864/99572672 | 18+13/2/9 |

These are descriptive order statistics from one command run. They are not
confidence bounds or independent cross-host replicates.

## Structural evidence and provenance

Each row's structural evidence is an `untimed-single-replay`, separate from the
20 timed samples. For tree edits, `E` is normalized instrumented splice-plan
length, `H` is the maximum inspected old/replacement/result tree height, `R` is
inspected replacement-tree item count, and `F` is fresh
`batch-work-node-identities`. `F_final` and `F_work` are
implementation-specific; present `F_work` equals `F`. Structural `allocations`
is a node-work counter, not bytes, and every present value equals `F`; it is
omitted from the compact table to avoid duplicating `F`. Copy fields come from
text copy-observer components. Slack comes from inspected result nodes/chunks.
Retention populations and identity counts come from actual retained
collections. A dash below means the raw value is JSON `null`, not zero.

| # | E/H/R/F | F_final/F_work | Copy total (old/norm/slice) B | Visits boundary/rebalance | Slack node/chunk B | Nodes edit→final; height old→result | Retained R/S/C; input identities |
|--:|---|---|---|---|---|---|---|
| 1 | —/1/—/— | —/— | — (—/—/0) | —/— | 0/0 | —→33; 1→1 | 0/0/0; — |
| 2 | —/2/—/— | —/— | — (—/—/0) | —/— | 22/0 | —→331; 2→2 | 0/0/0; — |
| 3 | —/3/—/— | —/— | — (—/—/0) | —/— | 56/0 | —→3,305; 3→3 | 0/0/0; — |
| 4 | 20,000/2/29,984/692,515 | 209,949/692,515 | 30,713,700 (15,351,854/15,361,846/—) | 367,349/412,874 | 868/0 | —→61; 2→2 | 0/0/0; 1,003,575 |
| 5 | 20,000/2/29,982/1,093,785 | 309,177/1,093,785 | 30,708,997 (15,349,503/15,359,494/—) | 366,821/636,800 | 8,082/0 | —→591; 2→2 | 0/0/0; 11,153,452 |
| 6 | 10/2/10/69 | 33/69 | 0 (0/0/—) | 20/39 | 384/10,230 | —→343; 2→2 | 0/0/0; 310 |
| 7 | 100/2/180/1,697 | 365/1,697 | 122,920 (81,920/41,000/—) | 1,002/837 | 3,084/102,300 | —→433; 2→2 | 0/0/0; 68 |
| 8 | 1,000/3/1,960/8,782 | 638/8,782 | 1,475,040 (983,040/492,000/—) | 6,798/4,559 | 8,539/1,023,000 | —→638; 2→3 | 0/0/0; 0 |
| 9 | 320/3/19,920/2,126 | 284/2,126 | 15,242,080 (10,158,080/5,084,000/—) | 1,600/1,279 | 3,414/10,230,000 | —→763; 2→3 | 0/0/0; 479 |
| 10 | 20,000/2/10,000/240,002 | 120,002/240,002 | 0 (0/0/—) | 50,000/160,000 | 84/0 | —→333; 2→2 | 0/0/0; 6,544,998 |
| 11 | 1/2/10,240/69 | 22/69 | 0 (0/0/—) | 32/35 | 52/0 | —→365; 1→2 | 0/0/0; 343 |
| 12 | 1/3/0/1 | 1/1 | 0 (0/0/—) | 0/1 | 44/0 | —→1,653; 3→3 | 0/0/0; 1,652 |
| 13 | 1,000/2/1,000/8,516 | 551/8,516 | 2,539,000 (1,023,000/1,516,000/—) | 6,838/4,559 | 6,842/0 | —→551; 2→2 | 0/0/0; 0 |
| 14 | 1/2/10,240/0 | 0/0 | 122,584,160 (10,385,760/112,198,400/—) | 0/1 | 22/0 | —→331; 2→2 | 0/0/0; 331 |
| 15 | —/2/—/— | —/— | — (—/—/—) | —/— | 22/0 | —→331; 2→2 | 0/0/0; — |
| 16 | —/2/—/— | —/— | — (—/—/—) | —/— | 22/0 | —→331; 2→2 | 0/0/0; — |
| 17 | —/2/—/— | —/— | — (—/—/—) | —/— | 22/0 | —→331; 2→2 | 0/0/0; — |
| 18 | 1,000/2/1,000/53,306 | 15,565/53,306 | 2,539,000 (1,023,000/1,516,000/—) | 18,340/30,492 | 6,191/0 | —→530; 2→2 | 1,000/0/0; 415,208 |
| 19 | 10,000/2/10,000/481,880 | 141,474/481,880 | 25,554,000 (10,230,000/15,324,000/—) | 161,139/278,918 | 9,043/0 | —→622; 2→2 | 10,000/0/0; 4,667,640 |
| 20 | —/2/—/— | —/— | 983,040 (—/—/983,040) | —/— | 22/0 | —→331; 2→2 | 0/1,000/0; 0 |
| 21 | —/2/—/— | —/— | 10,158,080 (—/—/10,158,080) | —/— | 22/0 | —→331; 2→2 | 0/10,000/0; 0 |
| 22 | —/2/—/— | —/— | — (—/—/—) | —/— | 22/0 | —→331; 2→2 | 0/0/1,000; 331 |
| 23 | —/2/—/— | —/— | — (—/—/—) | —/— | 22/0 | —→331; 2→2 | 0/0/10,000; 331 |
| 24 | 20,000/2/29,982/1,093,785 | 309,177/1,093,785 | 30,708,997 (15,349,503/15,359,494/—) | 366,821/636,800 | 22/0 | 591→331; 2→2 | 0/0/0; 11,153,452 |
| 25 | —/1/—/— | —/— | — (—/—/—) | —/— | 0/0 | —→33; 1→1 | 0/0/0; — |
| 26 | —/1/—/— | —/— | — (—/—/—) | —/— | 0/0 | —→33; 1→1 | 0/0/0; — |
| 27 | —/—/—/— | —/— | — (—/—/—) | —/— | —/— | —→—; —→— | 0/0/0; — |
| 28 | —/—/—/— | —/— | — (—/—/—) | —/— | —/— | —→—; —→— | 0/0/0; — |
| 29 | —/—/—/— | —/— | — (—/—/—) | —/— | —/— | —→—; —→— | 0/0/0; — |
| 30 | —/—/—/— | —/— | — (—/—/—) | —/— | —/— | —→—; —→— | 0/0/0; — |
| 31 | —/—/—/— | —/— | — (—/—/—) | —/— | —/— | —→—; —→— | 0/0/0; — |

Rows 25 and 26 additionally report identical
`reductionCallbackCount=2080`. Row 30 alone reports
`movementCopiedBytes=157696065`; row 31 alone reports
`snapshotCopiedBytes=1048576`. SumTree structural metrics for rows 27–31 are
not applicable and remain null. Copying for uninstrumented production rows is
also null rather than inferred. `retainedInputNodeIdentities` is the replay's
reported identity counter (summed across edit evidence where applicable), not
a retained-byte measurement or necessarily a globally unique set.

### Structural interpretation

- Packed builds scale from 33 nodes/height 1 at 1 MiB to 331/height 2 at
  10 MiB and 3,305/height 3 at 100 MiB, with node-slot slack 0, 22, and 56 and
  zero chunk-byte slack.
- Local edits end at 61 nodes and 868 free node slots at 1 MiB, and 591 nodes
  and 8,082 slots at 10 MiB. Their replay copied about 30.7 MB at either scale,
  showing this fixed edit count's observed copying did not scale with the
  document by 10×. This is evidence for this trace, not a proof over all edits.
- Batch normalization is visible: input edit populations 10/100/1,000/10,000
  produced `E=10/100/1000/320`. Work and visits are reported in the table;
  notably the 1,000-edit result retained zero input-node identities, while the
  10,000-input row retained 479. These implementation counters do not by
  themselves establish an asymptotic bound.
- Alternating ends copied zero observed old/normalization bytes but performed
  50,000 boundary and 160,000 rebalance visits. Large paste and large delete
  also report zero observed copying in these observer components; replacement
  preparation and unavailable copy categories must not be inferred as zero.
- The 100,000-range replace-all normalized to `E=1`, with 122,584,160 observed
  copied bytes, whereas the 1,000-range case retained `E=1000` and copied
  2,539,000 bytes. This is the exact canonical schedule's normalization result,
  not a generic replace-all rule.

## Retention, memory, fragmentation, and compaction

The retained-root live-memory median was 106,305,176 bytes at 1,000 roots and
156,209,240 bytes at 10,000; retained slices were 101,453,592 and 113,637,984;
retained cursors were 100,529,888 and 103,895,368. The corresponding descriptive
10,000-minus-1,000 differences are 49,904,064, 12,184,392, and 3,365,480 bytes.
Because each population is a separate fresh process, these differences include
runtime and workload effects and are not isolated retained-heap byte costs.
Allocation and peak triples for all six rows remain in the sample table.

Structural retention gives complementary evidence. Root rows retained exactly
1,000/10,000 roots and report 415,208/4,667,640 input-node identity contacts.
Slice rows retained exactly 1,000/10,000 slices, copied 983,040/10,158,080
boundary bytes, and report zero retained input-node identities. Cursor rows
retained exactly 1,000/10,000 cursors while associating retention with the same
331-node root topology. This distinguishes copying slices from root/cursor
sharing, but does not convert identities to bytes.

Rows 5 and 24 share the same 10 MiB local replay hash. Before compaction both
end at 591 nodes. Row 24's explicit serialize/rebuild compaction reduces that
to 331 nodes, node-slot slack from the edit state's 8,082 to 22, and leaves
chunk-byte slack at zero. Its whole-row median is 3409.459465 ms versus
3260.227388 ms for the edit-only row, but the barriers and validation digests
differ and compaction is not isolated; their difference is not a compaction
latency estimate. Compaction copying is unavailable in the raw counters.

This evidence supports carrying the exact tested private `B=32` and `C=1024`
into integration and keeping automatic threshold-based compaction disabled.
It also supports an explicit full rebuild as a structure-restoring operation.
It does not select a trigger threshold, background schedule, or incremental
algorithm. There was no B/C/compaction parameter sweep, so the report makes no
claim that these values are optimal on this host or globally.

## Main timing findings

- Whole build/scan/slice/serialize wall medians were 18.771785 ms (1 MiB),
  243.652855 ms (10 MiB), and 2508.150668 ms (100 MiB).
- Local 20,000-edit medians were 2015.258889 ms (1 MiB) and 3260.227388 ms
  (10 MiB). The matched mutable-gap edit median was 2.962369 ms, with persistence
  semantics explicitly different.
- Distributed-batch medians for 10/100/1,000/10,000 input edits were
  0.297619/6.690186/49.453836/301.810091 ms.
- Alternating ends was 818.040878 ms. Large paste was 2.373638 ms; large delete
  was 0.086024 ms. Replace-all medians were 48.917661 ms (1,000) and
  547.447216 ms (100,000).
- Ten thousand coordinate positions took 440.470954 ms as one row-level
  operation distribution; this is not a per-conversion distribution. Shape
  observation medians were 0.006392 ms for one 10 MiB line and 0.006498 ms for
  millions of short lines; text construction happened before timing.
- Retention medians for 1,000/10,000 populations were
  173.580848/1616.449215 ms for roots, 31.377520/312.531422 ms for slices, and
  1.962762/14.045569 ms for cursors.

## Caveats and scope

- This is one benchmark command, seed, host, OS image, and Racket CS runtime.
  Twenty samples estimate within-run distributions, not cross-run or
  cross-machine variability.
- p95/p99 are empirical nearest-rank statistics over only 20 samples; p99 is
  necessarily the observed maximum and is not a stable tail estimate.
- Raw samples include only the recorded measurement fields. Hostname is null;
  continuous peak RSS, isolated retained-heap bytes, and uninstrumented copy
  categories are unavailable.
- Structural counters come from separate deterministic untimed replays and
  cannot be assigned to a particular timed sample.
- The corpus reaches 100 MiB for build and delete, but edits use synthetic fixed
  schedules. There are no real editor sessions, concurrent workloads,
  long-duration fragmentation cycles, background compaction, or parameter
  sweep.
- Property-run and annotation-overlap performance belongs to later interval
  indexing work and is not represented by this Stage-2 text/control artifact.
- Ratios are reported only for canonical matched controls and are descriptive,
  not inferential or globally predictive.

## Approval boundary

Repository-owner approval is explicitly recorded as approved. The owner accepts
the Stage-2 benchmark report, its recorded controls, private `B=32`, private
`C=1024`, automatic threshold-based compaction disabled, and explicit full
serialize/rebuild compaction for buffer integration. `approvalEligible: true`
only confirms that the runner accepted the complete artifact; it does not itself
record approval. No production constant or public export is changed by this
report. Stage 3 may proceed under this approval, but this report update does not
begin it.
