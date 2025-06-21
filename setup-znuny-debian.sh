#!/bin/bash
#
# Znuny 6.5 Installation Script for Debian/Ubuntu
# This script automates the installation of Znuny 6.5 with PostgreSQL
# 
# Author: System Administrator
# Date: 2025-06-21
# Version: 1.0
#
# Usage: sudo bash setup-znuny-debian.sh
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

# Global variables for credentials
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
    local length=${1:-25}
    # Generate password with alphanumeric characters only
    local password=""
    while [[ ${#password} -lt $length ]]; do
        password+=$(openssl rand -base64 48 | tr -d "=+/\n" | grep -o '[A-Za-z0-9]' | head -c $((length - ${#password})))
    done
    echo "$password"
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
    
    # Check if running interactively
    if [ -t 0 ]; then
        # Prompt for database credentials
        echo -e "\n${BLUE}Database Setup${NC}"
        read -p "Enter database username (default: znuny): " input_db_user
        DB_USER=${input_db_user:-znuny}
        
        read -p "Enter database password (leave blank to auto-generate): " input_db_pass
        if [[ -z "$input_db_pass" ]]; then
            DB_PASSWORD=$(generate_password)
            echo -e "${GREEN}Generated password: ${DB_PASSWORD}${NC}"
        else
            DB_PASSWORD="$input_db_pass"
        fi
    else
        # Non-interactive mode: use defaults or generate password
        DB_USER="znuny"
        DB_PASSWORD=$(generate_password)
        echo -e "${BLUE}Database Setup (non-interactive)${NC}"
        echo "Using database user: ${DB_USER}"
        echo "Generated database password: ${DB_PASSWORD}"
    fi
    
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
        libjson-xs-perl \
        libtemplate-perl \
        libtimedate-perl \
        libarchive-zip-perl \
        libdata-uuid-perl \
        libdatetime-perl \
        libmoo-perl \
        libnet-dns-perl \
        libyaml-libyaml-perl \
        libtext-csv-xs-perl \
        libio-socket-ssl-perl \
        libcrypt-eksblowfish-perl \
        libapache-dbi-perl \
        libmime-tools-perl
    
    if [[ $? -ne 0 ]]; then
        log_message ERROR "Failed to install Perl modules"
        exit 1
    fi
    
    log_message INFO "Core Perl modules installed successfully"
    
    # Optional modules for extended functionality (mail, LDAP, PDF, etc.)
    log_message INFO "Installing optional Perl modules..."
    apt-get install -y \
        libmail-imapclient-perl \
        libnet-ldap-perl \
        libpdf-api2-perl \
        libgd-text-perl \
        libgd-graph-perl \
        libexcel-writer-xlsx-perl \
        libauthen-sasl-perl \
        libauthen-ntlm-perl || {
        log_message WARN "Some optional modules failed to install, but installation will continue"
    }
    
    log_message INFO "Perl modules installation completed"
}

# Function to download and install Znuny
install_znuny() {
    log_message INFO "Downloading and installing Znuny ${ZNUNY_VERSION}..."
    
    cd "$INSTALL_DIR"
    
    # Download Znuny
    if [[ ! -f "znuny-${ZNUNY_VERSION}.tar.gz" ]]; then
        log_message INFO "Downloading Znuny ${ZNUNY_VERSION}..."
        
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
    
    # Copy default configuration
    cd /opt/otrs
    if [[ -f Kernel/Config.pm.dist ]]; then
        cp Kernel/Config.pm.dist Kernel/Config.pm
    fi
    
    # Set admin password
    if [ -t 0 ]; then
        # Interactive mode: prompt for password
        echo -e "\n${BLUE}Admin Account Setup${NC}"
        read -p "Enter admin password (leave blank to auto-generate): " input_admin_pass
        if [[ -z "$input_admin_pass" ]]; then
            ADMIN_PASSWORD=$(generate_password)
            echo -e "${GREEN}Generated admin password: ${ADMIN_PASSWORD}${NC}"
        else
            ADMIN_PASSWORD="$input_admin_pass"
        fi
    else
        # Non-interactive mode: generate password
        ADMIN_PASSWORD=$(generate_password)
        echo -e "${BLUE}Admin Account Setup (non-interactive)${NC}"
        echo "Generated admin password: ${ADMIN_PASSWORD}"
    fi
    
    # Export variables for use in other functions
    export DB_PASSWORD
    export ADMIN_PASSWORD
    
    # Create configuration with database settings
    cat > Kernel/Config.pm <<EOF
# --
# Copyright (C) 2001-2021 OTRS AG, https://otrs.com/
# Copyright (C) 2021 Znuny GmbH, https://znuny.org/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see https://www.gnu.org/licenses/gpl-3.0.txt.
# --

package Kernel::Config;

use strict;
use warnings;
use utf8;

sub Load {
    my \$Self = shift;

    # ---------------------------------------------------- #
    # database settings                                    #
    # ---------------------------------------------------- #

    # The database host
    \$Self->{DatabaseHost} = '${DB_HOST}';

    # The database name
    \$Self->{Database} = '${DB_NAME}';

    # The database user
    \$Self->{DatabaseUser} = '${DB_USER}';

    # The password of database user
    \$Self->{DatabasePw} = '${DB_PASSWORD}';

    # The database DSN
    \$Self->{DatabaseDSN} = "DBI:Pg:dbname=\$Self->{Database};host=\$Self->{DatabaseHost}";

    # ---------------------------------------------------- #
    # fs root directory
    # ---------------------------------------------------- #
    \$Self->{Home} = '/opt/otrs';

    # ---------------------------------------------------- #
    # insert your own config settings "here"               #
    # config settings taken from Kernel/Config/Defaults.pm #
    # ---------------------------------------------------- #
    
    # SecureMode - disabled for initial setup via web installer
    # IMPORTANT: Set this to 1 after completing web installation for security
    \$Self->{SecureMode} = 0;
    
    # System FQDN
    \$Self->{FQDN} = '${HOSTNAME}';
    
    # Default language
    \$Self->{DefaultLanguage} = 'en';
    
    # Set ProductName
    \$Self->{ProductName} = 'Znuny';

    # ---------------------------------------------------- #

    # ---------------------------------------------------- #
    # data inserted by installer                           #
    # ---------------------------------------------------- #
    # \$DIBI\$

    # ---------------------------------------------------- #
    # ---------------------------------------------------- #
    #                                                      #
    # end of your own config options!!!                   #
    #                                                      #
    # ---------------------------------------------------- #
    # ---------------------------------------------------- #

    return 1;
}

# ---------------------------------------------------- #
# needed system stuff (don't edit this)                #
# ---------------------------------------------------- #

use Kernel::Config::Defaults; # import Translatable()
use parent qw(Kernel::Config::Defaults);

# -----------------------------------------------------#

1;
EOF

    # Set permissions on Config.pm
    chown ${ZNUNY_USER}:${WEB_GROUP} Kernel/Config.pm
    chmod 640 Kernel/Config.pm
    
    log_message INFO "Znuny configuration created"
}

# Function to set file permissions
set_permissions() {
    log_message INFO "Setting file permissions..."
    
    cd /opt/otrs
    
    # Use Znuny's SetPermissions script
    if [[ -x bin/otrs.SetPermissions.pl ]]; then
        bin/otrs.SetPermissions.pl --otrs-user=${ZNUNY_USER} --web-group=${WEB_GROUP} || {
            log_message WARN "SetPermissions script failed, applying manual permissions"
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

# Function to initialize database
initialize_database() {
    log_message INFO "Initializing Znuny database..."
    
    cd /opt/otrs
    
    # Create initial database schema
    if [[ -f bin/otrs.Console.pl ]]; then
        # First, check database connectivity
        log_message INFO "Testing database connectivity..."
        if ! PGPASSWORD="${DB_PASSWORD}" psql -h ${DB_HOST} -U ${DB_USER} -d ${DB_NAME} -c "SELECT 1;" &>/dev/null; then
            log_message ERROR "Cannot connect to database. Please check credentials and PostgreSQL configuration"
            exit 1
        fi
        
        # Create necessary directories before database initialization
        log_message INFO "Creating required directories..."
        mkdir -p /opt/otrs/var/tmp
        mkdir -p /opt/otrs/var/log
        mkdir -p /opt/otrs/var/sessions
        mkdir -p /opt/otrs/var/article
        chown -R ${ZNUNY_USER}:${WEB_GROUP} /opt/otrs/var
        chmod -R 770 /opt/otrs/var
        
        log_message INFO "Database connection successful!"
        log_message INFO "Database schema will be initialized via web installer"
        
        # Note: In Znuny 6.5, database initialization is done through the web installer
        # at http://server/otrs/installer.pl
    else
        log_message ERROR "otrs.Console.pl not found"
        exit 1
    fi
    
    log_message INFO "Database initialized successfully"
}

# Function to setup cron jobs
setup_cron() {
    log_message INFO "Setting up cron jobs..."
    
    if [[ -d /opt/otrs/var/cron ]]; then
        cd /opt/otrs/var/cron
        
        # Copy example cron files
        for cronfile in *.dist; do
            if [[ -f "$cronfile" ]]; then
                cp "$cronfile" "${cronfile%.dist}"
            fi
        done
    else
        log_message WARN "Cron directory not found, skipping cron setup"
        return
    fi
    
    # Set permissions on cron files
    chown ${ZNUNY_USER}:${WEB_GROUP} *.dist 2>/dev/null || true
    
    # Install cron jobs
    if [[ -x /opt/otrs/bin/Cron.sh ]]; then
        su - ${ZNUNY_USER} -c "/opt/otrs/bin/Cron.sh start" || {
            log_message WARN "Failed to start cron jobs"
        }
    else
        log_message WARN "Cron.sh not found"
    fi
    
    log_message INFO "Cron jobs configured successfully"
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
    systemctl enable znuny.service || {
        log_message WARN "Failed to enable Znuny service"
    }
    
    # Note: Daemon will be started after web installer completes
    log_message INFO "Znuny daemon will start after web installation is complete"
    
    log_message INFO "Znuny service configured for automatic startup"
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
    if [[ -f /opt/otrs/var/run/otrs.Daemon.pl.pid ]] && kill -0 $(cat /opt/otrs/var/run/otrs.Daemon.pl.pid) 2>/dev/null; then
        log_message INFO "Znuny daemon is running ✓"
    else
        log_message WARN "Znuny daemon is not running (this is normal for initial setup)"
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
    # Get primary IP address (not localhost)
    LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I | awk '{print $1}')
    
    # Export for use in other functions
    export HOSTNAME
    export LOCAL_IP
    
    # Create credentials file
    cat > "$CREDENTIALS_FILE" <<EOF
========================================
Znuny 6.5 Installation Credentials
========================================
Generated: $(date)
Server: ${HOSTNAME}

PostgreSQL Database:
--------------------
  Host:     ${DB_HOST}
  Port:     ${DB_PORT}
  Database: ${DB_NAME}
  User:     ${DB_USER}
  Password: ${DB_PASSWORD}

Znuny Web Interface:
--------------------
  URL (Hostname):  http://${HOSTNAME}/otrs/index.pl
  URL (IP):        http://${LOCAL_IP}/otrs/index.pl
  Admin User:      root@localhost
  Admin Password:  ${ADMIN_PASSWORD}

System Information:
-------------------
  Znuny Version: ${ZNUNY_VERSION}
  Install Path:  /opt/otrs
  System User:   ${ZNUNY_USER} (service account, no password)
  Web Group:     ${WEB_GROUP}
  Config File:   /opt/otrs/Kernel/Config.pm
  Log File:      ${LOG_FILE}

Next Steps:
-----------
1. Access the web interface at one of the URLs above
2. Log in with the admin credentials
3. Complete the web-based configuration wizard
4. Configure email settings
5. Create agents and customer users
6. Set up queues and tickets

Security Notes:
---------------
- Change the admin password after first login
- Secure this credentials file or delete after saving
- Review and harden Apache configuration
- Configure firewall rules as needed
- Enable SSL/TLS for production use

Support:
--------
- Documentation: https://doc.znuny.org/
- Community:     https://community.znuny.org/
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
    echo -e "${YELLOW}Admin Password:${NC} [See ${CREDENTIALS_FILE}]"
    echo
    echo -e "${BLUE}Important Files:${NC}"
    echo -e "  - Credentials: ${CREDENTIALS_FILE}"
    echo -e "  - Install Log: ${LOG_FILE}"
    echo -e "  - Config File: /opt/otrs/Kernel/Config.pm"
    echo
    echo -e "${YELLOW}Next Steps:${NC}"
    echo -e "  1. Access the web interface"
    echo -e "  2. Log in with admin credentials"
    echo -e "  3. Complete initial configuration"
    echo -e "  4. ${RED}IMPORTANT:${NC} Save credentials and secure the file!"
    echo
    echo -e "${GREEN}Services Status:${NC}"
    systemctl is-active --quiet postgresql && echo -e "  - PostgreSQL: ${GREEN}Running${NC}" || echo -e "  - PostgreSQL: ${RED}Not running${NC}"
    systemctl is-active --quiet apache2 && echo -e "  - Apache:     ${GREEN}Running${NC}" || echo -e "  - Apache:     ${RED}Not running${NC}"
    systemctl is-enabled --quiet znuny && echo -e "  - Znuny:      ${GREEN}Enabled (auto-start)${NC}" || echo -e "  - Znuny:      ${YELLOW}Not enabled${NC}"
    echo
    echo -e "${GREEN}Installation completed successfully!${NC}"
    echo -e "${YELLOW}Znuny will start automatically on system boot.${NC}"
    echo
    
    # Always display credentials at the end
    echo
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}INSTALLATION COMPLETE - CREDENTIALS${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo
    echo -e "${BLUE}Database Credentials:${NC}"
    echo -e "  Username: ${YELLOW}${DB_USER}${NC}"
    echo -e "  Password: ${YELLOW}${DB_PASSWORD}${NC}"
    echo
    echo -e "${BLUE}Web Installer:${NC}"
    echo -e "  URL:      ${YELLOW}http://${LOCAL_IP}/otrs/installer.pl${NC}"
    echo
    echo -e "${BLUE}After installation, access Znuny at:${NC}"
    echo -e "  URL:      ${YELLOW}http://${LOCAL_IP}/otrs/index.pl${NC}"
    echo
    echo -e "${GREEN}========================================${NC}"
    echo
    echo -e "Full details saved to: ${YELLOW}${CREDENTIALS_FILE}${NC}"
    
    # Remind about security
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
    rm -f /opt/znuny-6.5
    
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
    echo -e "${BLUE}  Znuny 6.5 Installation Script         ${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo
    
    # Create log directory if it doesn't exist
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Create log file
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    
    log_message INFO "Starting Znuny installation..."
    log_message INFO "Log file: $LOG_FILE"
    log_message INFO "Script version: 1.0"
    log_message INFO "Target Znuny version: ${ZNUNY_VERSION}"
    
    # Run installation steps
    check_root
    detect_os
    check_prerequisites
    
    echo
    echo -e "${YELLOW}This script will install:${NC}"
    echo "  - PostgreSQL database server"
    echo "  - Apache web server with mod_perl2"
    echo "  - Znuny ${ZNUNY_VERSION}"
    echo "  - All required Perl modules"
    echo "  - System dependencies"
    echo
    
    # Check if running interactively (not piped)
    if [ -t 0 ]; then
        read -p "Continue with installation? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_message INFO "Installation cancelled by user"
            exit 0
        fi
    else
        echo -e "${YELLOW}Running in non-interactive mode, proceeding with installation...${NC}"
        sleep 2
    fi
    
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
        
        # Offer to rollback
        echo
        
        # Check if running interactively
        if [ -t 0 ]; then
            echo -e "${YELLOW}Installation failed. Would you like to:${NC}"
            echo "  1) Keep partial installation"
            echo "  2) Remove Znuny files (keep PostgreSQL)"
            echo "  3) Remove everything (Znuny + PostgreSQL)"
            read -p "Select option (1-3) [1]: " -n 1 -r rollback_option
            echo
        else
            echo -e "${YELLOW}Installation failed in non-interactive mode. Keeping partial installation.${NC}"
            rollback_option="1"
        fi
        
        case $rollback_option in
            2)
                log_message INFO "Removing Znuny files..."
                rm -rf /opt/znuny-${ZNUNY_VERSION}
                rm -f /opt/otrs
                rm -f /opt/znuny-${ZNUNY_VERSION}.tar.gz
                userdel ${ZNUNY_USER} 2>/dev/null || true
                ;;
            3)
                log_message INFO "Removing Znuny and PostgreSQL..."
                rm -rf /opt/znuny-${ZNUNY_VERSION}
                rm -f /opt/otrs
                rm -f /opt/znuny-${ZNUNY_VERSION}.tar.gz
                userdel ${ZNUNY_USER} 2>/dev/null || true
                su - postgres -c "dropdb ${DB_NAME} 2>/dev/null" || true
                su - postgres -c "dropuser ${DB_USER} 2>/dev/null" || true
                a2disconf znuny 2>/dev/null || true
                rm -f /etc/apache2/conf-available/znuny.conf
                ;;
        esac
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
    main "$@"
fi