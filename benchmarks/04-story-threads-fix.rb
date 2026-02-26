# Step 4: Apply and verify the two-line fix for Comment.story_threads().
#
# This script monkey-patches the fix into the running app and benchmarks it
# against the original implementation. Run on the SQLite version:
#
#   cd ~/lobsters/2-after-sqlite && bin/rails runner ~/lobsters/benchmarks/04-story-threads-fix.rb
#
# The fix addresses both bottlenecks identified in EXPLAIN analysis:
#
#   Bottleneck 1 (CTE base case): The JOIN + OR pattern
#     `JOIN stories ON stories.id = c.story_id WHERE (stories.id = X OR stories.merged_story_id = X)`
#     causes SQLite to scan via parent_comment_id IS NULL (99.8% of rows).
#     FIX: Pre-resolve story IDs and use `WHERE c.story_id IN (...)` instead.
#
#   Bottleneck 2 (final JOIN): The `INNER JOIN comments ON comments.id = confidence.id`
#     triggers a full table scan of all 186k comments.
#     FIX: Add `.where(story_id: story_ids)` to the outer query so SQLite
#     narrows the scan to just the relevant story's comments.
#
# Expected results:
#
#   | Version                    | Req/s | Avg Latency | DB time  |
#   |----------------------------|-------|-------------|----------|
#   | SQLite (original)          | 5.6   | 972ms       | ~310ms   |
#   | SQLite (fix CTE only)      | 12.2  | 487ms       | ~130ms   |
#   | SQLite (both fixes)        | 78    | 187ms       | ~1ms     |
#   | MySQL                      | 59    | 255ms       | ~7ms     |

require "benchmark"

story = Story.order(:id).last
abort "No stories found." unless story

puts "=" * 70
puts "  Story Threads Fix: Before vs After"
puts "  Story: #{story.short_id} (id=#{story.id})"
puts "  Total comments: #{Comment.count}"
puts "  Story comments: #{Comment.where(story_id: story.id).count}"
puts "=" * 70
puts ""

# --- Original (unfixed) query timing ---
puts "1. Original query (Comment.story_threads)..."
original_times = 5.times.map do
  Benchmark.realtime { Comment.story_threads(story).to_a }
end
original_ms = (original_times.sort[2] * 1000).round(1)
puts "   Median: #{original_ms}ms (#{Comment.story_threads(story).count} comments)"
puts ""

# --- Fix 1 only: Pre-resolve story IDs in CTE ---
puts "2. Fix CTE only (pre-resolve story IDs, remove JOIN + OR)..."

story_ids = [story.id]
story_ids += Story.where(merged_story_id: story.id).pluck(:id)
story_ids_sql = story_ids.join(",")

fix1_join = <<~SQL
  inner join (
    with recursive confidence as (
      select c.id, cast(confidence_order as blob) as confidence_order_path
      from comments c
      where c.story_id IN (#{story_ids_sql}) and parent_comment_id is null
      union all
      select c.id,
        cast(concat(substring(confidence.confidence_order_path, 1, 3 * (depth + 1)), c.confidence_order) as blob)
      from comments c join confidence on c.parent_comment_id = confidence.id
    )
    select * from confidence
  ) confidence on comments.id = confidence.id
SQL

fix1_times = 5.times.map do
  Benchmark.realtime { Comment.joins(fix1_join).order("confidence.confidence_order_path").to_a }
end
fix1_ms = (fix1_times.sort[2] * 1000).round(1)
puts "   Median: #{fix1_ms}ms"
puts ""

# --- Both fixes: Pre-resolve IDs + WHERE story_id on outer query ---
puts "3. Both fixes (pre-resolve IDs + WHERE story_id on outer query)..."

fix2_times = 5.times.map do
  Benchmark.realtime {
    Comment.joins(fix1_join)
      .where(story_id: story_ids)
      .order("confidence.confidence_order_path")
      .to_a
  }
end
fix2_ms = (fix2_times.sort[2] * 1000).round(1)
puts "   Median: #{fix2_ms}ms"
puts ""

# --- Summary ---
puts "=" * 70
puts "  Summary"
puts "=" * 70
puts ""
puts "  %-35s %8s %10s" % ["Version", "Time", "Speedup"]
puts "  " + "-" * 55
puts "  %-35s %7.1fms %9s" % ["Original (broken)", original_ms, "baseline"]
puts "  %-35s %7.1fms %8.0fx" % ["Fix 1: CTE only", fix1_ms, original_ms / fix1_ms]
puts "  %-35s %7.1fms %8.0fx" % ["Fix 1+2: CTE + WHERE story_id", fix2_ms, original_ms / fix2_ms]
puts ""

if original_ms > 100 && fix2_ms < 20
  puts "CONFIRMED: Both fixes together give #{(original_ms / fix2_ms).round(0)}x speedup."
  puts "The query planner bottleneck is the root cause."
elsif original_ms < 50
  puts "NOTE: Original query is already fast (#{original_ms}ms). Dataset may be too"
  puts "small to trigger the bottleneck. Need ~150k+ total comments."
end
