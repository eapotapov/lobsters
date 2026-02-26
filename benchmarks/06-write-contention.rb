# Supporting evidence: Write contention was NOT the cause.
#
# Run from each app directory:
#   cd ~/lobsters/2-after-sqlite && bin/rails runner ~/lobsters/benchmarks/06-write-contention.rb
#   cd ~/lobsters/1-before-sqlite && bin/rails runner ~/lobsters/benchmarks/06-write-contention.rb
#
# Expected results (with small/medium dataset):
#
#   | Version        | Sequential | Concurrent | Errors | Slowdown |
#   |----------------|-----------|------------|--------|----------|
#   | MySQL (before) | 41 w/s    | 40 w/s     | 1      | 1.02x    |
#   | SQLite         | 189 w/s   | 296 w/s    | 0      | 0.64x    |
#   | MySQL (revert) | 36 w/s    | 41 w/s     | 1      | 0.87x    |
#
# SQLite writes were 4-7x FASTER than MySQL. Write contention was not the problem.

require "benchmark"

TOTAL_WRITES = 250
THREAD_COUNT = 5
WRITES_PER_THREAD = TOTAL_WRITES / THREAD_COUNT

# Find a story to vote on
story = Story.first
user = User.first
abort "Need at least one story and user" unless story && user

puts "=" * 70
puts "  Write Contention Test"
puts "  Database: #{ActiveRecord::Base.connection.adapter_name}"
puts "  #{TOTAL_WRITES} writes, #{THREAD_COUNT} threads"
puts "=" * 70
puts ""

# Use Keystore as a simple write target (key-value store, no complex validations)
# Sequential writes
puts "Sequential writes (#{TOTAL_WRITES} total)..."
seq_errors = 0
seq_time = Benchmark.realtime do
  TOTAL_WRITES.times do |i|
    Keystore.put("bench_seq_#{i}", i.to_s)
  rescue => e
    seq_errors += 1
  end
end
seq_rate = (TOTAL_WRITES / seq_time).round(1)
puts "  #{seq_rate} writes/s, #{seq_errors} errors, #{(seq_time * 1000).round(0)}ms total"
puts ""

# Concurrent writes
puts "Concurrent writes (#{THREAD_COUNT} threads x #{WRITES_PER_THREAD} writes)..."
conc_errors = Concurrent::AtomicFixnum.new(0) rescue 0
error_count = 0
conc_time = Benchmark.realtime do
  threads = THREAD_COUNT.times.map do |t|
    Thread.new do
      WRITES_PER_THREAD.times do |i|
        Keystore.put("bench_conc_#{t}_#{i}", i.to_s)
      rescue => e
        error_count += 1
      end
    end
  end
  threads.each(&:join)
end
conc_rate = (TOTAL_WRITES / conc_time).round(1)
puts "  #{conc_rate} writes/s, #{error_count} errors, #{(conc_time * 1000).round(0)}ms total"
puts ""

# Cleanup
TOTAL_WRITES.times { |i| Keystore.where(key: "bench_seq_#{i}").delete_all }
THREAD_COUNT.times do |t|
  WRITES_PER_THREAD.times { |i| Keystore.where(key: "bench_conc_#{t}_#{i}").delete_all }
end

slowdown = (seq_time / conc_time).round(2)
puts "Summary:"
puts "  Sequential: #{seq_rate} writes/s"
puts "  Concurrent: #{conc_rate} writes/s"
puts "  Ratio:      #{slowdown}x (< 1.0 means concurrent is faster)"
puts ""
if error_count == 0
  puts "No SQLITE_BUSY errors. Write contention is not a problem at this scale."
else
  puts "#{error_count} errors under concurrent load."
end
