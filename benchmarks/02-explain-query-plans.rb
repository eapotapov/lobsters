# Step 2: Show the EXPLAIN query plans that prove the root cause.
#
# Run from the appropriate app directory:
#   cd ~/lobsters/2-after-sqlite && bin/rails runner ~/lobsters/benchmarks/02-explain-query-plans.rb
#   cd ~/lobsters/1-before-sqlite && bin/rails runner ~/lobsters/benchmarks/02-explain-query-plans.rb
#
# Expected results:
#
#   SQLite EXPLAIN QUERY PLAN:
#     SEARCH c USING INDEX comments_parent_comment_id_fk (parent_comment_id=?)
#     SEARCH stories USING INTEGER PRIMARY KEY (rowid=?)
#     ...
#     SCAN comments                          <-- FULL TABLE SCAN of all 186,872 rows
#     BLOOM FILTER ON confidence (id=?)
#
#   MySQL EXPLAIN:
#     stories: index_merge  Using union(PRIMARY,index_stories_on_merged_story_id)
#     c:       ref          USING INDEX story_id_short_id
#     ...
#     comments: eq_ref      PRIMARY          <-- Direct primary key lookup
#
# The two bottlenecks:
#   1. CTE base case: SQLite scans all comments where parent_comment_id IS NULL
#      (99.8% of rows), then joins to stories. MySQL resolves story IDs first.
#   2. Final JOIN: SQLite scans the entire comments table to join against ~25
#      CTE results. MySQL uses eq_ref PRIMARY (direct PK lookup).

story = Story.order(:id).last
abort "No stories found. Run bin/rails fake_data first." unless story

puts "=" * 70
puts "  EXPLAIN Query Plans for Comment.story_threads()"
puts "  Story: #{story.short_id} (id=#{story.id})"
puts "  Database: #{ActiveRecord::Base.connection.adapter_name}"
puts "=" * 70

comment_count = Comment.count
story_comment_count = Comment.where(story_id: story.id).count
null_parent_count = Comment.where(parent_comment_id: nil).count

puts ""
puts "Database stats:"
puts "  Total comments:               #{comment_count}"
puts "  Comments for this story:      #{story_comment_count}"
puts "  Comments with NULL parent_id: #{null_parent_count} (#{(null_parent_count.to_f / comment_count * 100).round(1)}%)"
puts ""

adapter = ActiveRecord::Base.connection.adapter_name.downcase

if adapter.include?("sqlite")
  # SQLite: EXPLAIN QUERY PLAN
  sql = <<~SQL
    EXPLAIN QUERY PLAN
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

  puts "--- SQLite EXPLAIN QUERY PLAN ---"
  puts ""
  results = ActiveRecord::Base.connection.execute(sql)
  results.each do |row|
    indent = "  " * row["detail"].to_s.scan(/--/).length
    puts "  #{row['id']}|#{row['parent']}|#{row['notused']}| #{row['detail']}"
  end

  puts ""
  puts "LOOK FOR: 'SCAN comments' in the output above."
  puts "This means SQLite is scanning ALL #{comment_count} rows instead of"
  puts "using the primary key to look up the #{story_comment_count} matching comments."

elsif adapter.include?("mysql") || adapter.include?("trilogy")
  # MySQL: EXPLAIN
  sql = <<~SQL
    EXPLAIN
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

  puts "--- MySQL EXPLAIN ---"
  puts ""
  results = ActiveRecord::Base.connection.execute(sql)
  # MySQL EXPLAIN returns columns: id, select_type, table, type, possible_keys, key, key_len, ref, rows, Extra
  results.each do |row|
    puts "  table: %-20s type: %-10s key: %-30s rows: %-8s Extra: %s" % [
      row[2], row[3], row[5], row[8], row[9]
    ]
  end

  puts ""
  puts "LOOK FOR: 'eq_ref' with key 'PRIMARY' on the comments table."
  puts "This means MySQL does a direct primary key lookup for each of the"
  puts "#{story_comment_count} CTE results, instead of scanning all #{comment_count} rows."
end
