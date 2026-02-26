#!/usr/bin/env ruby
# frozen_string_literal: true

# Fast import of TSV dump files (from MariaDB) into SQLite databases.
# Drops indexes before import, reimports with prepared statements in large
# transactions, then recreates indexes. ~10x faster than indexed inserts.
#
# Usage:
#   bundle exec ruby import_to_sqlite_fast.rb <sqlite_db_path> <dump_dir>

require "sqlite3"

DUMP_DIR = ARGV[1] || "/tmp/lobsters_dump"
SQLITE_DB = ARGV[0] || raise("Usage: ruby import_to_sqlite_fast.rb <sqlite_db_path> <dump_dir>")
COMMIT_EVERY = 100_000

TABLES = %w[
  users categories tags stories story_texts comments votes taggings
  hats read_ribbons saved_stories hidden_stories domains origins
  hat_requests invitations invitation_requests keystores links
  messages moderations mod_notes notifications usernames tag_filters
  suggested_taggings suggested_titles comment_stats
]

def mysql_unescape(field)
  return nil if field == "NULL" || field == "\\N"

  result = +""
  i = 0
  while i < field.bytesize
    byte = field.getbyte(i)
    if byte == 0x5C && i + 1 < field.bytesize
      next_byte = field.getbyte(i + 1)
      case next_byte
      when 0x6E then result << "\n"; i += 2
      when 0x74 then result << "\t"; i += 2
      when 0x5C then result << "\\"; i += 2
      when 0x30 then result << "\0"; i += 2
      when 0x72 then result << "\r"; i += 2
      when 0x4E then i += 2; return nil
      else result << byte.chr; i += 1
      end
    else
      result << byte.chr
      i += 1
    end
  end
  result.force_encoding("UTF-8")
  if result.valid_encoding?
    result
  else
    SQLite3::Blob.new(result.force_encoding("BINARY"))
  end
end

db = SQLite3::Database.new(SQLITE_DB)
db.execute("PRAGMA journal_mode=WAL")
db.execute("PRAGMA synchronous=OFF")
db.execute("PRAGMA foreign_keys=OFF")
db.execute("PRAGMA cache_size=-200000")

# Save and drop all non-autoindex indexes for faster inserts
puts "  Dropping indexes..."
indexes = db.execute(<<~SQL).map { |row| row[0] }
  SELECT sql FROM sqlite_master
  WHERE type = 'index' AND sql IS NOT NULL
  AND name NOT LIKE 'sqlite_autoindex_%'
SQL

db.execute(<<~SQL).each do |row|
  SELECT name FROM sqlite_master
  WHERE type = 'index' AND sql IS NOT NULL
  AND name NOT LIKE 'sqlite_autoindex_%'
SQL
  db.execute("DROP INDEX IF EXISTS #{row[0]}")
end
puts "    dropped #{indexes.size} indexes"

TABLES.each do |table|
  tsv_file = File.join(DUMP_DIR, "#{table}.tsv")
  col_file = File.join(DUMP_DIR, "#{table}.columns")

  next unless File.exist?(tsv_file) && File.size(tsv_file) > 0

  columns = File.read(col_file).strip.split(",")
  placeholders = columns.map { "?" }.join(",")
  sql = "INSERT INTO #{table} (#{columns.join(",")}) VALUES (#{placeholders})"

  $stdout.write "  #{table}... "
  $stdout.flush

  db.execute("DELETE FROM #{table}")

  count = 0
  db.transaction do
    stmt = db.prepare(sql)

    File.open(tsv_file, "rb") do |f|
      f.each_line do |line|
        line.chomp!
        fields = line.split("\t", -1)

        if fields.length != columns.length
          $stderr.puts "  WARN: #{table} row #{count + 1}: expected #{columns.length} fields, got #{fields.length}, skipping"
          next
        end

        values = fields.map { |field| mysql_unescape(field) }
        stmt.execute(values)

        count += 1
        if count % COMMIT_EVERY == 0
          stmt.close
          db.execute("COMMIT")
          db.execute("BEGIN")
          stmt = db.prepare(sql)
          $stdout.write "."
          $stdout.flush
        end
      end
    end

    stmt.close
  end

  puts "#{count} rows"
end

# Recreate indexes
puts "  Recreating indexes..."
indexes.each do |create_sql|
  db.execute(create_sql)
end
puts "    recreated #{indexes.size} indexes"

# Rebuild FTS
$stdout.write "  Rebuilding FTS... "
begin
  db.execute("INSERT INTO comments_fts(comments_fts) VALUES('rebuild')")
rescue
  nil
end
begin
  db.execute("INSERT INTO story_texts_fts(story_texts_fts) VALUES('rebuild')")
rescue
  nil
end
puts "done"

puts "  Import complete."
