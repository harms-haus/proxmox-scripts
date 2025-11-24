#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2025 community-scripts ORG
# Author: Community
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/get-convex/convex-backend

APP="ConvexBackend"
var_tags="${var_tags:-backend;database}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-10}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -f /usr/local/bin/convex-local-backend ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  msg_info "Updating $APP LXC"
  DEBIAN_FRONTEND=noninteractive $STD apt-get update
  DEBIAN_FRONTEND=noninteractive $STD apt-get -y upgrade
  msg_ok "Updated $APP LXC"

  msg_info "Checking for new Convex backend release"
  LATEST_RELEASE=$(curl -s https://api.github.com/repos/get-convex/convex-backend/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
  CURRENT_VERSION=$(/usr/local/bin/convex-local-backend --version 2>/dev/null || echo "unknown")
  
  if [[ "$CURRENT_VERSION" != *"$LATEST_RELEASE"* ]] || [[ "$CURRENT_VERSION" == "unknown" ]]; then
    msg_info "Downloading latest release: $LATEST_RELEASE"
    BINARY_URL=$(curl -s https://api.github.com/repos/get-convex/convex-backend/releases/latest | grep "browser_download_url.*convex-local-backend-x86_64-unknown-linux-gnu.zip" | cut -d '"' -f 4)
    
    if [[ -n "$BINARY_URL" ]]; then
      msg_info "Stopping Service"
      systemctl stop convex-backend 2>/dev/null || true
      msg_ok "Stopped Service"

      msg_info "Downloading new binary"
      cd /tmp
      curl -fsSL "$BINARY_URL" -o convex-backend.zip
      unzip -o convex-backend.zip
      chmod +x convex-local-backend
      mv convex-local-backend /usr/local/bin/convex-local-backend
      rm -f convex-backend.zip
      msg_ok "Updated binary"

      msg_info "Starting Service"
      systemctl start convex-backend
      msg_ok "Started Service"
    fi
  else
    msg_info "Already on latest version"
  fi

  msg_ok "Updated successfully!"
  exit
}

start
# build_container will try to download install script from community repo
# Since we don't have one there, it will fail, but container will be created
# We catch the error and continue with our installation code
set +e
build_container
BUILD_EXIT=$?
set -e

# If build_container failed (404 on install script) but container exists, continue
if [[ $BUILD_EXIT -ne 0 ]]; then
  if [[ -n "${CTID:-}" ]] && pct status "$CTID" &>/dev/null; then
    msg_info "Container created, continuing with installation..."
  else
    msg_error "Failed to create container"
    exit 1
  fi
fi

description

msg_info "Installing Dependencies"
DEBIAN_FRONTEND=noninteractive $STD apt-get update
DEBIAN_FRONTEND=noninteractive $STD apt-get install -y curl wget unzip ca-certificates openssl
msg_ok "Installed Dependencies"

# Database selection
msg_info "Selecting Database"
echo ""
echo -e "${BGN}Select Database Type:${CL}"
echo -e "  1) SQLite (default, no installation needed)"
echo -e "  2) PostgreSQL"
echo -e "  3) MySQL"
echo ""
read -p "Enter choice [1-3] (default: 1): " DB_CHOICE
DB_CHOICE=${DB_CHOICE:-1}

case $DB_CHOICE in
  1)
    DB_TYPE="sqlite"
    DB_CONNECTION=""
    msg_ok "Selected SQLite (default)"
    ;;
  2)
    DB_TYPE="postgres"
    msg_info "Installing PostgreSQL"
    DEBIAN_FRONTEND=noninteractive $STD apt-get install -y postgresql postgresql-contrib
    systemctl enable postgresql
    systemctl start postgresql
    msg_ok "Installed PostgreSQL"
    
    msg_info "Waiting for PostgreSQL to be ready"
    sleep 3
    for i in {1..30}; do
      if sudo -u postgres psql -c 'SELECT 1' > /dev/null 2>&1; then
        break
      fi
      if [ $i -eq 30 ]; then
        msg_error "PostgreSQL not ready after 30 seconds"
        exit 1
      fi
      sleep 1
    done
    msg_ok "PostgreSQL is ready"
    
    msg_info "Configuring PostgreSQL"
    DB_NAME="convex_self_hosted"
    DB_USER="convex_user"
    DB_PASS=$(openssl rand -hex 16)
    
    sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" 2>/dev/null || true
    sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" 2>/dev/null || true
    sudo -u postgres psql -c "ALTER DATABASE $DB_NAME OWNER TO $DB_USER;" 2>/dev/null || true
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;" 2>/dev/null || true
    
    DB_CONNECTION="postgresql://$DB_USER:$DB_PASS@localhost:5432"
    
    # Verify database connection
    if ! sudo -u postgres psql -d "$DB_NAME" -c 'SELECT 1' > /dev/null 2>&1; then
      msg_error "Failed to verify PostgreSQL connection"
      exit 1
    fi
    msg_ok "Configured PostgreSQL"
    ;;
  3)
    DB_TYPE="mysql"
    msg_info "Installing MySQL"
    # Set debconf for non-interactive MySQL installation
    debconf-set-selections <<< "mysql-server mysql-server/root_password password temp_root_pass"
    debconf-set-selections <<< "mysql-server mysql-server/root_password_again password temp_root_pass"
    DEBIAN_FRONTEND=noninteractive $STD apt-get install -y mysql-server
    systemctl enable mysql
    systemctl start mysql
    msg_ok "Installed MySQL"
    
    msg_info "Waiting for MySQL to be ready"
    sleep 3
    for i in {1..30}; do
      if mysql -uroot -ptemp_root_pass -e 'SELECT 1' > /dev/null 2>&1; then
        break
      fi
      if [ $i -eq 30 ]; then
        msg_error "MySQL not ready after 30 seconds"
        exit 1
      fi
      sleep 1
    done
    msg_ok "MySQL is ready"
    
    msg_info "Configuring MySQL"
    DB_NAME="convex_self_hosted"
    DB_USER="convex_user"
    DB_PASS=$(openssl rand -hex 16)
    
    # Create database and user
    mysql -uroot -ptemp_root_pass <<EOF 2>/dev/null || true
CREATE DATABASE IF NOT EXISTS $DB_NAME;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
    
    # Remove temporary root password (optional, for security)
    mysql -uroot -ptemp_root_pass -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH auth_socket;" 2>/dev/null || true
    
    DB_CONNECTION="mysql://$DB_USER:$DB_PASS@localhost:3306"
    
    # Verify database connection
    if ! mysql -u"$DB_USER" -p"$DB_PASS" -e "USE $DB_NAME; SELECT 1;" > /dev/null 2>&1; then
      msg_error "Failed to verify MySQL connection"
      exit 1
    fi
    msg_ok "Configured MySQL"
    ;;
  *)
    msg_error "Invalid choice, defaulting to SQLite"
    DB_TYPE="sqlite"
    DB_CONNECTION=""
    ;;
esac

# Download and install Convex backend binary
msg_info "Downloading Convex Backend"
LATEST_RELEASE=$(curl -s https://api.github.com/repos/get-convex/convex-backend/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
BINARY_URL=$(curl -s https://api.github.com/repos/get-convex/convex-backend/releases/latest | grep "browser_download_url.*convex-local-backend-x86_64-unknown-linux-gnu.zip" | cut -d '"' -f 4)

if [[ -z "$BINARY_URL" ]]; then
  msg_error "Failed to get binary URL"
  exit 1
fi

cd /tmp
curl -fsSL "$BINARY_URL" -o convex-backend.zip
unzip -o convex-backend.zip
chmod +x convex-local-backend
mv convex-local-backend /usr/local/bin/convex-local-backend
rm -f convex-backend.zip
msg_ok "Downloaded Convex Backend ($LATEST_RELEASE)"

# Create working directory
msg_info "Creating Configuration Directory"
mkdir -p /opt/convex-backend
cd /opt/convex-backend
msg_ok "Created Configuration Directory"

# Generate instance secret and admin key
msg_info "Generating Instance Secret"
INSTANCE_NAME="convex-self-hosted"
INSTANCE_SECRET=$(openssl rand -hex 32)
echo "$INSTANCE_SECRET" > /opt/convex-backend/instance_secret.txt
chmod 600 /opt/convex-backend/instance_secret.txt
msg_ok "Generated Instance Secret"

msg_info "Generating Admin Key"
ADMIN_KEY=""
msg_info "Installing Rust and build dependencies (this may take a few minutes)..."
# Install Rust with stable toolchain for key generation
# cmake is required for some Rust dependencies like libz-ng-sys
DEBIAN_FRONTEND=noninteractive $STD apt-get install -y build-essential git pkg-config libssl-dev cmake
if ! command -v cargo &> /dev/null; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal 2>&1 | grep -v "info:" || true
  source "$HOME/.cargo/env" 2>/dev/null || export PATH="$HOME/.cargo/bin:$PATH"
fi

# Verify Rust is installed
if ! command -v cargo &> /dev/null; then
  msg_warn "Rust installation failed. Admin key will need to be generated manually."
  ADMIN_KEY="<will-generate-after-start>"
else
  msg_info "Rust installed. Compiling keybroker (this may take 5-15 minutes)..."
  msg_info "Please be patient - Rust compilation is in progress..."
  
  # Clone repo temporarily to get keybroker
  cd /tmp
  if [[ ! -d /tmp/convex-backend-keygen ]]; then
    if ! git clone --depth 1 https://github.com/get-convex/convex-backend.git convex-backend-keygen 2>/dev/null; then
      msg_error "Failed to clone repository"
      ADMIN_KEY="<will-generate-after-start>"
    fi
  fi

  if [[ -d /tmp/convex-backend-keygen ]] && [[ -z "$ADMIN_KEY" ]]; then
    cd /tmp/convex-backend-keygen
    
    # Compile and run keybroker with timeout (30 minutes max)
    msg_info "Compiling keybroker tool (this will take several minutes)..."
    
    # Build and run - use cargo run with release mode for better performance
    # Save all output to log file, then extract just the key line
    # Note: timeout uses seconds (1800 = 30 minutes)
    msg_info "Building and running keybroker..."
    if timeout 1800 cargo run --release -p keybroker --bin generate_key -- "$INSTANCE_NAME" "$INSTANCE_SECRET" > /tmp/keybroker_output.log 2>&1; then
      CARGO_EXIT_CODE=0
      msg_info "Key generation completed successfully"
    else
      CARGO_EXIT_CODE=$?
      msg_warn "Cargo command exited with code $CARGO_EXIT_CODE"
    fi
    
    # Extract the admin key from the output (should be on its own line)
    ADMIN_KEY_OUTPUT=$(cat /tmp/keybroker_output.log 2>/dev/null || echo "")
    
    if [[ $CARGO_EXIT_CODE -ne 0 ]]; then
      msg_info "Check /tmp/keybroker_output.log for details"
    fi
    
    # Try multiple patterns to extract the admin key
    # Expected format: instance_name|key (e.g., "convex-self-hosted|abc123...")
    if [[ -n "$ADMIN_KEY_OUTPUT" ]]; then
      # First, try to find a line that matches the exact pattern: instance_name|alphanumeric
      ADMIN_KEY=$(echo "$ADMIN_KEY_OUTPUT" | grep -oE "${INSTANCE_NAME}\|[a-zA-Z0-9]+" | head -1 | tr -d '\r\n' | xargs || echo "")
      
      # If that didn't work, look for lines containing the instance name and pipe
      if [[ -z "$ADMIN_KEY" ]]; then
        ADMIN_KEY=$(echo "$ADMIN_KEY_OUTPUT" | grep "${INSTANCE_NAME}" | grep "|" | head -1 | tr -d '\r\n' | xargs || echo "")
      fi
      
      # If still no key, try extracting from any line with the instance name
      if [[ -z "$ADMIN_KEY" ]] && echo "$ADMIN_KEY_OUTPUT" | grep -q "$INSTANCE_NAME"; then
        # Look for the pattern instance_name| followed by alphanumeric characters
        ADMIN_KEY=$(echo "$ADMIN_KEY_OUTPUT" | sed -n "s/.*\(${INSTANCE_NAME}|[a-zA-Z0-9]\+\).*/\1/p" | head -1 | tr -d '\r\n' | xargs || echo "")
      fi
      
      # Last resort: find any line that looks like a key (instance_name| followed by alphanumeric)
      if [[ -z "$ADMIN_KEY" ]]; then
        ADMIN_KEY=$(echo "$ADMIN_KEY_OUTPUT" | awk "/${INSTANCE_NAME}\|/{print; exit}" | tr -d '\r\n' | xargs || echo "")
      fi
    fi
    
    if [[ -n "$ADMIN_KEY" ]] && [[ "$ADMIN_KEY" =~ ^${INSTANCE_NAME}\| ]] && [[ ${#ADMIN_KEY} -gt ${#INSTANCE_NAME} ]]; then
      echo "$ADMIN_KEY" > /opt/convex-backend/admin_key.txt
      chmod 600 /opt/convex-backend/admin_key.txt
      msg_ok "Generated Admin Key: ${ADMIN_KEY:0:30}..."
    else
      msg_warn "Key generation failed or output format unexpected."
      msg_info "Full output saved to /tmp/keybroker_output.log"
      msg_info "Cargo exit code: $CARGO_EXIT_CODE"
      if [[ -f /tmp/keybroker_output.log ]]; then
        msg_info "Last 30 lines of output:"
        tail -30 /tmp/keybroker_output.log
        msg_info "Searching for lines containing '${INSTANCE_NAME}':"
        grep -i "${INSTANCE_NAME}" /tmp/keybroker_output.log | head -5 || echo "  (no matches found)"
      else
        msg_warn "Log file /tmp/keybroker_output.log not found"
      fi
      ADMIN_KEY="<will-generate-after-start>"
    fi
    
    cd /opt/convex-backend
    rm -rf /tmp/convex-backend-keygen
  fi
  
  # Ensure ADMIN_KEY is set
  if [[ -z "$ADMIN_KEY" ]]; then
    ADMIN_KEY="<will-generate-after-start>"
  fi
fi

# Dashboard installation (optional)
echo ""
echo -e "${BGN}Install Convex Dashboard?${CL}"
echo -e "  The dashboard provides a web UI for managing your Convex backend."
read -p "Install dashboard? [y/N]: " INSTALL_DASHBOARD
INSTALL_DASHBOARD=${INSTALL_DASHBOARD:-n}

if [[ "$INSTALL_DASHBOARD" =~ ^[Yy]$ ]]; then
  msg_info "Installing Dashboard (via Docker)"
  # Install Docker for dashboard
  DEBIAN_FRONTEND=noninteractive $STD apt-get install -y docker.io
  systemctl enable docker
  systemctl start docker
  
  msg_info "Waiting for Docker to be ready"
  sleep 2
  for i in {1..30}; do
    if docker info > /dev/null 2>&1; then
      break
    fi
    if [ $i -eq 30 ]; then
      msg_error "Docker not ready after 30 seconds"
      exit 1
    fi
    sleep 1
  done
  msg_ok "Docker is ready"
  
  msg_info "Downloading Dashboard"
  # Dashboard is available as a Docker image
  docker pull ghcr.io/get-convex/convex-dashboard:latest 2>/dev/null || true
  
  # Create dashboard service
  cat <<EOF > /etc/systemd/system/convex-dashboard.service
[Unit]
Description=Convex Dashboard Service
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/usr/bin/docker run --rm -p 6791:6791 -e NEXT_PUBLIC_DEPLOYMENT_URL=http://${IP}:3210 ghcr.io/get-convex/convex-dashboard:latest
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  
  systemctl daemon-reload
  systemctl enable convex-dashboard
  msg_ok "Configured Dashboard"
fi

# Create systemd service
msg_info "Creating Systemd Service"
INSTANCE_NAME="convex-self-hosted"
INSTANCE_SECRET=$(cat /opt/convex-backend/instance_secret.txt)

# Build service command
SERVICE_CMD="/usr/local/bin/convex-local-backend --instance-name $INSTANCE_NAME --instance-secret $INSTANCE_SECRET --port 3210 --http-actions-port 3211 --disable-beacon"

if [[ "$DB_TYPE" == "postgres" ]]; then
  SERVICE_CMD="$SERVICE_CMD --db postgres-v5 $DB_CONNECTION"
elif [[ "$DB_TYPE" == "mysql" ]]; then
  SERVICE_CMD="$SERVICE_CMD --db mysql-v5 $DB_CONNECTION"
fi

cat <<EOF > /etc/systemd/system/convex-backend.service
[Unit]
Description=Convex Backend Service
After=network.target
$(if [[ "$DB_TYPE" == "postgres" ]]; then echo "Requires=postgresql.service"; fi)
$(if [[ "$DB_TYPE" == "mysql" ]]; then echo "Requires=mysql.service"; fi)

[Service]
Type=simple
User=root
WorkingDirectory=/opt/convex-backend
ExecStart=$SERVICE_CMD
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable convex-backend
msg_ok "Created Systemd Service"

# Start service
msg_info "Starting Convex Backend"
systemctl start convex-backend
sleep 3
if systemctl is-active --quiet convex-backend; then
  msg_ok "Started Convex Backend"
else
  msg_warn "Service may not have started correctly. Check logs with: journalctl -u convex-backend"
fi

# Generate admin key if not already generated
if [[ "$ADMIN_KEY" == "<will-generate-after-start>" ]]; then
  msg_info "Admin key generation skipped (requires Rust compilation)"
  msg_info "To generate admin key manually, run:"
  echo ""
  echo -e "${TAB}${GN}Option 1 - Quick (if Rust is installed):${CL}"
  echo -e "${TAB}  cd /tmp"
  echo -e "${TAB}  git clone --depth 1 https://github.com/get-convex/convex-backend.git convex-keygen"
  echo -e "${TAB}  cd convex-keygen"
  echo -e "${TAB}  cargo run -p keybroker --bin generate_key -- convex-self-hosted \$(cat /opt/convex-backend/instance_secret.txt)"
  echo -e "${TAB}  rm -rf /tmp/convex-keygen"
  echo ""
  echo -e "${TAB}${GN}Option 2 - Install Rust first:${CL}"
  echo -e "${TAB}  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
  echo -e "${TAB}  source \$HOME/.cargo/env"
  echo -e "${TAB}  Then follow Option 1"
  echo ""
  echo -e "${TAB}${YW}Note:${CL} Admin key generation requires compiling Rust code and may take 5-15 minutes."
  echo -e "${TAB}The Convex backend will work without an admin key, but admin features will be limited."
  echo ""
  ADMIN_KEY="<see-instructions-above>"
fi

# Start dashboard if installed
if [[ "$INSTALL_DASHBOARD" =~ ^[Yy]$ ]]; then
  msg_info "Starting Dashboard"
  systemctl start convex-dashboard
  sleep 2
  if systemctl is-active --quiet convex-dashboard; then
    msg_ok "Started Dashboard"
  else
    msg_warn "Dashboard may not have started correctly. Check logs with: journalctl -u convex-dashboard"
  fi
fi

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo ""
echo -e "${INFO}${YW}Access Information:${CL}"
echo -e "${TAB}${GN}Backend URL:${CL} ${BGN}http://${IP}:3210${CL}"
echo -e "${TAB}${GN}HTTP Actions URL:${CL} ${BGN}http://${IP}:3211${CL}"
if [[ "$INSTALL_DASHBOARD" =~ ^[Yy]$ ]]; then
  echo -e "${TAB}${GN}Dashboard URL:${CL} ${BGN}http://${IP}:6791${CL}"
fi
echo ""
echo -e "${INFO}${YW}Configuration:${CL}"
echo -e "${TAB}${GN}Instance Name:${CL} ${BGN}${INSTANCE_NAME}${CL}"
echo -e "${TAB}${GN}Database Type:${CL} ${BGN}${DB_TYPE}${CL}"
if [[ "$DB_TYPE" != "sqlite" ]]; then
  echo -e "${TAB}${GN}Database Name:${CL} ${BGN}convex_self_hosted${CL}"
fi
echo ""
echo -e "${INFO}${YW}Admin Key:${CL}"
if [[ "$ADMIN_KEY" != "<will-generate-after-start>" ]] && [[ "$ADMIN_KEY" != "<see-instructions-above>" ]]; then
  echo -e "${TAB}${GN}${ADMIN_KEY}${CL}"
  echo -e "${TAB}${YW}(Saved to: /opt/convex-backend/admin_key.txt)${CL}"
else
  echo -e "${TAB}${RD}${ADMIN_KEY}${CL}"
fi
echo ""
echo -e "${INFO}${YW}To use with Convex CLI, add to your .env.local:${CL}"
echo -e "${TAB}CONVEX_SELF_HOSTED_URL='http://${IP}:3210'"
if [[ "$ADMIN_KEY" != "<will-generate-after-start>" ]] && [[ "$ADMIN_KEY" != "<see-instructions-above>" ]]; then
  echo -e "${TAB}CONVEX_SELF_HOSTED_ADMIN_KEY='${ADMIN_KEY}'"
fi
echo ""
echo -e "${INFO}${YW}Service Management:${CL}"
echo -e "${TAB}${GN}View logs:${CL} journalctl -u convex-backend -f"
if [[ "$INSTALL_DASHBOARD" =~ ^[Yy]$ ]]; then
  echo -e "${TAB}${GN}Dashboard logs:${CL} journalctl -u convex-dashboard -f"
fi
echo -e "${TAB}${GN}Restart service:${CL} systemctl restart convex-backend"
echo ""

