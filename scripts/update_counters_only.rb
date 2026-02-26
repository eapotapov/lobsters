#!/usr/bin/env ruby
# frozen_string_literal: true

# Run just the counter updates on an already-seeded database.
# Usage:
#   cd /srv/lobsters/lobsters-current
#   RAILS_ENV=development bundle exec rails runner /srv/lobsters/update_counters_only.rb

HOTNESS_WINDOW = 60 * 60 * 22
BATCH_SIZE = 5_000
conn = ActiveRecord::Base.connection

def timed
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  puts "  (#{elapsed.round(1)}s)"
end

puts "=== Counter Updates ==="
puts

timed do
  print "Story score + flags..."
  conn.execute(<<~SQL)
    UPDATE stories s
    JOIN (
      SELECT story_id,
        COALESCE(SUM(vote), 0) AS total_score,
        SUM(CASE WHEN vote = -1 THEN 1 ELSE 0 END) AS total_flags
      FROM votes WHERE comment_id IS NULL
      GROUP BY story_id
    ) v ON v.story_id = s.id
    SET s.score = v.total_score, s.flags = v.total_flags
  SQL
  puts " done"
end

timed do
  print "Comment score + flags..."
  conn.execute(<<~SQL)
    UPDATE comments c
    JOIN (
      SELECT comment_id,
        COALESCE(SUM(vote), 0) AS total_score,
        SUM(CASE WHEN vote = -1 THEN 1 ELSE 0 END) AS total_flags
      FROM votes WHERE comment_id IS NOT NULL
      GROUP BY comment_id
    ) v ON v.comment_id = c.id
    SET c.score = v.total_score, c.flags = v.total_flags
  SQL
  puts " done"
end

z = "1.281551565545"
z2 = "1.642213913636"

timed do
  print "Wilson confidence..."
  conn.execute(<<~SQL)
    UPDATE comments SET confidence = CASE
      WHEN is_deleted = 1 OR is_moderated = 1 THEN 0
      WHEN (score + 2 * flags) = 0 THEN 0
      ELSE
        GREATEST(0, LEAST(1,
          (
            ((score + flags) * 1.0 / (score + 2 * flags))
            + (#{z2} / (2.0 * (score + 2 * flags)))
            - #{z} * SQRT(
              ((score + flags) * 1.0 / (score + 2 * flags))
              * ((1.0 - (score + flags) * 1.0 / (score + 2 * flags)) / (score + 2 * flags))
              + (#{z2} / (4.0 * (score + 2 * flags) * (score + 2 * flags)))
            )
          ) / (1.0 + #{z2} / (score + 2 * flags))
        ))
      END
  SQL
  puts " done"
end

timed do
  print "confidence_order..."
  conn.execute(<<~SQL)
    UPDATE comments SET confidence_order = concat(
      lpad(char(65535 - floor(confidence * 65535) using binary), 2, '\0'),
      char(id & 0xff using binary)
    )
  SQL
  puts " done"
end

timed do
  print "reply_count + last_reply_at..."
  conn.execute(<<~SQL)
    UPDATE comments c
    JOIN (
      SELECT parent_comment_id,
        COUNT(*) AS cnt,
        MAX(created_at) AS last_at
      FROM comments
      WHERE parent_comment_id IS NOT NULL
      GROUP BY parent_comment_id
    ) r ON r.parent_comment_id = c.id
    SET c.reply_count = r.cnt, c.last_reply_at = r.last_at
  SQL
  puts " done"
end

timed do
  print "comments_count + last_comment_at..."
  conn.execute(<<~SQL)
    UPDATE stories s
    JOIN (
      SELECT story_id,
        COUNT(*) AS cnt,
        MAX(created_at) AS last_at
      FROM comments
      GROUP BY story_id
    ) c ON c.story_id = s.id
    SET s.comments_count = c.cnt, s.last_comment_at = c.last_at
  SQL
  puts " done"
end

timed do
  print "Merged story comment counts..."
  conn.execute(<<~SQL)
    UPDATE stories s
    JOIN (
      SELECT m.merged_story_id AS target_id, COUNT(*) AS cnt
      FROM comments c
      JOIN stories m ON c.story_id = m.id
      WHERE m.merged_story_id IS NOT NULL
      GROUP BY m.merged_story_id
    ) mc ON mc.target_id = s.id
    SET s.comments_count = s.comments_count + mc.cnt
  SQL
  puts " done"
end

timed do
  print "stories_count (merged)..."
  conn.execute(<<~SQL)
    UPDATE stories s
    JOIN (
      SELECT merged_story_id, COUNT(*) AS cnt
      FROM stories
      WHERE merged_story_id IS NOT NULL
      GROUP BY merged_story_id
    ) m ON m.merged_story_id = s.id
    SET s.stories_count = m.cnt
  SQL
  puts " done"
end

timed do
  print "Hotness..."
  conn.execute(<<~SQL)
    UPDATE stories s
    LEFT JOIN (
      SELECT c.story_id, SUM(c.score + 1) * 0.5 AS cpoints
      FROM comments c
      JOIN stories s2 ON c.story_id = s2.id
      WHERE c.user_id != s2.user_id
      GROUP BY c.story_id
    ) cp ON cp.story_id = s.id
    SET s.hotness = -(
      LOG10(GREATEST(ABS(s.score + 1) + LEAST(s.score, GREATEST(0, COALESCE(cp.cpoints, 0))), 1))
      * CASE WHEN s.score > 0 THEN 1 WHEN s.score < 0 THEN -1 ELSE 0 END
      + UNIX_TIMESTAMP(s.created_at) / #{HOTNESS_WINDOW}
    )
  SQL
  puts " done"
end

timed do
  print "Domain stories_count..."
  conn.execute(<<~SQL)
    UPDATE domains d
    JOIN (
      SELECT domain_id, COUNT(*) AS cnt
      FROM stories
      WHERE domain_id IS NOT NULL
      GROUP BY domain_id
    ) sc ON sc.domain_id = d.id
    SET d.stories_count = sc.cnt
  SQL
  puts " done"
end

timed do
  print "Story karma..."
  conn.execute(<<~SQL)
    UPDATE users u
    JOIN (
      SELECT s.user_id, COALESCE(SUM(v.vote), 0) AS story_karma
      FROM votes v
      JOIN stories s ON v.story_id = s.id
      WHERE v.comment_id IS NULL AND v.user_id != s.user_id
      GROUP BY s.user_id
    ) sk ON sk.user_id = u.id
    SET u.karma = sk.story_karma
  SQL
  puts " done"
end

timed do
  print "Comment karma..."
  conn.execute(<<~SQL)
    UPDATE users u
    JOIN (
      SELECT c.user_id, COALESCE(SUM(v.vote), 0) AS comment_karma
      FROM votes v
      JOIN comments c ON v.comment_id = c.id
      WHERE v.user_id != c.user_id
      GROUP BY c.user_id
    ) ck ON ck.user_id = u.id
    SET u.karma = u.karma + ck.comment_karma
  SQL
  puts " done"
end

timed do
  print "Keystore thread_id..."
  max_thread_id = conn.select_value("SELECT MAX(thread_id) FROM comments") || 0
  conn.execute(<<~SQL)
    INSERT INTO keystores (`key`, `value`) VALUES ('thread_id', #{max_thread_id})
    ON DUPLICATE KEY UPDATE `value` = #{max_thread_id}
  SQL
  puts " done"
end

timed do
  print "Keystore per-user counters..."
  values = []
  conn.select_rows(<<~SQL).each do |user_id, sc, cc|
    SELECT u.id,
      COALESCE(s_cnt.cnt, 0) AS sc,
      COALESCE(c_cnt.cnt, 0) AS cc
    FROM users u
    LEFT JOIN (SELECT user_id, COUNT(*) AS cnt FROM stories GROUP BY user_id) s_cnt ON s_cnt.user_id = u.id
    LEFT JOIN (SELECT user_id, COUNT(*) AS cnt FROM comments WHERE is_deleted = 0 GROUP BY user_id) c_cnt ON c_cnt.user_id = u.id
  SQL
    values << "('user:#{user_id}:stories_submitted', #{sc})"
    values << "('user:#{user_id}:comments_posted', #{cc})"
    if values.size >= BATCH_SIZE
      conn.execute("INSERT INTO keystores (`key`, `value`) VALUES #{values.join(',')} ON DUPLICATE KEY UPDATE `value` = VALUES(`value`)")
      values.clear
    end
  end
  unless values.empty?
    conn.execute("INSERT INTO keystores (`key`, `value`) VALUES #{values.join(',')} ON DUPLICATE KEY UPDATE `value` = VALUES(`value`)")
  end
  puts " done"
end

puts
puts "=== All counters updated ==="
