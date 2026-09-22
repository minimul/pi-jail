#!/bin/bash
# make-rails-app.sh DIR RAILS_PORT DEVTOOLS_PORT
# Creates a minimal Rails app in DIR and drops in everything rails-compose.yml
# expects (compose.yml, .env, Dockerfile-dev, Dockerfile-dev-postgres,
# config/sidekiq.yml).  Runs inside the VM as the unprivileged user; the
# generator runs as root *inside* a rootless container, which is this user on
# the host, so every generated file lands owned by the user.  Idempotent.
set -euo pipefail
DIR=$1; RAILS_PORT=$2; DEVTOOLS_PORT=$3
POC_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$HOME/www/demo-3000"
mkdir -p "$DIR"

if [ ! -f "$DIR/Gemfile" ]; then
    if [ "$TEMPLATE" != "$DIR" ] && [ -f "$TEMPLATE/Gemfile" ]; then
        echo "==> $DIR: copying the app generated in $TEMPLATE"
        cp -a "$TEMPLATE/." "$DIR/"
        rm -rf "$DIR/log" "$DIR/tmp"
    else
        echo "==> $DIR: rails new (inside the rootless daemon)"
        docker run --rm -v "$DIR:/app" ruby:3.3 bash -ec '
            apt-get update -qq >/dev/null
            apt-get install -y -qq --no-install-recommends libpq-dev >/dev/null
            gem install rails -v "~> 8.0.0" --no-document -q
            cd /tmp
            rails new demo --database=postgresql --skip-bundle --skip-git \
                --skip-docker --skip-kamal --skip-thruster --skip-solid \
                --skip-javascript --skip-hotwire --skip-jbuilder \
                --skip-action-mailbox --skip-action-text --skip-active-storage \
                --skip-action-cable --skip-system-test --skip-test --skip-ci \
                --skip-rubocop --skip-brakeman --skip-bootsnap --skip-dev-gems
            cd /tmp/demo
            printf "\ngem \"sidekiq\"\ngem \"good_job\"\n" >> Gemfile
            bundle lock
            cp -a /tmp/demo/. /app/
        '
    fi
fi
mkdir -p "$DIR/log" "$DIR/tmp" "$DIR/config/initializers" "$DIR/bin"

cp "$POC_DIR/rails-compose.yml" "$DIR/compose.yml"

cat > "$DIR/.env" <<EOF
RAILS_PORT=$RAILS_PORT
DEVTOOLS_PORT=$DEVTOOLS_PORT
DB_PASSWORD=postgres
REDIS_URL=redis://redis:6379/0
EOF

cat > "$DIR/Dockerfile-dev" <<'EOF'
FROM ruby:3.3
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends libpq-dev postgresql-client git curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /rails
# Gems land in /usr/local/bundle; compose seeds the 'bundle' volume from here.
COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4
ENTRYPOINT ["/rails/bin/docker-entrypoint-dev"]
EXPOSE 3000
CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
EOF

cat > "$DIR/Dockerfile-dev-postgres" <<'EOF'
FROM postgres:18
EOF

cat > "$DIR/config/sidekiq.yml" <<'EOF'
:concurrency: 2
:queues:
  - default
EOF

cat > "$DIR/config/database.yml" <<'EOF'
default: &default
  adapter: postgresql
  encoding: unicode
  host: db
  username: postgres
  password: <%= ENV.fetch("DB_PASSWORD", "postgres") %>
  pool: 5
development:
  <<: *default
  database: demo_development
test:
  <<: *default
  database: demo_test
EOF

cat > "$DIR/config/initializers/poc.rb" <<'EOF'
# pi-jail POC: allow requests by compose service name (http://rails:3000 from the jail).
Rails.application.config.hosts.clear
EOF

cat > "$DIR/bin/docker-entrypoint-dev" <<'EOF'
#!/bin/bash
set -e
until pg_isready -h db -U postgres -q; do sleep 1; done
rm -f /rails/tmp/pids/server.pid
if ! ls /rails/db/migrate/*good_job* >/dev/null 2>&1; then
    bin/rails generate good_job:install
fi
bin/rails db:prepare
exec "$@"
EOF
chmod +x "$DIR/bin/docker-entrypoint-dev"
echo "==> $DIR ready (rails on 127.0.0.1:$RAILS_PORT)"
