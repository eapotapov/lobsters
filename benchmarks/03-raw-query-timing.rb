# Step 3: Time the raw CTE query to quantify the bottleneck.
#
# Run from the appropriate app directory:
#   cd ~/lobsters/2-after-sqlite && bin/rails runner ~/lobsters/benchmarks/03-raw-query-timing.rb
#   cd ~/lobsters/1-before-sqlite && bin/rails runner ~/lobsters/benchmarks/03-raw-query-timing.rb
#
# Expected results (with ~186k total comments, ~1820 per story):
#
#   | Query                        | MySQL  | SQLite | Ratio |
#   |------------------------------|--------|--------|-------|
#   | Full CTE + JOIN + ORDER      | 12ms   | 280ms  | 23x   |
#   | Recursive CTE (count only)   | 5ms    | 160ms  | 32x   |
#   | Simple SELECT (no CTE)       | 9ms    | 7ms    | 0.8x  |
#
# The simple query (no CTE) is equally fast on both engines.
# The recursive CTE is 23-32x slower on SQLite due to wrong index choice.

require "benchmark"

story = Story.order(:id).last
abort "No stories found." unless story

adapter = ActiveRecord::Base.connection.adapter_name.downcase
is_sqlite = adapter.include?("sqlite")

puts "=" * 70
puts "  Raw Query Timing: CTE vs Simple SELECT"
puts "  Story: #{story.short_id} (id=#{story.id})"
puts "  Database: #{ActiveRecord::Base.connection.adapter_name}"
puts "  Total comments: #{Comment.count}"
puts "  Story comments: #{Comment.where(story_id: story.id).count}"
puts "=" * 70
puts ""

conn = ActiveRecord::Base.connection

# Build the CTE query appropriate for this database engine
if is_sqlite
  full_cte_sql = <<~SQL
    WITH RECURSIVE confidence AS (
      SELECT c.id, CAST(confidence_order AS blob) AS confidence_order_path
      FROM comments c
      JOIN stories ON stories.id = c.story_id
      WHERE (stories.id = #{story.id} OR stories.merged_story_id = #{story.id})
        AND parent_comment_id IS NULL
      UNION ALL
      SELECT c.id,
        CAST(CONCAT(SUBSTRING(confidence.confidence_order_path, 1, 3 * (depth + 1)), c.confidence_order) AS blob)
      FROM comments c
      JOIN confidence ON c.parent_comment_id = confidence.id
    )
    SELECT comments.*
    FROM comments
    INNER JOIN confidence ON comments.id = confidence.id
    ORDER BY confidence.confidence_order_path
  SQL

  cte_count_sql = <<~SQL
    WITH RECURSIVE confidence AS (
      SELECT c.id, CAST(confidence_order AS blob) AS confidence_order_path
      FROM comments c
      JOIN stories ON stories.id = c.story_id
      WHERE (stories.id = #{story.id} OR stories.merged_story_id = #{story.id})
        AND parent_comment_id IS NULL
      UNION ALL
      SELECT c.id,
        CAST(CONCAT(SUBSTRING(confidence.confidence_order_path, 1, 3 * (depth + 1)), c.confidence_order) AS blob)
      FROM comments c
      JOIN confidence ON c.parent_comment_id = confidence.id
    )
    SELECT COUNT(*) FROM confidence
  SQL
else
  full_cte_sql = <<~SQL
    WITH RECURSIVE discussion AS (
      SELECT c.id,
        CAST(confidence_order AS char(93) CHARACTER SET binary) AS confidence_order_path
      FROM comments c
      JOIN stories ON stories.id = c.story_id
      WHERE (stories.id = #{story.id} OR stories.merged_story_id = #{story.id})
        AND parent_comment_id IS NULL
      UNION ALL
      SELECT c.id,
        CAST(CONCAT(
          LEFT(discussion.confidence_order_path, 3 * (depth + 1)),
          c.confidence_order
        ) AS char(93) CHARACTER SET binary)
      FROM comments c
      JOIN discussion ON c.parent_comment_id = discussion.id
    )
    SELECT comments.*
    FROM comments
    INNER JOIN discussion AS comments_recursive ON comments.id = comments_recursive.id
    ORDER BY comments_recursive.confidence_order_path
  SQL

  cte_count_sql = <<~SQL
    WITH RECURSIVE discussion AS (
      SELECT c.id,
        CAST(confidence_order AS char(93) CHARACTER SET binary) AS confidence_order_path
      FROM comments c
      JOIN stories ON stories.id = c.story_id
      WHERE (stories.id = #{story.id} OR stories.merged_story_id = #{story.id})
        AND parent_comment_id IS NULL
      UNION ALL
      SELECT c.id,
        CAST(CONCAT(
          LEFT(discussion.confidence_order_path, 3 * (depth + 1)),
          c.confidence_order
        ) AS char(93) CHARACTER SET binary)
      FROM comments c
      JOIN discussion ON c.parent_comment_id = discussion.id
    )
    SELECT COUNT(*) FROM discussion
  SQL
end

simple_sql = "SELECT * FROM comments WHERE story_id = #{story.id} ORDER BY created_at"

# Warm up
conn.execute(full_cte_sql)
conn.execute(cte_count_sql)
conn.execute(simple_sql)

iterations = 5

puts "Running each query #{iterations} times, reporting median..."
puts ""

times_full = []
times_cte = []
times_simple = []

iterations.times do
  times_full << Benchmark.realtime { conn.execute(full_cte_sql) }
  times_cte << Benchmark.realtime { conn.execute(cte_count_sql) }
  times_simple << Benchmark.realtime { conn.execute(simple_sql) }
end

median = ->(arr) { sorted = arr.sort; sorted[sorted.length / 2] }

full_ms = (median.call(times_full) * 1000).round(1)
cte_ms = (median.call(times_cte) * 1000).round(1)
simple_ms = (median.call(times_simple) * 1000).round(1)

puts "Results (median of #{iterations} runs):"
puts ""
puts "  %-35s %8s" % ["Query", "Time"]
puts "  " + "-" * 45
puts "  %-35s %7.1fms" % ["Full CTE + JOIN + ORDER", full_ms]
puts "  %-35s %7.1fms" % ["Recursive CTE (count only)", cte_ms]
puts "  %-35s %7.1fms" % ["Simple SELECT (no CTE)", simple_ms]
puts ""

if full_ms > 50 && simple_ms < 50
  puts "CONFIRMED: CTE query is #{(full_ms / simple_ms).round(0)}x slower than simple SELECT."
  puts "The recursive CTE triggers a catastrophic query plan, not a general SQLite issue."
elsif full_ms < 50
  puts "NOTE: CTE query is fast (#{full_ms}ms). Your dataset may be too small"
  puts "to trigger the bottleneck. Need ~150k+ total comments."
end
