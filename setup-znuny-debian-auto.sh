#!/bin/bash
#
# Znuny 6.5 Automated Installation Script for Debian/Ubuntu
# This script automates the COMPLETE installation of Znuny 6.5 with PostgreSQL
# No manual intervention required - perfect for testing environments
# 
# Author: System Administrator
# Date: 2025-06-22
# Version: 2.0
#
# Usage: sudo bash setup-znuny-debian-auto.sh
#

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration variables
ZNUNY_VERSION="6.5.15"
ZNUNY_DOWNLOAD_URL="https://download.znuny.org/releases/znuny-${ZNUNY_VERSION}.tar.gz"
INSTALL_DIR="/opt"
ZNUNY_USER="znuny"
WEB_GROUP="www-data"
LOG_FILE="/var/log/znuny-setup-$(date +%Y%m%d_%H%M%S).log"
CREDENTIALS_FILE="/root/znuny-credentials.txt"

# Global variables for credentials - auto-generated
DB_PASSWORD=""
ADMIN_PASSWORD=""
LOCAL_IP=""
HOSTNAME=""

# Database configuration
DB_TYPE="postgresql"
DB_HOST="localhost"
DB_PORT="5432"
DB_NAME="znuny"
DB_USER="znuny"

# Function to log messages
log_message() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Mask sensitive information in logs
    local masked_message=$(echo "$message" | sed -E 's/(password|passwd|pwd)[:=][^ ]*/\1:[HIDDEN]/gi')
    
    echo "${timestamp} [${level}] ${masked_message}" >> "$LOG_FILE"
    
    case $level in
        ERROR)
            echo -e "${RED}[ERROR]${NC} $message" >&2
            ;;
        WARN)
            echo -e "${YELLOW}[WARN]${NC} $message"
            ;;
        INFO)
            echo -e "${GREEN}[INFO]${NC} $message"
            ;;
        *)
            echo "$message"
            ;;
    esac
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_message ERROR "This script must be run as root or with sudo"
        exit 1
    fi
}

# Function to detect OS
detect_os() {
    if [[ -f /etc/debian_version ]]; then
        if [[ -f /etc/lsb-release ]]; then
            . /etc/lsb-release
            OS_TYPE="ubuntu"
            OS_VERSION=$DISTRIB_RELEASE
        else
            OS_TYPE="debian"
            OS_VERSION=$(cat /etc/debian_version)
        fi
    else
        log_message ERROR "This script only supports Debian-based systems"
        exit 1
    fi
    
    log_message INFO "Detected OS: $OS_TYPE $OS_VERSION"
}

# Function to check prerequisites
check_prerequisites() {
    log_message INFO "Checking prerequisites..."
    
    # Check Perl version
    if ! command -v perl &> /dev/null; then
        log_message ERROR "Perl is not installed"
        exit 1
    fi
    
    PERL_VERSION=$(perl -e 'print $]')
    PERL_VERSION_NUM=$(perl -e 'printf "%d%03d", split(/\./, substr($], 0, 5))')
    if [[ $PERL_VERSION_NUM -lt 5016 ]]; then
        log_message ERROR "Perl version must be 5.16.0 or higher. Current: $PERL_VERSION"
        exit 1
    fi
    log_message INFO "Perl version: $PERL_VERSION ✓"
    
    # Check if bc is installed (needed for disk space check)
    if ! command -v bc &> /dev/null; then
        apt-get update -qq
        apt-get install -y bc
    fi
    
    # Check disk space (minimum 2GB)
    AVAILABLE_SPACE=$(df -BG /opt | awk 'NR==2 {print $4}' | sed 's/G//')
    # Handle decimal values
    AVAILABLE_SPACE=${AVAILABLE_SPACE%%.*}
    if [[ -z "$AVAILABLE_SPACE" ]] || [[ $AVAILABLE_SPACE -lt 2 ]]; then
        log_message ERROR "Insufficient disk space. At least 2GB required in /opt"
        exit 1
    fi
    log_message INFO "Disk space: ${AVAILABLE_SPACE}GB available ✓"
}

# Function to generate secure password
generate_password() {
    local length=${1:-16}
    # Generate password with alphanumeric characters only
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-$length
}

# Function to install PostgreSQL
install_postgresql() {
    log_message INFO "Installing PostgreSQL..."
    
    apt-get update -qq
    apt-get install -y postgresql postgresql-contrib
    
    # Start and enable PostgreSQL
    systemctl start postgresql
    systemctl enable postgresql
    
    log_message INFO "PostgreSQL installed successfully"
}

# Function to setup PostgreSQL database
setup_postgresql_db() {
    log_message INFO "Setting up PostgreSQL database..."
    
    # Auto-generate database password
    DB_PASSWORD=$(generate_password)
    if [[ -z "$DB_PASSWORD" ]]; then
        log_message ERROR "Failed to generate database password"
        exit 1
    fi
    
    log_message INFO "Generated database credentials"
    log_message INFO "Database user: ${DB_USER}"
    
    # Create database and user
    log_message INFO "Creating database user: ${DB_USER}"
    log_message INFO "Creating database: ${DB_NAME}"
    
    if ! command -v psql &> /dev/null; then
        log_message ERROR "psql command not found. PostgreSQL may not be installed correctly."
        exit 1
    fi
    
    su - postgres -c "psql" <<EOF
-- Drop user and database if they exist (for re-runs)
DROP DATABASE IF EXISTS ${DB_NAME};
DROP USER IF EXISTS ${DB_USER};

-- Create user
CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';

-- Create database
CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};

-- Connect to the database and set default privileges
\c ${DB_NAME}
ALTER SCHEMA public OWNER TO ${DB_USER};
GRANT ALL ON SCHEMA public TO ${DB_USER};
EOF

    # Check if psql command succeeded
    if [ $? -ne 0 ]; then
        log_message ERROR "Failed to create database and user"
        exit 1
    fi
    
    log_message INFO "Database and user created successfully"
    
    # Configure PostgreSQL authentication
    # Find PostgreSQL version and config directory
    if command -v pg_config &> /dev/null; then
        PG_VERSION=$(pg_config --version | grep -oP '\d+' | head -1)
    else
        # Try to detect from directory structure
        PG_VERSION=$(ls -1 /etc/postgresql/ 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -1)
    fi
    
    if [ -z "$PG_VERSION" ]; then
        log_message ERROR "Could not determine PostgreSQL version"
        exit 1
    fi
    
    PG_CONFIG_DIR="/etc/postgresql/${PG_VERSION}/main"
    
    if [ ! -d "$PG_CONFIG_DIR" ]; then
        log_message ERROR "PostgreSQL config directory not found: $PG_CONFIG_DIR"
        exit 1
    fi
    
    # Backup pg_hba.conf
    cp "${PG_CONFIG_DIR}/pg_hba.conf" "${PG_CONFIG_DIR}/pg_hba.conf.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Check if authentication line already exists
    if ! grep -q "^local.*${DB_NAME}.*${DB_USER}" "${PG_CONFIG_DIR}/pg_hba.conf"; then
        # Add authentication line for znuny user before the default local line
        sed -i "/^local.*all.*all/i local   ${DB_NAME}       ${DB_USER}                                md5" "${PG_CONFIG_DIR}/pg_hba.conf" || {
            log_message ERROR "Failed to update pg_hba.conf"
            exit 1
        }
    fi
    
    # Reload PostgreSQL
    systemctl reload postgresql
    
    log_message INFO "PostgreSQL database configured successfully"
}

# Function to install system dependencies
install_system_dependencies() {
    log_message INFO "Installing system dependencies..."
    
    apt-get update -qq
    
    # Install Apache and other system packages
    apt-get install -y \
        apache2 \
        libapache2-mod-perl2 \
        build-essential \
        libssl-dev \
        libexpat1-dev \
        libxml2-dev \
        libxslt1-dev \
        libyaml-dev \
        libgd-dev \
        libpq-dev \
        curl \
        wget \
        git \
        bc
    
    log_message INFO "System dependencies installed successfully"
}

# Function to install Perl modules
install_perl_modules() {
    log_message INFO "Installing Perl modules..."
    
    # Install core required Perl modules via apt
    apt-get install -y \
        libdbi-perl \
        libdbd-pg-perl \
        libcgi-pm-perl \
        libwww-perl \
        libxml-libxml-perl \
        libxml-parser-perl \
        libtemplate-perl \
        libjson-xs-perl \
        libmail-imapclient-perl \
        libtext-csv-perl \
        libdatetime-perl \
        libmoo-perl \
        libnet-dns-perl \
        libyaml-libyaml-perl \
        libtext-csv-xs-perl \
        libio-socket-ssl-perl \
        libcrypt-eksblowfish-perl \
        libapache-dbi-perl \
        libmime-tools-perl \
        libcrypt-cbc-perl \
        libcrypt-rijndael-perl
    
    if [[ $? -ne 0 ]]; then
        log_message ERROR "Failed to install Perl modules"
        exit 1
    fi
    
    log_message INFO "Core Perl modules installed successfully"
    
    # Install additional Perl modules via CPAN if needed
    cpan -i Encode::HanExtra Archive::Tar Archive::Zip || {
        log_message WARN "Some optional CPAN modules failed to install"
    }
}

# Function to download and install Znuny
install_znuny() {
    log_message INFO "Installing Znuny ${ZNUNY_VERSION}..."
    
    cd "${INSTALL_DIR}"
    
    # Download Znuny if not already present
    if [[ ! -f "znuny-${ZNUNY_VERSION}.tar.gz" ]]; then
        log_message INFO "Downloading Znuny ${ZNUNY_VERSION}..."
        
        # Show download progress
        echo -e "${BLUE}Downloading from: ${ZNUNY_DOWNLOAD_URL}${NC}"
        
        # Try download with retry logic
        local retry_count=0
        local max_retries=3
        
        while [[ $retry_count -lt $max_retries ]]; do
            if wget --progress=bar:force "$ZNUNY_DOWNLOAD_URL" -O "znuny-${ZNUNY_VERSION}.tar.gz.tmp" 2>&1 | \
                while IFS= read -r line; do
                    echo -ne "\r${line}"
                done; then
                echo # New line after progress
                mv "znuny-${ZNUNY_VERSION}.tar.gz.tmp" "znuny-${ZNUNY_VERSION}.tar.gz"
                break
            else
                retry_count=$((retry_count + 1))
                log_message WARN "Download attempt $retry_count failed"
                rm -f "znuny-${ZNUNY_VERSION}.tar.gz.tmp"
                if [[ $retry_count -lt $max_retries ]]; then
                    log_message INFO "Retrying in 5 seconds..."
                    sleep 5
                fi
            fi
        done
        
        # Verify download
        if [[ ! -f "znuny-${ZNUNY_VERSION}.tar.gz" ]] || [[ ! -s "znuny-${ZNUNY_VERSION}.tar.gz" ]]; then
            log_message ERROR "Failed to download Znuny ${ZNUNY_VERSION} after $max_retries attempts"
            exit 1
        fi
    else
        log_message INFO "Using existing Znuny archive"
    fi
    
    # Check if already extracted
    if [[ -d "znuny-${ZNUNY_VERSION}" ]]; then
        log_message WARN "Znuny directory already exists, removing..."
        rm -rf "znuny-${ZNUNY_VERSION}"
    fi
    
    # Extract Znuny
    log_message INFO "Extracting Znuny archive..."
    tar xzf "znuny-${ZNUNY_VERSION}.tar.gz" || {
        log_message ERROR "Failed to extract Znuny archive"
        exit 1
    }
    
    # Create symbolic link
    if [[ -L /opt/otrs ]]; then
        rm /opt/otrs
    fi
    ln -s "${INSTALL_DIR}/znuny-${ZNUNY_VERSION}" /opt/otrs
    
    log_message INFO "Znuny extracted and linked successfully"
}

# Function to create Znuny user
create_znuny_user() {
    log_message INFO "Creating Znuny system user..."
    
    # Check if user exists
    if ! id "$ZNUNY_USER" &>/dev/null; then
        useradd -d /opt/otrs -c 'Znuny user' -g "$WEB_GROUP" -s /bin/bash "$ZNUNY_USER"
        log_message INFO "User '$ZNUNY_USER' created"
    else
        log_message WARN "User '$ZNUNY_USER' already exists"
    fi
}

# Function to configure Znuny
configure_znuny() {
    log_message INFO "Configuring Znuny..."
    
    # Generate admin password
    ADMIN_PASSWORD=$(generate_password)
    
    cd /opt/otrs
    
    # Create Config.pm with database configuration
    cat > Kernel/Config.pm <<EOF
# --
# Copyright (C) 2001-2021 OTRS AG, https://otrs.com/
# Copyright (C) 2021 Znuny GmbH, https://znuny.org/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see https://www.gnu.org/licenses/gpl-3.0.txt.
# --
#  Note:
#  -->> Most OTRS configuration should be done via the OTRS web interface
#       and the SysConfig. Only for some configuration, such as database
#       credentials and customer data source changes, you should edit this
#       file. For changes do customer data sources you can copy the definitions
#       from Kernel/Config/Defaults.pm and paste them in this file.
#       Config.pm will not be overwritten when updating OTRS.
# --

package Kernel::Config;

use strict;
use warnings;
use utf8;

sub Load {
    my \$Self = shift;

    # ---------------------------------------------------- #
    # database settings                                   #
    # ---------------------------------------------------- #

    # The database host
    \$Self->{DatabaseHost} = '${DB_HOST}';

    # The database name
    \$Self->{Database} = '${DB_NAME}';

    # The database user
    \$Self->{DatabaseUser} = '${DB_USER}';

    # The password of database user.
    \$Self->{DatabasePw} = '${DB_PASSWORD}';

    # The database DSN
    \$Self->{DatabaseDSN} = "DBI:Pg:dbname=\$Self->{Database};host=\$Self->{DatabaseHost}";

    # ---------------------------------------------------- #
    # fs root directory
    # ---------------------------------------------------- #
    \$Self->{Home} = '/opt/otrs';

    # ---------------------------------------------------- #
    # insert your own config settings "here"              #
    # config settings taken from Kernel/Config/Defaults.pm #
    # ---------------------------------------------------- #
    
    # SecureMode
    \$Self->{SecureMode} = 1;
    
    # SystemID
    \$Self->{SystemID} = 10;
    
    # FQDN
    \$Self->{FQDN} = '${HOSTNAME}';
    
    # AdminEmail
    \$Self->{AdminEmail} = 'admin@${HOSTNAME}';
    
    # Organization
    \$Self->{Organization} = 'Znuny Test';

    # ---------------------------------------------------- #

    # ---------------------------------------------------- #
    # data inserted by installer                          #
    # ---------------------------------------------------- #
    # \$DIBI\$

    # ---------------------------------------------------- #
    # ---------------------------------------------------- #
    #                                                     #
    # end of your own config options!!!                   #
    #                                                     #
    # ---------------------------------------------------- #
    # ---------------------------------------------------- #

    return 1;
}

# ---------------------------------------------------- #
# needed system stuff (don't edit this)               #
# ---------------------------------------------------- #

use Kernel::Config::Defaults;
use parent qw(Kernel::Config::Defaults);

# -----------------------------------------------------#

1;
EOF

    # Set proper permissions on Config.pm
    chmod 660 Kernel/Config.pm
    chown ${ZNUNY_USER}:${WEB_GROUP} Kernel/Config.pm
    
    log_message INFO "Znuny configuration file created"
}

# Function to set permissions
set_permissions() {
    log_message INFO "Setting file permissions..."
    
    cd /opt/otrs
    
    # Use Znuny's own permission script if available
    if [[ -x bin/otrs.SetPermissions.pl ]]; then
        bin/otrs.SetPermissions.pl --znuny-user=${ZNUNY_USER} --web-group=${WEB_GROUP} || {
            log_message WARN "SetPermissions.pl reported issues, applying manual permissions"
            chown -R ${ZNUNY_USER}:${WEB_GROUP} /opt/otrs
            chmod -R 755 /opt/otrs
            find var/ -type d -exec chmod 770 {} \;
            find var/ -type f -exec chmod 660 {} \;
            chmod 660 Kernel/Config.pm
        }
    else
        # Manual permissions if script doesn't exist
        log_message INFO "Applying manual permissions"
        chown -R ${ZNUNY_USER}:${WEB_GROUP} /opt/otrs
        chmod -R 755 /opt/otrs
        find var/ -type d -exec chmod 770 {} \;
        find var/ -type f -exec chmod 660 {} \;
        chmod 660 Kernel/Config.pm
    fi
    
    log_message INFO "File permissions set successfully"
}

# Function to configure Apache
configure_apache() {
    log_message INFO "Configuring Apache..."
    
    # Enable required Apache modules
    a2enmod perl
    a2enmod headers
    a2enmod deflate
    a2enmod filter
    a2enmod expires
    a2enmod rewrite
    
    # Link Znuny Apache configuration
    if [[ -f /opt/otrs/scripts/apache2-httpd.include.conf ]]; then
        ln -sf /opt/otrs/scripts/apache2-httpd.include.conf /etc/apache2/conf-available/znuny.conf
        a2enconf znuny || {
            log_message ERROR "Failed to enable Znuny Apache configuration"
            exit 1
        }
    else
        log_message ERROR "Apache configuration file not found"
        exit 1
    fi
    
    # Test Apache configuration
    if ! apache2ctl configtest 2>/dev/null; then
        log_message ERROR "Apache configuration test failed"
        exit 1
    fi
    
    # Restart Apache
    systemctl restart apache2
    systemctl enable apache2
    
    log_message INFO "Apache configured successfully"
}

# Function to initialize database and create admin user
initialize_database() {
    log_message INFO "Initializing Znuny database..."
    
    cd /opt/otrs
    
    # Create necessary directories before database initialization
    log_message INFO "Creating required directories..."
    mkdir -p /opt/otrs/var/tmp
    mkdir -p /opt/otrs/var/log
    mkdir -p /opt/otrs/var/sessions
    mkdir -p /opt/otrs/var/article
    chown -R ${ZNUNY_USER}:${WEB_GROUP} /opt/otrs/var
    chmod -R 770 /opt/otrs/var
    
    # Initialize database schema
    log_message INFO "Creating database schema..."
    su - ${ZNUNY_USER} -c "cd /opt/otrs && bin/otrs.Console.pl Maint::Database::Init --type postgresql" || {
        log_message ERROR "Failed to initialize database"
        exit 1
    }
    
    # Deploy database content
    log_message INFO "Deploying database content..."
    su - ${ZNUNY_USER} -c "cd /opt/otrs && bin/otrs.Console.pl Maint::Database::Deploy" || {
        log_message ERROR "Failed to deploy database content"
        exit 1
    }
    
    # Create admin user
    log_message INFO "Creating admin user..."
    su - ${ZNUNY_USER} -c "cd /opt/otrs && bin/otrs.Console.pl Admin::User::Add --user-name root@localhost --first-name Admin --last-name User --email-address root@localhost --password '${ADMIN_PASSWORD}' --group admin --group users" || {
        log_message ERROR "Failed to create admin user"
        exit 1
    }
    
    # Set initial system configuration
    log_message INFO "Setting initial system configuration..."
    su - ${ZNUNY_USER} -c "cd /opt/otrs && bin/otrs.Console.pl Maint::Config::Rebuild" || {
        log_message WARN "Config rebuild reported issues"
    }
    
    # Rebuild ticket counter
    su - ${ZNUNY_USER} -c "cd /opt/otrs && bin/otrs.Console.pl Maint::Ticket::UnlockTicketByAge" || true
    
    log_message INFO "Database initialized and admin user created successfully"
}

# Function to setup cron jobs
setup_cron() {
    log_message INFO "Setting up Znuny cron jobs..."
    
    cd /opt/otrs/var/cron
    
    # Activate all cron jobs
    for cronfile in *.dist; do
        cp "$cronfile" "${cronfile%.dist}"
    done
    
    # Install cron jobs for znuny user
    su - ${ZNUNY_USER} -c "/opt/otrs/bin/Cron.sh start" || {
        log_message WARN "Some cron jobs may have failed to install"
    }
    
    log_message INFO "Cron jobs configured"
}

# Function to create systemd service
create_systemd_service() {
    log_message INFO "Creating Znuny systemd service..."
    
    # Create systemd service file
    cat > /etc/systemd/system/znuny.service <<EOF
[Unit]
Description=Znuny Daemon
After=postgresql.service apache2.service
Requires=postgresql.service apache2.service

[Service]
Type=forking
User=${ZNUNY_USER}
Group=${WEB_GROUP}
WorkingDirectory=/opt/otrs
ExecStart=/opt/otrs/bin/otrs.Daemon.pl start
ExecStop=/opt/otrs/bin/otrs.Daemon.pl stop
ExecReload=/opt/otrs/bin/otrs.Daemon.pl reload
PIDFile=/opt/otrs/var/run/otrs.Daemon.pl.pid
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd
    systemctl daemon-reload
    
    # Enable and start the service
    systemctl enable znuny.service
    
    # Start the Znuny daemon
    log_message INFO "Starting Znuny daemon..."
    systemctl start znuny.service || {
        log_message WARN "Znuny daemon start reported issues, trying direct start"
        su - ${ZNUNY_USER} -c "/opt/otrs/bin/otrs.Daemon.pl start" || true
    }
    
    log_message INFO "Znuny service configured and started"
}

# Function to verify services
verify_services() {
    log_message INFO "Verifying all services are running..."
    
    local all_ok=true
    
    # Check PostgreSQL
    if systemctl is-active --quiet postgresql; then
        log_message INFO "PostgreSQL is running ✓"
    else
        log_message ERROR "PostgreSQL is not running"
        all_ok=false
    fi
    
    # Check Apache
    if systemctl is-active --quiet apache2; then
        log_message INFO "Apache is running ✓"
    else
        log_message ERROR "Apache is not running"
        all_ok=false
    fi
    
    # Check Znuny daemon
    if systemctl is-active --quiet znuny; then
        log_message INFO "Znuny daemon is running ✓"
    elif [[ -f /opt/otrs/var/run/otrs.Daemon.pl.pid ]] && kill -0 $(cat /opt/otrs/var/run/otrs.Daemon.pl.pid) 2>/dev/null; then
        log_message INFO "Znuny daemon is running (manual) ✓"
    else
        log_message WARN "Znuny daemon may not be running"
    fi
    
    # Test web interface
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost/otrs/index.pl" | grep -q "200\|302"; then
        log_message INFO "Web interface is accessible ✓"
    else
        log_message WARN "Web interface may not be fully accessible yet"
    fi
    
    if [[ "$all_ok" == "false" ]]; then
        log_message ERROR "Some services are not running properly"
        return 1
    fi
    
    return 0
}

# Function to check installed modules
check_modules() {
    log_message INFO "Checking installed Perl modules..."
    
    cd /opt/otrs
    
    # Run module check
    if [[ -f bin/otrs.CheckModules.pl ]]; then
        bin/otrs.CheckModules.pl > /tmp/znuny_modules_check.txt 2>&1
    else
        log_message WARN "CheckModules.pl not found, skipping module check"
        return
    fi
    
    # Check for missing REQUIRED modules only
    if grep -E "required.*Not installed" /tmp/znuny_modules_check.txt; then
        log_message ERROR "Required modules are missing. Check /tmp/znuny_modules_check.txt for details"
        return 1
    elif grep -q "Not installed" /tmp/znuny_modules_check.txt; then
        log_message WARN "Some optional modules are not installed. Check /tmp/znuny_modules_check.txt for details"
    else
        log_message INFO "All required modules are installed"
    fi
}

# Function to save credentials
save_credentials() {
    log_message INFO "Saving credentials..."
    
    # Get system hostname and IP
    HOSTNAME=$(hostname -f 2>/dev/null || hostname)
    LOCAL_IP=$(hostname -I | awk '{print $1}')
    
    # Save credentials to file
    cat > "$CREDENTIALS_FILE" <<EOF
========================================
Znuny 6.5 Installation Credentials
Generated: $(date)
========================================

DATABASE INFORMATION:
--------------------
Database Type: PostgreSQL
Database Host: ${DB_HOST}
Database Port: ${DB_PORT}
Database Name: ${DB_NAME}
Database User: ${DB_USER}
Database Password: ${DB_PASSWORD}

WEB INTERFACE ACCESS:
--------------------
URL (Hostname): http://${HOSTNAME}/otrs/index.pl
URL (IP): http://${LOCAL_IP}/otrs/index.pl

ADMIN LOGIN:
-----------
Username: root@localhost
Password: ${ADMIN_PASSWORD}

FILE LOCATIONS:
--------------
Znuny Root: /opt/otrs
Config File: /opt/otrs/Kernel/Config.pm
Log Directory: /opt/otrs/var/log/

SERVICE MANAGEMENT:
------------------
Start Znuny: systemctl start znuny
Stop Znuny: systemctl stop znuny
Restart Znuny: systemctl restart znuny
Check Status: systemctl status znuny

IMPORTANT SECURITY NOTES:
------------------------
1. These are the initial credentials generated during installation
2. Change the admin password after first login
3. Secure or delete this file once you've saved the credentials
4. Configure firewall rules to restrict access
5. Enable SSL/TLS for production use

========================================
EOF

    chmod 600 "$CREDENTIALS_FILE"
    
    log_message INFO "Credentials saved to $CREDENTIALS_FILE"
}

# Function to display summary
display_summary() {
    echo
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Znuny 6.5 Installation Complete!      ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo
    echo -e "${YELLOW}Web Interface:${NC}"
    echo -e "  - Via hostname: http://${HOSTNAME}/otrs/index.pl"
    echo -e "  - Via IP:       http://${LOCAL_IP}/otrs/index.pl"
    echo -e "${YELLOW}Admin Login:${NC} root@localhost"
    echo -e "${YELLOW}Admin Password:${NC} ${ADMIN_PASSWORD}"
    echo
    echo -e "${BLUE}Database Credentials:${NC}"
    echo -e "  - Database: ${DB_NAME}"
    echo -e "  - Username: ${DB_USER}"
    echo -e "  - Password: ${DB_PASSWORD}"
    echo
    echo -e "${BLUE}Important Files:${NC}"
    echo -e "  - Credentials: ${CREDENTIALS_FILE}"
    echo -e "  - Install Log: ${LOG_FILE}"
    echo -e "  - Config File: /opt/otrs/Kernel/Config.pm"
    echo
    echo -e "${GREEN}Services Status:${NC}"
    systemctl is-active --quiet postgresql && echo -e "  - PostgreSQL: ${GREEN}Running${NC}" || echo -e "  - PostgreSQL: ${RED}Not running${NC}"
    systemctl is-active --quiet apache2 && echo -e "  - Apache:     ${GREEN}Running${NC}" || echo -e "  - Apache:     ${RED}Not running${NC}"
    systemctl is-active --quiet znuny && echo -e "  - Znuny:      ${GREEN}Running${NC}" || echo -e "  - Znuny:      ${YELLOW}Check manually${NC}"
    echo
    echo -e "${GREEN}Znuny is ready to use!${NC}"
    echo -e "${YELLOW}Access the web interface and login with the admin credentials.${NC}"
    echo
    echo -e "${RED}SECURITY REMINDER:${NC}"
    echo "1. Save the credentials from ${CREDENTIALS_FILE}"
    echo "2. Change the admin password after first login"
    echo "3. Delete or secure the credentials file when done"
}

# Uninstall function
uninstall_znuny() {
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}  Znuny Uninstallation                  ${NC}"
    echo -e "${RED}========================================${NC}"
    echo
    
    log_message INFO "Starting Znuny uninstallation..."
    
    # Stop services
    log_message INFO "Stopping services..."
    systemctl stop znuny 2>/dev/null || true
    systemctl disable znuny 2>/dev/null || true
    systemctl stop apache2 2>/dev/null || true
    
    # Remove Znuny daemon
    if [[ -x /opt/otrs/bin/otrs.Daemon.pl ]]; then
        su - znuny -c "/opt/otrs/bin/otrs.Daemon.pl stop" 2>/dev/null || true
    fi
    
    # Remove cron jobs
    log_message INFO "Removing cron jobs..."
    su - znuny -c "crontab -r" 2>/dev/null || true
    
    # Remove Apache configuration
    log_message INFO "Removing Apache configuration..."
    a2disconf znuny 2>/dev/null || true
    rm -f /etc/apache2/conf-available/znuny.conf
    
    # Remove systemd service
    log_message INFO "Removing systemd service..."
    rm -f /etc/systemd/system/znuny.service
    systemctl daemon-reload
    
    # Drop database
    log_message INFO "Dropping database..."
    su - postgres -c "dropdb znuny" 2>/dev/null || true
    su - postgres -c "dropuser znuny" 2>/dev/null || true
    
    # Remove Znuny files
    log_message INFO "Removing Znuny files..."
    rm -rf /opt/otrs
    rm -rf /opt/znuny-${ZNUNY_VERSION}
    rm -f /opt/znuny-${ZNUNY_VERSION}.tar.gz
    
    # Remove user
    log_message INFO "Removing znuny user..."
    userdel -r znuny 2>/dev/null || true
    
    # Restart Apache
    systemctl start apache2 2>/dev/null || true
    
    log_message INFO "Znuny uninstallation completed"
    echo -e "${GREEN}Znuny has been uninstalled successfully!${NC}"
    echo
    echo "Note: PostgreSQL and system packages were not removed."
    echo "To remove them, run:"
    echo "  apt-get remove --purge postgresql postgresql-*"
}

# Main installation function
main() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Znuny 6.5 Automated Installation      ${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo
    
    # Create log directory if it doesn't exist
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Create log file
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    
    log_message INFO "Starting Znuny automated installation..."
    log_message INFO "Log file: $LOG_FILE"
    log_message INFO "Script version: 2.0 (Fully Automated)"
    log_message INFO "Target Znuny version: ${ZNUNY_VERSION}"
    
    # Run installation steps
    check_root
    detect_os
    check_prerequisites
    
    echo
    echo -e "${YELLOW}This script will automatically install:${NC}"
    echo "  - PostgreSQL database server"
    echo "  - Apache web server with mod_perl2"
    echo "  - Znuny ${ZNUNY_VERSION}"
    echo "  - All required Perl modules"
    echo "  - System dependencies"
    echo
    echo -e "${GREEN}The installation will be fully automated.${NC}"
    echo -e "${GREEN}No manual configuration required!${NC}"
    echo
    
    # Short pause before starting
    echo -e "${YELLOW}Starting installation in 3 seconds...${NC}"
    sleep 3
    
    # Execute installation
    install_system_dependencies
    install_postgresql
    setup_postgresql_db
    install_perl_modules
    install_znuny
    create_znuny_user
    configure_znuny
    set_permissions
    configure_apache
    
    # Check if we can proceed with database initialization
    log_message INFO "Verifying Znuny installation before database setup..."
    if [[ ! -f /opt/otrs/bin/otrs.Console.pl ]]; then
        log_message ERROR "Znuny installation appears incomplete. Missing otrs.Console.pl"
        exit 1
    fi
    
    initialize_database
    setup_cron
    create_systemd_service
    check_modules || log_message WARN "Module check reported issues"
    save_credentials
    
    # Verify services
    verify_services || log_message WARN "Some services may need manual attention"
    
    # Display summary
    display_summary
    
    log_message INFO "Installation completed successfully!"
}

# Cleanup function
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_message ERROR "Installation failed with exit code $exit_code"
        log_message ERROR "Check log file for details: $LOG_FILE"
        
        echo
        echo -e "${RED}Installation failed!${NC}"
        echo -e "Check the log file for details: ${LOG_FILE}"
    fi
}

# Error handling
trap cleanup EXIT
trap 'log_message ERROR "Installation failed at line $LINENO"' ERR

# Check command-line arguments
if [[ "${1:-}" == "uninstall" ]]; then
    check_root
    uninstall_znuny
else
    # Run main installation function
    main
fi