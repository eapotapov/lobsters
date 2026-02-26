#!/bin/bash
#
# Lobsters SQLite Migration Study - Full Server Setup
#
# Reproduces three side-by-side Lobsters instances for comparing
# MySQL (before), SQLite (after migration), and MySQL (after revert).
#
# Tested on Ubuntu 24.04 LTS. Run as a regular user (not root).
# The script will use sudo where needed for system packages.
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh
#
set -euo pipefail

LOBSTERS_DIR=~/lobsters
REPO_URL=https://github.com/lobsters/lobsters.git

# Commits for each version
COMMIT_BEFORE="f5f98d6e"   # Last main before SQLite merge
COMMIT_SQLITE="74544e96"   # Merge commit of PR #1871 (SQLite migration)
COMMIT_REVERT="fce8b853"   # After revert + cleanup

MYSQL_USER="lobsters"
MYSQL_PASS="lobsters"

echo "=== Step 1: Install system dependencies ==="
sudo apt-get update
sudo apt-get install -y \
  build-essential pkg-config autoconf bison rustc \
  libssl-dev libreadline-dev zlib1g-dev libyaml-dev libffi-dev \
  libvips-dev \
  libmariadb-dev-compat libmariadb-dev \
  libsqlite3-dev \
  mysql-server \
  nginx \
  wrk

echo "=== Step 2: Install rbenv + Ruby 4.0.0 ==="
if [ ! -d ~/.rbenv ]; then
  git clone https://github.com/rbenv/rbenv.git ~/.rbenv
  mkdir -p ~/.rbenv/plugins
  git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build
fi

export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
eval "$(rbenv init -)"

if ! rbenv versions | grep -q "4.0.0"; then
  rbenv install 4.0.0
fi
rbenv global 4.0.0

# Add to shell profile if not already there
for profile in ~/.bashrc ~/.zshrc; do
  if [ -f "$profile" ] && ! grep -q 'rbenv init' "$profile"; then
    echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> "$profile"
    echo 'eval "$(rbenv init -)"' >> "$profile"
  fi
done

echo "=== Step 3: Configure MySQL ==="
sudo mysql -e "CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'127.0.0.1' IDENTIFIED WITH mysql_native_password BY '${MYSQL_PASS}';" || true
sudo mysql -e "CREATE DATABASE IF NOT EXISTS lobsters_before;"
sudo mysql -e "CREATE DATABASE IF NOT EXISTS lobsters_revert;"
sudo mysql -e "GRANT ALL PRIVILEGES ON lobsters_before.* TO '${MYSQL_USER}'@'127.0.0.1';"
sudo mysql -e "GRANT ALL PRIVILEGES ON lobsters_revert.* TO '${MYSQL_USER}'@'127.0.0.1';"
sudo mysql -e "FLUSH PRIVILEGES;"

echo "=== Step 4: Clone three versions of Lobsters ==="
mkdir -p "$LOBSTERS_DIR"

clone_version() {
  local dir="$1"
  local commit="$2"

  if [ ! -d "$LOBSTERS_DIR/$dir" ]; then
    git clone "$REPO_URL" "$LOBSTERS_DIR/$dir"
  fi
  cd "$LOBSTERS_DIR/$dir"
  git checkout "$commit"
}

clone_version "1-before-sqlite" "$COMMIT_BEFORE"
clone_version "2-after-sqlite"  "$COMMIT_SQLITE"
clone_version "3-after-revert"  "$COMMIT_REVERT"

echo "=== Step 5: Install database.yml configs ==="
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cp "$SCRIPT_DIR/database-before.yml"  "$LOBSTERS_DIR/1-before-sqlite/config/database.yml"
cp "$SCRIPT_DIR/database-sqlite.yml"  "$LOBSTERS_DIR/2-after-sqlite/config/database.yml"
cp "$SCRIPT_DIR/database-revert.yml"  "$LOBSTERS_DIR/3-after-revert/config/database.yml"

echo "=== Step 6: Allow all hosts in development.rb ==="
for dir in 1-before-sqlite 2-after-sqlite 3-after-revert; do
  devconf="$LOBSTERS_DIR/$dir/config/environments/development.rb"
  if ! grep -q 'config.hosts.clear' "$devconf"; then
    # Insert config.hosts.clear after "Rails.application.configure do"
    sed -i '/Rails.application.configure do/a\  config.hosts.clear' "$devconf"
  fi
done

echo "=== Step 7: Bundle install for all three versions ==="
for dir in 1-before-sqlite 2-after-sqlite 3-after-revert; do
  echo "--- bundle install: $dir ---"
  cd "$LOBSTERS_DIR/$dir"
  bundle install
done

echo "=== Step 8: Set up databases and seed data ==="
# Version 1: MySQL (before)
echo "--- db:setup + fake_data: 1-before-sqlite ---"
cd "$LOBSTERS_DIR/1-before-sqlite"
bin/rails db:setup
echo "y" | bin/rails fake_data

# Version 2: SQLite
echo "--- db:setup + fake_data: 2-after-sqlite ---"
cd "$LOBSTERS_DIR/2-after-sqlite"
bin/rails db:setup
echo "y" | bin/rails fake_data

# Version 3: MySQL (revert)
echo "--- db:setup + fake_data: 3-after-revert ---"
cd "$LOBSTERS_DIR/3-after-revert"
bin/rails db:setup
echo "y" | bin/rails fake_data

echo "=== Step 9: Update test user password to 'testtest' ==="
for dir in 1-before-sqlite 2-after-sqlite 3-after-revert; do
  cd "$LOBSTERS_DIR/$dir"
  bin/rails runner "u = User.find_by(username: 'test'); u.password = 'testtest'; u.password_confirmation = 'testtest'; u.save!"
done

echo "=== Step 10: Install systemd user services ==="
mkdir -p ~/.config/systemd/user
cp "$SCRIPT_DIR/lobsters-before.service"       ~/.config/systemd/user/
cp "$SCRIPT_DIR/lobsters-after.service"        ~/.config/systemd/user/
cp "$SCRIPT_DIR/lobsters-after-revert.service" ~/.config/systemd/user/

systemctl --user daemon-reload
systemctl --user enable lobsters-before lobsters-after lobsters-after-revert
systemctl --user start  lobsters-before lobsters-after lobsters-after-revert

# Enable lingering so services run without an active login session
loginctl enable-linger "$USER"

echo "=== Step 11: Install nginx config ==="
sudo cp "$SCRIPT_DIR/lobsters-nginx.conf" /etc/nginx/sites-available/lobsters
sudo ln -sf /etc/nginx/sites-available/lobsters /etc/nginx/sites-enabled/lobsters
sudo nginx -t
sudo systemctl reload nginx

echo ""
echo "=== Setup complete! ==="
echo ""
echo "Services:"
systemctl --user status lobsters-before lobsters-after lobsters-after-revert --no-pager
echo ""
echo "Add these to /etc/hosts on your client machine (pointing to this server's IP):"
echo "  <server-ip>  lobsters-before lobsters-after lobsters-revert"
echo ""
echo "Test login: username=test, password=testtest"
