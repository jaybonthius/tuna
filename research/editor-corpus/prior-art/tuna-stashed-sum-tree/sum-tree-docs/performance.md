# SumTree performance and comparisons

## Target workload

The generic SumTree and Tuna text adapter target immutable retained snapshots, measured byte/character/UTF-16/line navigation, and scattered edit batches whose coordinates all address one old snapshot. They trade allocation and boundary-rebuilding work for persistence and cached summaries. The target is not the fastest possible mutable edit near one cursor.

The private defaults `B=32` and `C=1024`, plus explicit serialize/rebuild compaction, are provisional integration choices. The benchmark did not sweep these parameters or establish an automatic compaction trigger, so they are not optima or public contracts.

## Representative local results

These are wall-time medians from one Racket CS 9.2 run on Linux x86_64. See the [full local report](../docs/research/sum-tree-benchmark.md) for the schedule, samples, structural counters, and provenance.

| Local workload | Median |
| --- | ---: |
| 1 MiB build/scan/slice/serialize: bounded SumTree text | 18.771785 ms |
| Same probe: flat immutable bytes | 1.708988 ms |
| Same probe: flat immutable string | 10.842515 ms |
| Same probe: bounded/indexed pieces | 24.201731 ms |
| 1 MiB local edit trace: SumTree text | 2015.258889 ms |
| Same edit trace: mutable gap buffer | 2.962369 ms |
| Separate mutable-gap snapshot copy | 5.174919 ms |
| 1 MiB summary reduction: generic descriptor | 0.069848 ms |
| Same summary reduction: hard-coded summary | 0.071627 ms |

The gap buffer decisively won this nearby mutable-edit trace. Its edit timing did not include a persistent snapshot; the separately timed 5.174919 ms copy is shown rather than added to the edit row. Conversely, retaining a SumTree root does not copy the full text, but changed paths and boundaries still allocate and old roots keep shared structure live.

The nearly equal generic and hard-coded summary reductions show no descriptor-dispatch penalty in this one identical-topology run. They do not prove that callback cost is generally absent.

The 10 MiB edit trace also left sparse structure. Explicit rebuild compaction reduced the tree from **591 to 331 nodes** and slot slack from **8,082 to 22**. The run did not isolate compaction latency.

## Design comparison

| Structure | Intended strengths | Important trade-off |
| --- | --- | --- |
| **This SumTree with Tuna text adapter** | Persistent roots, simultaneous old-snapshot batches, and client-defined measured navigation | Racket allocation, immutable boundary work, and retained structure cost much more than the local mutable gap control for nearby edits. |
| **Zed SumTree and rope** | Zed's generic tree stores summaries in shared `Arc` nodes; updates use copy-on-write. Its rope is a `SumTree<Chunk>` and summarizes UTF-8, UTF-16, and line measures for coordinate navigation. ([tree and summaries](https://github.com/zed-industries/zed/blob/819fe337999551ce8177b14c8db1127645617ae4/crates/sum_tree/src/sum_tree.rs#L197-L205), [copy-on-write](https://github.com/zed-industries/zed/blob/819fe337999551ce8177b14c8db1127645617ae4/crates/sum_tree/src/sum_tree.rs#L534-L558), [rope backing](https://github.com/zed-industries/zed/blob/819fe337999551ce8177b14c8db1127645617ae4/crates/rope/src/rope.rs#L25-L28), [navigation](https://github.com/zed-industries/zed/blob/819fe337999551ce8177b14c8db1127645617ae4/crates/rope/src/rope.rs#L317-L386), [summary fields](https://github.com/zed-industries/zed/blob/819fe337999551ce8177b14c8db1127645617ae4/crates/rope/src/rope.rs#L784-L812), [official explanation](https://zed.dev/blog/zed-decoded-rope-sumtree)) | Similar ideas do not make Zed's Rust representation, tuning, or performance transferable to Tuna. |
| **Ropey** | A persistent UTF-8 rope with shared clones and byte, character, line, and UTF-16 coordinate operations. ([sharing source](https://github.com/cessen/ropey/blob/42f6fc791b20e61c1b631465f69465dfa4c4fae2/src/rope.rs#L18-L82), [coordinate source I](https://github.com/cessen/ropey/blob/42f6fc791b20e61c1b631465f69465dfa4c4fae2/src/rope.rs#L231-L282), [coordinate source II](https://github.com/cessen/ropey/blob/42f6fc791b20e61c1b631465f69465dfa4c4fae2/src/rope.rs#L634-L747), [API](https://docs.rs/ropey/latest/ropey/struct.Rope.html)) | Tree and chunk overhead remain; Ropey's Rust guarantees and measurements are not Tuna measurements. |
| **Mutable gap buffer** | A contiguous array with a movable gap is simple and especially effective for edits near the gap. ([Emacs manual](https://www.gnu.org/software/emacs/manual/html_node/elisp/Buffer-Gap.html)) | Distant edits move data, and immutable snapshots require copying or extra machinery. |
| **VS Code piece tree** | Original and append-only buffers hold text while a red-black tree indexes pieces and caches subtree length and line metadata. ([piece and buffers](https://github.com/microsoft/vscode/blob/85264502e4c6c4db48604183dc78bee88807282d/src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeBase.ts#L85-L121), [piece operations](https://github.com/microsoft/vscode/blob/85264502e4c6c4db48604183dc78bee88807282d/src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeBase.ts#L209-L261), [append/edit](https://github.com/microsoft/vscode/blob/85264502e4c6c4db48604183dc78bee88807282d/src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeBase.ts#L796-L855), [subtree metadata](https://github.com/microsoft/vscode/blob/85264502e4c6c4db48604183dc78bee88807282d/src/vs/editor/common/model/pieceTreeTextBuffer/rbTreeBase.ts#L8-L28), [official account](https://code.visualstudio.com/blogs/2018/03/23/text-buffer-reimplementation)) | Piece growth and lookup behavior differ from persistent-root sharing; VS Code's JavaScript results do not rank Tuna. |

## Reading the results

- This was one local characterization run, not a Zed, Ropey, Emacs, or VS Code benchmark.
- The controls share local corpora and schedules but not persistence semantics. A fast mutable result and a cheap retained root answer different questions.
- Medians from 20 samples describe that run; they are not cross-host confidence bounds or latency guarantees.
- Structural counters show observed packing and rebuilding, not universal complexity bounds.
- There is no universal winner. Choose for snapshot lifetime, edit locality, coordinate needs, memory limits, and runtime, then benchmark the actual workload.
