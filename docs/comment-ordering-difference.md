# Comment Ordering Difference Between MariaDB and SQLite

## Summary

When comparing comment rendering across the MariaDB and SQLite versions of Lobsters, we found that **some sibling comments appear in a different order**. The comments themselves are identical — same content, same authors, same votes — but their display order occasionally swaps.

This is a systematic issue caused by a difference in how MariaDB and SQLite cast and sort the `confidence_order_path` blob in the recursive CTE that builds comment threading.

## How to See It

Open the same story on both versions (requires `/etc/hosts` entry pointing to `178.128.147.216`):

- MariaDB: http://lobsters-mariadb.eapotapov.test/s/ibaaaa
- SQLite (PR #1871): http://lobsters-1871.eapotapov.test/s/ibaaaa
- SQLite (fixed): http://lobsters-1927.eapotapov.test/s/ibaaaa

On this story (`ibaaaa`, 19 comments), comment `id=246` (a depth-2 grandchild) and comment `id=243` (a depth-1 child) are swapped between MariaDB and SQLite.

Other affected stories (confirmed): `/s/paaaaa` (3 swaps), `/s/9aaaaa` (1 swap). Stories `/s/naaaaa` and `/s/bcaaaa` have identical ordering.

## Root Cause

The `Comment.story_threads()` method uses a recursive CTE to build a `confidence_order_path` — a binary string formed by concatenating each comment's 3-byte `confidence_order` at its depth position. Comments are then sorted by this path to produce threaded display order.

The two database engines construct this path differently:

### MariaDB ([`comment.rb:604`](https://github.com/lobsters/lobsters/blob/9b736939954b959ca85e9962dedb6baaa0565111/app/models/comment.rb#L604))

```sql
cast(confidence_order as char(93) character set binary) as confidence_order_path
```

Casts to a **fixed-width** `char(93)` (= 31 max depth * 3 bytes). The result is **right-padded with `0x00` bytes** to fill 93 bytes.

### SQLite ([`comment.rb:606`](https://github.com/lobsters/lobsters/blob/74544e966924b948e9f411cc0bf11949ef0e03c2/app/models/comment.rb#L606))

```sql
cast(confidence_order as blob) as confidence_order_path
```

Casts to a **variable-length** `blob`. No padding — the path is only as long as the depth requires.

### Why This Causes Swaps

Consider a parent comment at depth 1 and its child at depth 2, both under the same root:

```
Root comment confidence_order: 0x1F95F2

Depth-1 child (id=243):  confidence_order = 0x438BF3
Depth-2 grandchild (id=246): confidence_order = 0x2CAAF6
                              (child of 243)
```

**MariaDB paths** (fixed-width, zero-padded):

| Comment | Path (hex) | Effective sort key |
|---|---|---|
| id=246 (grandchild) | `1F95F2` `000000` `2CAAF6` `000000...` | `1F95F2 000000 2CAAF6` |
| id=243 (child) | `1F95F2` `438BF3` `000000` `000000...` | `1F95F2 438BF3` |

Because the path is fixed-width, the depth-1 slot for the grandchild contains `000000` (padding from the root's truncated path). Since `0x000000` < `0x438BF3`, **the grandchild sorts before its own parent**.

**SQLite paths** (variable-length, no padding):

| Comment | Path (hex) | Effective sort key |
|---|---|---|
| id=243 (child) | `1F95F2` `438BF3` | `1F95F2 438BF3` |
| id=246 (grandchild) | `1F95F2` `438BF3` `2CAAF6` | `1F95F2 438BF3 2CAAF6` |

With variable-length blobs, the child's path (`1F95F2438BF3`) is a prefix of the grandchild's path (`1F95F2438BF32CAAF6`). SQLite sorts shorter values first when they are a prefix, so **the parent correctly sorts before the child**.

### Which One Is Correct?

SQLite produces the **correct** ordering. A parent comment should always appear before its children in a threaded view. MariaDB's zero-padding creates a sort anomaly where a grandchild with high confidence can leapfrog ahead of its parent.

In practice, the visual effect is minor — it only affects comments where a highly-confident reply exists at a deeper nesting level than a sibling — but it is a genuine bug in the MariaDB implementation.

## Code References

### MariaDB version (upstream `main`, commit [`9b736939`](https://github.com/lobsters/lobsters/commit/9b736939954b959ca85e9962dedb6baaa0565111))

- [`COP_LENGTH` constant](https://github.com/lobsters/lobsters/blob/9b736939954b959ca85e9962dedb6baaa0565111/app/models/comment.rb#L103): `31 * 3 = 93` — fixed path width
- [`story_threads` method](https://github.com/lobsters/lobsters/blob/9b736939954b959ca85e9962dedb6baaa0565111/app/models/comment.rb#L593-L625)
- [Base case cast](https://github.com/lobsters/lobsters/blob/9b736939954b959ca85e9962dedb6baaa0565111/app/models/comment.rb#L604): `cast(confidence_order as char(93) character set binary)`
- [Recursive case cast](https://github.com/lobsters/lobsters/blob/9b736939954b959ca85e9962dedb6baaa0565111/app/models/comment.rb#L613-L616): `cast(concat(left(...), c.confidence_order) as char(93) character set binary)`
- [Final ORDER BY](https://github.com/lobsters/lobsters/blob/9b736939954b959ca85e9962dedb6baaa0565111/app/models/comment.rb#L623): `order("comments_recursive.confidence_order_path")`

### SQLite version (PR #1871, commit [`74544e96`](https://github.com/lobsters/lobsters/commit/74544e966924b948e9f411cc0bf11949ef0e03c2))

- [`story_threads` method](https://github.com/lobsters/lobsters/blob/74544e966924b948e9f411cc0bf11949ef0e03c2/app/models/comment.rb#L598-L621)
- [Base case cast](https://github.com/lobsters/lobsters/blob/74544e966924b948e9f411cc0bf11949ef0e03c2/app/models/comment.rb#L606): `cast(confidence_order as blob)`
- [Recursive case cast](https://github.com/lobsters/lobsters/blob/74544e966924b948e9f411cc0bf11949ef0e03c2/app/models/comment.rb#L613): `cast(concat(substring(...), c.confidence_order) as blob)`
- [Final ORDER BY](https://github.com/lobsters/lobsters/blob/74544e966924b948e9f411cc0bf11949ef0e03c2/app/models/comment.rb#L621): `order("confidence.confidence_order_path")`

## Verification

Ran on the production-faithful setup (3 versions, identical data — 675k comments across 120k stories):

| Story | Comments | Ordering |
|---|---|---|
| `/s/ibaaaa` | 19 | **Different** — 1 swap (id=246 vs id=243) |
| `/s/naaaaa` | 18 | Identical |
| `/s/bcaaaa` | 18 | Identical |
| `/s/paaaaa` | 17 | **Different** — 3 swaps |
| `/s/9aaaaa` | 16 | **Different** — 1 swap |

The pattern is consistent: swaps only occur when a grandchild (or deeper) comment has a higher confidence than a sibling at a shallower depth under the same ancestor. Stories with only depth-1 comments or where confidence values don't create cross-depth conflicts have identical ordering.

Both SQLite versions (broken PR #1871 and fixed) produce identical comment ordering — confirming this is a `char(N)` vs `blob` cast difference, not related to the query planner fix.

## Practical Impact

SQLite produces the more correct parent-before-child nesting — a parent comment always appears before its replies. MariaDB's zero-padding can cause a grandchild to jump ahead of its parent's sibling when the grandchild has higher confidence.

However, this does not break the visual thread structure. Comments are still indented correctly by depth in both versions. The difference only affects the relative position of siblings at different depths sharing an ancestor. A user would not notice unless comparing the two side by side.

Both orderings are "reasonable" — the confidence-based sorting is designed to surface high-quality comments, and the swap only manifests when a deeply-nested reply has higher confidence than a shallower sibling. Neither version is broken in a way users would perceive.

This issue is independent of the performance bug that caused the SQLite migration revert (documented in [`INVESTIGATION.md`](../INVESTIGATION.md)).
