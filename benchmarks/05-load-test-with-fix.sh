#!/usr/bin/env bash
#
# Step 5: End-to-end load test verification after applying the fix.
#
# This script applies the story_threads fix to the SQLite version, restarts
# the service, runs wrk, then reverts the change.
#
# Run on the remote server:
#   bash ~/lobsters/benchmarks/05-load-test-with-fix.sh <story_short_id>
#
# Expected results:
#
#   | Version                  | Req/s | Avg Latency | Timeouts |
#   |--------------------------|-------|-------------|----------|
#   | SQLite (original)        | 5.6   | 972ms       | yes      |
#   | SQLite (fix CTE only)    | 12.2  | 487ms       | 6        |
#   | SQLite (both fixes)      | 78    | 187ms       | 0        |
#   | MySQL                    | 59    | 255ms       | 0        |

set -euo pipefail

STORY_SHORT_ID="${1:-xxxxxx}"
SQLITE_DIR="$HOME/lobsters/2-after-sqlite"
COMMENT_RB="${SQLITE_DIR}/app/models/comment.rb"
DURATION=10s
THREADS=2
CONNECTIONS=10

echo "============================================="
echo "  Load Test: SQLite with story_threads fix"
echo "  wrk -t${THREADS} -c${CONNECTIONS} -d${DURATION}"
echo "  Story: ${STORY_SHORT_ID}"
echo "============================================="
echo ""

# Backup original file
cp "${COMMENT_RB}" "${COMMENT_RB}.bak"

echo "--- 1. SQLite ORIGINAL (before fix) ---"
wrk -t${THREADS} -c${CONNECTIONS} -d${DURATION} "http://localhost:3002/s/${STORY_SHORT_ID}" 2>&1
echo ""

# Apply the fix by replacing the story_threads method.
# This uses a Ruby script to do the patching at runtime.
cat > /tmp/apply_fix.rb << 'RUBY'
file = ARGV[0]
content = File.read(file)

# Find and replace the story_threads method
original = content[/def self\.story_threads\(story\).*?^  end/m]
unless original
  abort "Could not find story_threads method in #{file}"
end

fixed = <<~'RUBY_METHOD'
  def self.story_threads(story)
    return Comment.none unless story.id # unsaved Stories have no comments

    # Fix: Pre-resolve story IDs to avoid JOIN + OR that confuses SQLite's planner
    story_ids = [story.id]
    story_ids += Story.where(merged_story_id: story.id).pluck(:id)
    story_ids_sql = story_ids.join(",")

    inner_join = <<~SQL
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
      ) confidence
      on comments.id = confidence.id
    SQL

    # Fix: Add WHERE story_id to outer query so SQLite doesn't full-scan comments
    Comment.joins(inner_join).where(story_id: story_ids).order("confidence.confidence_order_path")
  end
RUBY_METHOD

content.sub!(original, fixed.strip)
File.write(file, content)
puts "Fix applied to #{file}"
RUBY

ruby /tmp/apply_fix.rb "${COMMENT_RB}"

# Restart the SQLite service to pick up the change
systemctl --user restart lobsters-after
sleep 3

# Warm up
curl -s "http://localhost:3002/s/${STORY_SHORT_ID}" > /dev/null 2>&1
sleep 1

echo "--- 2. SQLite WITH FIX ---"
wrk -t${THREADS} -c${CONNECTIONS} -d${DURATION} "http://localhost:3002/s/${STORY_SHORT_ID}" 2>&1
echo ""

# Restore original
cp "${COMMENT_RB}.bak" "${COMMENT_RB}"
rm "${COMMENT_RB}.bak"
systemctl --user restart lobsters-after
sleep 3

echo "--- 3. MySQL (reference) ---"
wrk -t${THREADS} -c${CONNECTIONS} -d${DURATION} "http://localhost:3001/s/${STORY_SHORT_ID}" 2>&1
echo ""

echo "Original comment.rb restored and service restarted."
