#!/usr/bin/env ruby
# frozen_string_literal: true

# Production-scale data seeder for Lobsters SQLite Migration Study
#
# Generates data matching real Lobsters production:
#   ~5,000 users, ~120,000 stories, ~675,000 comments, ~4,000,000 votes
#   ~10M rows total, 4.5-6.5 GB on disk
#
# This script mirrors production Lobsters behavior:
#   - confidence/confidence_order computed via Wilson score (same formula as comment.rb)
#   - hotness computed using the production formula (same as story.rb)
#   - initial self-upvote votes for every story and comment (same as after_create callbacks)
#   - domain records created for story URLs (same as Story#url= setter)
#   - usernames table populated (same as User after_create callback)
#   - keystore counters populated (thread_id, per-user story/comment counts)
#   - reply_count, last_reply_at, last_comment_at counter caches updated
#   - karma computed from actual vote data
#
# Usage:
#   cd /srv/lobsters/lobsters-current
#   RAILS_ENV=development bundle exec rails runner /path/to/seed_production_scale.rb
#
# This script uses bulk SQL inserts for speed. Expected runtime: 10-20 minutes on
# the s-4vcpu-8gb droplet. After running, use the YAML dump/load pipeline to copy
# data into the SQLite versions.

require "securerandom"
require "bcrypt"
require "bigdecimal"

class ProductionScaleSeeder
  # Target counts matching production
  USERS_COUNT       = 5_000
  STORIES_COUNT     = 120_000
  COMMENTS_COUNT    = 675_000
  VOTES_COUNT       = 4_000_000
  CATEGORIES_COUNT  = 10
  TAGS_COUNT        = 80
  BATCH_SIZE        = 5_000

  # Production constants from story.rb and comment.rb
  HOTNESS_WINDOW = 60 * 60 * 22 # 22 hours, from Story::HOTNESS_WINDOW
  MAX_DEPTH = 18                # from Comment::MAX_DEPTH

  # Vote reason codes
  COMMENT_REASONS = %w[O M T U S].freeze
  STORY_REASONS   = %w[O A B S].freeze

  # Words for generating fake text
  WORDS = %w[
    the be to of and a in that have I it for not on with he as you do at this
    but his by from they we say her she or an will my one all would there their
    what so up out if about who get which go me when make can like time no just
    him know take people into year your good some could them see other than then
    now look only come its over think also back after use two how our work first
    well way even new want because any these give day most us code software
    programming technology web application system database server network security
    design performance testing development framework library tool project open
    source release update version feature bug fix patch review discussion
    community article blog post comment question answer link resource tutorial
    guide reference documentation api interface protocol standard specification
    algorithm data structure type function method class object module package
    linux windows mac unix shell terminal command script automation deploy
    cloud container docker kubernetes microservice architecture distributed
    cache queue message event stream batch process thread async concurrent
    parallel memory cpu disk storage file directory path config environment
    variable constant string integer float boolean array hash map set list
    queue stack tree graph sort search filter transform parse render template
    view controller model route middleware plugin extension hook callback
    handler listener observer pattern factory builder adapter proxy decorator
    strategy iterator generator promise future stream pipeline workflow
    compiler interpreter runtime garbage collection optimization benchmark
    profile debug trace log monitor alert metric dashboard report analytics
    rust python javascript typescript ruby go java swift kotlin scala elixir
    haskell clojure erlang lisp scheme forth assembly wasm llvm
  ].freeze

  def initialize
    @conn = ActiveRecord::Base.connection
    @now = Time.now.utc
    @rng = Random.new(42) # Fixed seed for reproducibility
    @comment_story_map = {}  # comment_id => story_id
    @comment_user_map = {}   # comment_id => user_id (for initial upvotes)
    @story_user_map = {}     # story_id => user_id (for initial upvotes)
    @story_created_at = {}   # story_id => created_at string (for hotness)
  end

  def run
    puts "=== Production-Scale Lobsters Seeder ==="
    puts "Target: #{USERS_COUNT} users, #{STORIES_COUNT} stories, #{COMMENTS_COUNT} comments, #{VOTES_COUNT} votes"
    puts

    timed(:seed_users)
    timed(:seed_usernames)
    timed(:seed_categories_and_tags)
    timed(:seed_domains)
    timed(:seed_stories)
    timed(:seed_comments)
    timed(:seed_initial_votes)
    timed(:seed_votes)
    timed(:seed_supplementary)
    timed(:update_counters)

    print_summary
  end

  private

  def measure
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).round(1)
  end

  def timed(method_name)
    elapsed = measure { send(method_name) }
    puts "  (#{elapsed}s)"
  end

  # ── Users ──────────────────────────────────────────────────────────────

  def seed_users
    print "Seeding #{USERS_COUNT} users..."

    # The seeds.rb creates users 1 (System), 2 (inactive-user), 3 (test)
    # We start from user 4
    existing = User.count
    if existing >= USERS_COUNT
      puts " already have #{existing} users, skipping"
      return
    end

    password_digest = BCrypt::Password.create("password", cost: 4)
    start_id = existing + 1

    values = []
    (start_id..USERS_COUNT).each do |i|
      username = "user_#{i}"
      email = "user_#{i}@example.com"
      created_at = random_date_within(4 * 365) # up to 4 years ago
      karma = 0 # will be computed from votes in update_counters
      is_admin = i <= 5 ? 1 : 0
      is_moderator = i <= 20 ? 1 : 0
      token = generate_token("user")
      session_token = SecureRandom.hex(20)
      about = sentence(5..15)

      values << "(#{i}, '#{username}', '#{email}', '#{e(password_digest)}', " \
                "'#{created_at}', #{is_admin}, '#{session_token}', '#{e(about)}', " \
                "#{is_moderator}, #{karma}, 0, '#{token}', 0)"

      if values.size >= BATCH_SIZE
        flush_users(values)
        values.clear
        print "."
      end
    end
    flush_users(values) unless values.empty?
    puts " done"
  end

  def flush_users(values)
    return if values.empty?
    @conn.execute(<<~SQL)
      INSERT INTO users (id, username, email, password_digest, created_at,
        is_admin, session_token, about, is_moderator, karma,
        mailing_list_mode, token, show_email)
      VALUES #{values.join(",\n")}
    SQL
  end

  # ── Usernames (production: User after_create creates Username record) ──

  def seed_usernames
    print "Seeding usernames..."

    existing = @conn.select_value("SELECT COUNT(*) FROM usernames")
    if existing >= USERS_COUNT
      puts " already have #{existing} usernames, skipping"
      return
    end

    values = []
    @conn.select_rows("SELECT id, username, created_at FROM users").each do |id, username, created_at|
      values << "(#{id}, '#{e(username)}', #{id}, '#{created_at}')"

      if values.size >= BATCH_SIZE
        flush_usernames(values)
        values.clear
        print "."
      end
    end
    flush_usernames(values) unless values.empty?
    puts " done"
  end

  def flush_usernames(values)
    return if values.empty?
    @conn.execute(<<~SQL)
      INSERT IGNORE INTO usernames (id, username, user_id, created_at)
      VALUES #{values.join(",\n")}
    SQL
  end

  # ── Categories & Tags ──────────────────────────────────────────────────

  def seed_categories_and_tags
    print "Seeding categories and tags..."

    if Category.count >= CATEGORIES_COUNT && Tag.count >= TAGS_COUNT
      puts " already seeded, skipping"
      return
    end

    category_names = %w[
      Technology Programming Science Culture Media
      Practices Law Business Hardware
    ]

    categories = category_names.first(CATEGORIES_COUNT).map.with_index(1) do |name, i|
      existing = Category.find_by(category: name)
      next existing if existing
      Category.create!(category: name, token: generate_token("category"))
    end

    tag_names = %w[
      programming ruby python javascript rust go java security linux
      networking databases web devops ai ml api design systems distributed
      performance testing release opensource hardware science culture
      compsci cryptography privacy browsers mobile cloud containers
      compilers osdev graphics gamedev embedded audio video pdf
      elixir haskell scala kotlin swift typescript wasm assembly
      virtualization storage css html react vim emacs git
      networking unix practices reversing interviews law
      historical ask show meta education philosophy math
      formalmethods apl lisp clojure erlang dotnet person
      rant debugging archive satire event slides
    ]

    tag_names.first(TAGS_COUNT).each_with_index do |name, i|
      next if Tag.find_by(tag: name)
      Tag.create!(
        tag: name,
        category: categories[i % categories.size],
        description: sentence(3..10).truncate(100),
        token: generate_token("tag")
      )
    end
    puts " done"
  end

  # ── Domains (production: Story#url= creates Domain records) ────────────

  def seed_domains
    print "Seeding domains..."

    existing = @conn.select_value("SELECT COUNT(*) FROM domains")
    if existing > 0
      puts " already have #{existing} domains, skipping"
      @example_domain_id = @conn.select_value("SELECT id FROM domains WHERE domain = 'example.com'")
      return
    end

    # All our story URLs use example.com — create a single domain
    token = generate_token("domain")
    now_str = @now.strftime("%Y-%m-%d %H:%M:%S")
    @conn.execute(<<~SQL)
      INSERT INTO domains (id, domain, created_at, updated_at, stories_count, token)
      VALUES (1, 'example.com', '#{now_str}', '#{now_str}', 0, '#{token}')
    SQL
    @example_domain_id = 1
    puts " done"
  end

  # ── Stories ─────────────────────────────────────────────────────────────

  def seed_stories
    print "Seeding #{STORIES_COUNT} stories..."

    existing = Story.count
    if existing >= STORIES_COUNT
      puts " already have #{existing} stories, skipping"
      # Load story->user mapping for initial upvotes
      if @story_user_map.empty?
        @conn.select_rows("SELECT id, user_id, created_at FROM stories").each do |id, uid, cat|
          @story_user_map[id.to_i] = uid.to_i
          @story_created_at[id.to_i] = cat.to_s
        end
      end
      return
    end

    tag_ids = Tag.pluck(:id)
    start_id = existing + 1

    story_values = []
    story_text_values = []
    tagging_values = []
    tagging_id = Tagging.maximum(:id).to_i + 1

    (start_id..STORIES_COUNT).each do |i|
      user_id = @rng.rand(1..USERS_COUNT)
      created_at = random_date_within(3 * 365)
      title = sentence(3..8).truncate(150)
      short_id = base36(6, i)
      token = generate_token("story")
      score = 1 # initial score = 1 (submitter's upvote), will be recalculated from votes
      flags = 0
      is_deleted = @rng.rand(100) < 2 ? 1 : 0
      comments_count = 0 # will be updated later

      has_url = @rng.rand(100) > 15
      url = has_url ? "https://example.com/article/#{i}" : ""
      normalized_url = has_url ? url : nil
      description = has_url ? nil : paragraphs(1..3)
      markeddown = description
      domain_id = has_url ? @example_domain_id : "NULL"

      # Compute hotness using production formula (story.rb:546-576)
      # Simplified: no tag hotness_mod, no comment points yet (computed later)
      created_at_ts = Time.parse(created_at).to_f
      order = Math.log([score.abs + 1, 1].max, 10)
      sign = score > 0 ? 1 : (score < 0 ? -1 : 0)
      hotness = -((order * sign) + (created_at_ts / HOTNESS_WINDOW)).round(7)

      @story_user_map[i] = user_id
      @story_created_at[i] = created_at

      story_values << "(#{i}, '#{created_at}', #{user_id}, '#{e(url)}', " \
                      "#{sql_quote(normalized_url)}, " \
                      "'#{e(title)}', #{sql_quote(description)}, " \
                      "'#{short_id}', #{is_deleted}, #{score}, #{flags}, 0, " \
                      "#{hotness}, #{sql_quote(markeddown)}, " \
                      "#{comments_count}, NULL, NULL, 0, 0, #{domain_id}, NULL, NULL, " \
                      "NULL, 0, '#{created_at}', '#{created_at}', '#{token}')"

      story_text_values << "(#{i}, '#{e(title)}', " \
                           "#{sql_quote(description)}, " \
                           "#{sql_quote(description)}, " \
                           "'#{created_at}')"

      # 1-3 tags per story
      num_tags = @rng.rand(1..3)
      chosen_tags = tag_ids.sample(num_tags, random: @rng)
      chosen_tags.each do |tag_id|
        tagging_values << "(#{tagging_id}, #{i}, #{tag_id})"
        tagging_id += 1
      end

      if story_values.size >= BATCH_SIZE
        flush_stories(story_values)
        flush_story_texts(story_text_values)
        flush_taggings(tagging_values)
        story_values.clear
        story_text_values.clear
        tagging_values.clear
        print "."
      end
    end

    flush_stories(story_values) unless story_values.empty?
    flush_story_texts(story_text_values) unless story_text_values.empty?
    flush_taggings(tagging_values) unless tagging_values.empty?
    puts " done"
  end

  def flush_stories(values)
    return if values.empty?
    @conn.execute(<<~SQL)
      INSERT INTO stories (id, created_at, user_id, url, normalized_url,
        title, description, short_id, is_deleted, score, flags, is_moderated,
        hotness, markeddown_description, comments_count, merged_story_id,
        unavailable_at, user_is_author, user_is_following, domain_id,
        mastodon_id, origin_id, last_comment_at, stories_count,
        updated_at, last_edited_at, token)
      VALUES #{values.join(",\n")}
    SQL
  end

  def flush_story_texts(values)
    return if values.empty?
    @conn.execute(<<~SQL)
      INSERT INTO story_texts (id, title, description, body, created_at)
      VALUES #{values.join(",\n")}
    SQL
  end

  def flush_taggings(values)
    return if values.empty?
    @conn.execute(<<~SQL)
      INSERT IGNORE INTO taggings (id, story_id, tag_id)
      VALUES #{values.join(",\n")}
    SQL
  end

  # ── Comments ────────────────────────────────────────────────────────────

  def seed_comments
    print "Seeding #{COMMENTS_COUNT} comments..."

    existing = Comment.count
    if existing >= COMMENTS_COUNT
      puts " already have #{existing} comments, skipping"
      # Load mappings for vote generation
      if @comment_story_map.empty?
        print " loading comment maps..."
        @conn.select_rows("SELECT id, story_id, user_id FROM comments").each do |id, sid, uid|
          @comment_story_map[id.to_i] = sid.to_i
          @comment_user_map[id.to_i] = uid.to_i
        end
        puts " loaded #{@comment_story_map.size} mappings"
      end
      return
    end

    start_id = existing + 1
    values = []
    comments_per_story = COMMENTS_COUNT.to_f / STORIES_COUNT # ~5.6
    @comment_story_map.clear
    @comment_user_map.clear

    comment_id = start_id
    story_id = 1

    while comment_id <= COMMENTS_COUNT
      # Generate a cluster of comments for this story
      num_comments = poisson(comments_per_story).clamp(0, 50)
      break if comment_id + num_comments > COMMENTS_COUNT + 50 # allow slight overshoot

      story_created = random_date_within(3 * 365)
      thread_root_id = comment_id
      depths_in_cluster = [] # track depth of each comment in this cluster

      num_comments.times do |j|
        break if comment_id > COMMENTS_COUNT

        user_id = @rng.rand(1..USERS_COUNT)
        created_at = story_created # comments around story creation time
        short_id = base36(10, comment_id)
        token = generate_token("comment")
        comment_text = paragraphs(1..2)

        # Initial score=1 (submitter's upvote), confidence computed later from actual votes
        score = 1
        flags = 0
        confidence = wilson_confidence(score, flags)
        confidence_order_hex = confidence_order_hex(confidence, comment_id)

        # Threading: first comment is root, then ~50% are replies
        if j == 0
          parent_comment_id = "NULL"
          current_thread_id = comment_id
          depth = 0
        elsif @rng.rand(100) < 50
          # Reply to a random earlier comment in this story's cluster
          parent_idx = @rng.rand(0..j - 1)
          parent_id = thread_root_id + parent_idx
          parent_comment_id = parent_id.to_s
          current_thread_id = thread_root_id
          depth = [(depths_in_cluster[parent_idx] || 0) + 1, MAX_DEPTH].min
        else
          parent_comment_id = "NULL"
          current_thread_id = comment_id
          depth = 0
        end
        depths_in_cluster << depth
        @comment_story_map[comment_id] = story_id
        @comment_user_map[comment_id] = user_id

        values << "(#{comment_id}, '#{created_at}', '#{created_at}', '#{short_id}', " \
                  "#{story_id}, #{confidence_order_hex}, #{user_id}, #{parent_comment_id}, " \
                  "#{current_thread_id}, '#{e(comment_text)}', #{score}, #{flags}, " \
                  "#{confidence}, '#{e(comment_text)}', 0, 0, 0, NULL, #{depth}, 0, NULL, " \
                  "'#{created_at}', '#{token}')"

        comment_id += 1
      end

      story_id += 1
      story_id = 1 if story_id > STORIES_COUNT

      if values.size >= BATCH_SIZE
        flush_comments(values)
        values.clear
        print "."
      end
    end

    flush_comments(values) unless values.empty?
    puts " done"
  end

  def flush_comments(values)
    return if values.empty?
    @conn.execute(<<~SQL)
      INSERT INTO comments (id, created_at, updated_at, short_id,
        story_id, confidence_order, user_id, parent_comment_id,
        thread_id, comment, score, flags, confidence, markeddown_comment,
        is_deleted, is_moderated, is_from_email, hat_id, depth, reply_count,
        last_reply_at, last_edited_at, token)
      VALUES #{values.join(",\n")}
    SQL
  end

  # ── Initial self-upvotes (production: after_create callbacks) ──────────

  def seed_initial_votes
    print "Seeding initial self-upvotes..."

    existing = Vote.count
    if existing > 0
      puts " votes already exist, skipping"
      return
    end

    values = []
    vote_id = 1

    # Story self-upvotes (story.rb: record_initial_upvote)
    print " stories"
    @story_user_map.each do |sid, uid|
      values << "(#{vote_id}, #{uid}, #{sid}, NULL, 1, '', '#{@now.strftime("%Y-%m-%d %H:%M:%S")}')"
      vote_id += 1

      if values.size >= BATCH_SIZE
        flush_votes(values)
        values.clear
        print "."
      end
    end
    flush_votes(values) unless values.empty?
    values.clear

    # Comment self-upvotes (comment.rb: record_initial_upvote)
    print " comments"
    @comment_story_map.each do |cid, sid|
      uid = @comment_user_map[cid]
      values << "(#{vote_id}, #{uid}, #{sid}, #{cid}, 1, '', '#{@now.strftime("%Y-%m-%d %H:%M:%S")}')"
      vote_id += 1

      if values.size >= BATCH_SIZE
        flush_votes(values)
        values.clear
        print "."
      end
    end
    flush_votes(values) unless values.empty?

    @next_vote_id = vote_id
    puts " done (#{format_number(vote_id - 1)} initial votes)"
  end

  # ── Additional votes ───────────────────────────────────────────────────

  def seed_votes
    print "Seeding #{VOTES_COUNT} additional votes..."

    total_votes = Vote.count
    if total_votes >= VOTES_COUNT
      puts " already have #{total_votes} votes, skipping"
      return
    end

    # Initial votes already created; generate the remaining
    remaining = VOTES_COUNT - total_votes
    vote_id = @next_vote_id || (Vote.maximum(:id).to_i + 1)
    values = []

    # ~60% comment votes, ~40% story votes (matching production patterns)
    comment_votes_target = (remaining * 0.6).to_i
    story_votes_target = remaining - comment_votes_target

    # Build set of existing (user, comment) and (user, story) votes from initial upvotes
    seen_comment_votes = Set.new
    seen_story_votes = Set.new
    @comment_story_map.each do |cid, _sid|
      uid = @comment_user_map[cid]
      seen_comment_votes.add([uid, cid])
    end
    @story_user_map.each do |sid, uid|
      seen_story_votes.add([uid, sid])
    end

    # Comment votes
    print " comments"
    comment_votes_generated = 0
    while comment_votes_generated < comment_votes_target
      comment_id = @rng.rand(1..COMMENTS_COUNT)
      story_id = @comment_story_map[comment_id] || 1
      user_id = @rng.rand(1..USERS_COUNT)
      next unless seen_comment_votes.add?([user_id, comment_id])
      vote = @rng.rand(100) < 5 ? -1 : 1
      reason = vote == -1 ? "'#{COMMENT_REASONS.sample(random: @rng)}'" : "''"
      updated_at = random_date_within(3 * 365)

      values << "(#{vote_id}, #{user_id}, #{story_id}, #{comment_id}, #{vote}, #{reason}, '#{updated_at}')"

      vote_id += 1
      comment_votes_generated += 1

      if values.size >= BATCH_SIZE
        flush_votes(values)
        values.clear
        print "."
      end
    end

    # Story votes (no comment_id)
    print " stories"
    story_votes_generated = 0
    while story_votes_generated < story_votes_target
      story_id = @rng.rand(1..STORIES_COUNT)
      user_id = @rng.rand(1..USERS_COUNT)
      next unless seen_story_votes.add?([user_id, story_id])
      vote = @rng.rand(100) < 5 ? -1 : 1
      reason = vote == -1 ? "'#{STORY_REASONS.sample(random: @rng)}'" : "''"
      updated_at = random_date_within(3 * 365)

      values << "(#{vote_id}, #{user_id}, #{story_id}, NULL, #{vote}, #{reason}, '#{updated_at}')"

      vote_id += 1
      story_votes_generated += 1

      if values.size >= BATCH_SIZE
        flush_votes(values)
        values.clear
        print "."
      end
    end

    flush_votes(values) unless values.empty?
    puts " done"
  end

  def flush_votes(values)
    return if values.empty?
    @conn.execute(<<~SQL)
      INSERT IGNORE INTO votes (id, user_id, story_id, comment_id, vote, reason, updated_at)
      VALUES #{values.join(",\n")}
    SQL
  end

  # ── Supplementary tables ────────────────────────────────────────────────

  def seed_supplementary
    print "Seeding supplementary tables..."

    # Read ribbons (~2M - users following stories they commented on)
    seed_read_ribbons
    print "."

    # Saved stories (~50k)
    seed_saved_stories
    print "."

    # Hidden stories (~30k)
    seed_hidden_stories
    print "."

    # Hats (~500)
    seed_hats
    print "."

    # Story merges (~200)
    seed_merges
    print "."

    puts " done"
  end

  def seed_read_ribbons
    count = 2_000_000
    existing = ReadRibbon.count
    return if existing >= count

    values = []
    id = existing + 1
    count.times do
      user_id = @rng.rand(1..USERS_COUNT)
      story_id = @rng.rand(1..STORIES_COUNT)
      created_at = random_date_within(3 * 365)
      values << "(#{id}, 1, '#{created_at}', '#{created_at}', #{user_id}, #{story_id})"
      id += 1

      if values.size >= BATCH_SIZE
        flush_read_ribbons(values)
        values.clear
      end
    end
    flush_read_ribbons(values) unless values.empty?
  end

  def flush_read_ribbons(values)
    return if values.empty?
    @conn.execute(<<~SQL)
      INSERT IGNORE INTO read_ribbons (id, is_following, created_at, updated_at, user_id, story_id)
      VALUES #{values.join(",\n")}
    SQL
  end

  def seed_saved_stories
    count = 50_000
    existing = SavedStory.count
    return if existing >= count

    values = []
    id = existing + 1
    seen = Set.new
    count.times do
      user_id = @rng.rand(1..USERS_COUNT)
      story_id = @rng.rand(1..STORIES_COUNT)
      next unless seen.add?([user_id, story_id])
      created_at = random_date_within(2 * 365)
      token = generate_token("savedstory")
      values << "(#{id}, '#{created_at}', '#{created_at}', #{user_id}, #{story_id}, '#{token}')"
      id += 1

      if values.size >= BATCH_SIZE
        flush_saved_stories(values)
        values.clear
      end
    end
    flush_saved_stories(values) unless values.empty?
  end

  def flush_saved_stories(values)
    return if values.empty?
    @conn.execute(<<~SQL)
      INSERT IGNORE INTO saved_stories (id, created_at, updated_at, user_id, story_id, token)
      VALUES #{values.join(",\n")}
    SQL
  end

  def seed_hidden_stories
    count = 30_000
    existing = HiddenStory.count
    return if existing >= count

    values = []
    id = existing + 1
    seen = Set.new
    count.times do
      user_id = @rng.rand(1..USERS_COUNT)
      story_id = @rng.rand(1..STORIES_COUNT)
      next unless seen.add?([user_id, story_id])
      created_at = random_date_within(2 * 365)
      token = generate_token("hiddenstory")
      values << "(#{id}, #{user_id}, #{story_id}, '#{created_at}', '#{token}')"
      id += 1

      if values.size >= BATCH_SIZE
        flush_hidden_stories(values)
        values.clear
      end
    end
    flush_hidden_stories(values) unless values.empty?
  end

  def flush_hidden_stories(values)
    return if values.empty?
    @conn.execute(<<~SQL)
      INSERT IGNORE INTO hidden_stories (id, user_id, story_id, created_at, token)
      VALUES #{values.join(",\n")}
    SQL
  end

  def seed_hats
    count = 500
    existing = Hat.count
    return if existing >= count

    values = []
    suffixes = %w[Developer Founder Maintainer Contributor Author]
    adjectives = %w[Core Lead Senior Principal Staff Distinguished Former Honorary]

    (existing + 1..count).each do |id|
      user_id = @rng.rand(1..USERS_COUNT)
      granted_by = @rng.rand(1..20) # moderators
      hat = "#{adjectives.sample(random: @rng)} #{suffixes.sample(random: @rng)}"
      short_id = base36(10, id + 100_000)
      token = generate_token("hat")
      created_at = random_date_within(2 * 365)
      doffed = @rng.rand(100) < 20 ? "'#{created_at}'" : "NULL"

      values << "(#{id}, '#{created_at}', '#{created_at}', #{user_id}, #{granted_by}, " \
                "'#{e(hat)}', 'https://example.com/hat/#{id}', 0, #{doffed}, '#{short_id}', '#{token}')"
    end
    flush_hats(values) unless values.empty?
  end

  def flush_hats(values)
    return if values.empty?
    @conn.execute(<<~SQL)
      INSERT INTO hats (id, created_at, updated_at, user_id, granted_by_user_id,
        hat, link, modlog_use, doffed_at, short_id, token)
      VALUES #{values.join(",\n")}
    SQL
  end

  def seed_merges
    # Merge ~200 stories into other stories (important for the story_threads query)
    count = 200
    merged = Story.where.not(merged_story_id: nil).count
    return if merged >= count

    count.times do
      story_id = @rng.rand(1..STORIES_COUNT)
      target_id = @rng.rand(1..STORIES_COUNT)
      next if story_id == target_id
      @conn.execute("UPDATE stories SET merged_story_id = #{target_id} WHERE id = #{story_id} AND merged_story_id IS NULL")
    end
  end

  # ── Update counters ─────────────────────────────────────────────────────

  def update_counters
    print "Updating counters..."

    # All counter updates use JOIN-based UPDATEs instead of correlated subqueries
    # for performance. Correlated subqueries are O(N*M), JOIN-based are O(N+M).

    # Update score and flags on stories from votes (combined in one pass)
    @conn.execute(<<~SQL)
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
    print "."

    # Update score and flags on comments from votes (combined in one pass)
    @conn.execute(<<~SQL)
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
    print "."

    # Recalculate confidence from actual score/flags using Wilson score (comment.rb:226-245)
    z = "1.281551565545"
    z2 = "1.642213913636" # z*z
    @conn.execute(<<~SQL)
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
    print "."

    # Recalculate confidence_order from confidence + id (comment.rb:349-356)
    @conn.execute(<<~SQL)
      UPDATE comments SET confidence_order = concat(
        lpad(char(65535 - floor(confidence * 65535) using binary), 2, '\0'),
        char(id & 0xff using binary)
      )
    SQL
    print "."

    # Update reply_count and last_reply_at on comments (JOIN-based)
    @conn.execute(<<~SQL)
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
    print "."

    # Update comments_count and last_comment_at on stories (JOIN-based)
    # This counts direct comments only (not merged), matching how the app works
    @conn.execute(<<~SQL)
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
    print "."

    # Add merged story comment counts (only ~200 stories have merges)
    @conn.execute(<<~SQL)
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
    print "."

    # Update stories_count (merged stories counter cache)
    @conn.execute(<<~SQL)
      UPDATE stories s
      JOIN (
        SELECT merged_story_id, COUNT(*) AS cnt
        FROM stories
        WHERE merged_story_id IS NOT NULL
        GROUP BY merged_story_id
      ) m ON m.merged_story_id = s.id
      SET s.stories_count = m.cnt
    SQL
    print "."

    # Recalculate hotness (JOIN-based for comment points)
    @conn.execute(<<~SQL)
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
    print "."

    # Update domain stories_count
    @conn.execute(<<~SQL)
      UPDATE domains d
      JOIN (
        SELECT domain_id, COUNT(*) AS cnt
        FROM stories
        WHERE domain_id IS NOT NULL
        GROUP BY domain_id
      ) sc ON sc.domain_id = d.id
      SET d.stories_count = sc.cnt
    SQL
    print "."

    # Update user karma (JOIN-based, split into story karma + comment karma)
    # Story karma: votes on user's stories by other users
    @conn.execute(<<~SQL)
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
    print "."

    # Add comment karma: votes on user's comments by other users
    @conn.execute(<<~SQL)
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
    print "."

    # Populate keystore entries
    update_keystores
    print "."

    puts " done"
  end

  def update_keystores
    # Set thread_id counter to max thread_id from comments
    max_thread_id = @conn.select_value("SELECT MAX(thread_id) FROM comments") || 0
    @conn.execute(<<~SQL)
      INSERT INTO keystores (`key`, `value`) VALUES ('thread_id', #{max_thread_id})
      ON DUPLICATE KEY UPDATE `value` = #{max_thread_id}
    SQL

    # Per-user stories_submitted and comments_posted counters (JOIN-based query)
    values = []
    @conn.select_rows(<<~SQL).each do |user_id, sc, cc|
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
        flush_keystores(values)
        values.clear
      end
    end
    flush_keystores(values) unless values.empty?
  end

  def flush_keystores(values)
    return if values.empty?
    @conn.execute(<<~SQL)
      INSERT INTO keystores (`key`, `value`)
      VALUES #{values.join(",\n")}
      ON DUPLICATE KEY UPDATE `value` = VALUES(`value`)
    SQL
  end

  # ── Summary ─────────────────────────────────────────────────────────────

  def print_summary
    puts
    puts "=== Seeding Complete ==="
    tables = %w[users usernames stories comments votes taggings story_texts
                read_ribbons saved_stories hidden_stories hats categories tags
                domains keystores]
    total = 0
    tables.each do |t|
      count = @conn.select_value("SELECT COUNT(*) FROM #{t}")
      total += count
      puts "  %-20s %10s rows" % [t, format_number(count)]
    end
    puts "  %-20s %10s rows" % ["TOTAL", format_number(total)]
    puts

    # Disk size
    db_size = @conn.select_value(<<~SQL)
      SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024 / 1024, 2) AS size_gb
      FROM information_schema.tables
      WHERE table_schema = DATABASE()
    SQL
    puts "  Database size: #{db_size} GB"
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  def format_number(n)
    n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
  end

  def e(str)
    return str if str.nil?
    @conn.quote_string(str.to_s)
  end

  # Returns a quoted SQL string or NULL for nil values
  def sql_quote(val)
    val ? "'#{e(val)}'" : "NULL"
  end

  def generate_token(prefix)
    "#{prefix}_#{SecureRandom.alphanumeric(26)}"
  end

  def base36(length, id)
    chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    result = +""
    val = id
    length.times do
      result << chars[val % 36]
      val /= 36
    end
    result
  end

  def random_date_within(days)
    offset = @rng.rand(0..days * 24 * 3600)
    (@now - offset).strftime("%Y-%m-%d %H:%M:%S")
  end

  def sentence(word_range)
    count = @rng.rand(word_range)
    words = Array.new(count) { WORDS.sample(random: @rng) }
    words.first.capitalize + " " + words[1..].join(" ") + "."
  end

  def paragraphs(para_range)
    count = @rng.rand(para_range)
    Array.new(count) { sentence(5..20) }.join("\n\n")
  end

  # Wilson score lower bound (80% confidence) — same as comment.rb:226-245
  def wilson_confidence(score, flags)
    ups = score + flags
    downs = flags
    n = ups + downs
    return 0.0 if n == 0

    z = BigDecimal("1.281551565545")
    p = BigDecimal(ups) / BigDecimal(n)

    left = p + (1 / (2 * BigDecimal(n)) * z * z)
    right = z * Math.sqrt((p * ((1 - p) / BigDecimal(n))) + (z * z / (4 * BigDecimal(n) * BigDecimal(n))))
    under = 1.0 + ((1.0 / BigDecimal(n)) * z * z)

    confidence = (left - right) / under
    confidence.clamp(0..1).to_f
  end

  # 3-byte confidence_order as hex literal — same as comment.rb:349-356
  def confidence_order_hex(confidence, comment_id)
    ci = (65535 - (confidence * 65535).floor)
    bytes = [ci >> 8, ci & 0xff, comment_id & 0xff].pack("CCC")
    "0x" + bytes.unpack1("H*")
  end

  # Poisson-distributed random number (for realistic comment clustering)
  def poisson(lambda)
    l = Math.exp(-lambda)
    k = 0
    p = 1.0
    loop do
      k += 1
      p *= @rng.rand
      break if p <= l
    end
    k - 1
  end
end

ProductionScaleSeeder.new.run
