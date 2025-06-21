# Znuny Installer for Debian/Ubuntu

A comprehensive installation script for Znuny 6.5 (Open Source Ticketing System) on Debian and Ubuntu systems.

## Features

- ✅ Automated installation of Znuny 6.5.15
- ✅ PostgreSQL database setup
- ✅ Apache web server configuration with mod_perl
- ✅ All required Perl modules installation
- ✅ Systemd service configuration
- ✅ Automatic credentials generation
- ✅ Uninstall functionality
- ✅ Comprehensive error handling and logging

## Requirements

- Debian 11/12 or Ubuntu 20.04/22.04
- Root or sudo access
- At least 2GB RAM
- 10GB free disk space
- Internet connection for package downloads

## Quick Start

### One-Line Installation

```bash
# Install directly from GitHub
curl -fsSL https://raw.githubusercontent.com/neovash23/znuny-installer/main/setup-znuny-debian.sh | sudo bash
```

Or using wget:
```bash
wget -qO- https://raw.githubusercontent.com/neovash23/znuny-installer/main/setup-znuny-debian.sh | sudo bash
```

### Manual Installation

```bash
# Clone the repository
git clone https://github.com/neovash23/znuny-installer.git
cd znuny-installer

# Make the script executable
chmod +x setup-znuny-debian.sh

# Run the installer
sudo ./setup-znuny-debian.sh
```

### Uninstallation

```bash
# Remove Znuny (keeps PostgreSQL)
curl -fsSL https://raw.githubusercontent.com/neovash23/znuny-installer/main/setup-znuny-debian.sh | sudo bash -s uninstall
```

Or if you have it locally:
```bash
sudo ./setup-znuny-debian.sh uninstall
```

## What Gets Installed

- **Znuny 6.5.15**: The ticketing system
- **PostgreSQL**: Database server
- **Apache2**: Web server with mod_perl2
- **Perl Modules**: All required dependencies including:
  - DateTime
  - Moo
  - DBI/DBD::Pg
  - Template Toolkit
  - And many more...

## Post-Installation

After successful installation:

1. Access the web installer at: `http://your-server-ip/otrs/installer.pl`
2. Complete the web-based setup wizard
3. Default admin login: `root@localhost`
4. Password will be shown at the end of installation and saved to `/root/znuny-credentials.txt`

## Configuration Files

- **Znuny Config**: `/opt/otrs/Kernel/Config.pm`
- **Apache Config**: `/etc/apache2/conf-available/znuny.conf`
- **Installation Log**: `/var/log/znuny-setup-[timestamp].log`
- **Credentials**: `/root/znuny-credentials.txt`

## Services

The installer creates and configures:
- `znuny.service` - Main Znuny daemon
- `apache2.service` - Web server
- `postgresql.service` - Database server

Manage services with:
```bash
systemctl status znuny
systemctl restart znuny
systemctl stop znuny
```

## Troubleshooting

### Common Issues

1. **Apache fails to start**: Check for missing Perl modules
   ```bash
   tail -f /var/log/apache2/error.log
   ```

2. **Database connection errors**: Verify PostgreSQL is running
   ```bash
   systemctl status postgresql
   ```

3. **Permission errors**: Run the installer as root or with sudo

### Logs

- Installation log: `/var/log/znuny-setup-*.log`
- Apache errors: `/var/log/apache2/error.log`
- Znuny logs: `/opt/otrs/var/log/`

## Security Considerations

⚠️ **Important Security Steps**:

1. Change the default admin password immediately after installation
2. Secure or delete the credentials file: `/root/znuny-credentials.txt`
3. Configure firewall rules to restrict access
4. Enable SSL/TLS for production use
5. Review and harden Apache configuration

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This installer script is released under the MIT License. See [LICENSE](LICENSE) file for details.

Znuny itself is licensed under the GNU AFFERO GENERAL PUBLIC LICENSE Version 3.

## Credits

- [Znuny](https://www.znuny.org/) - The Open Source Ticketing System
- Based on OTRS ((OTRS)) Community Edition

## Support

- [Znuny Documentation](https://doc.znuny.org/)
- [Znuny Community Forum](https://community.znuny.org/)
- [GitHub Issues](https://github.com/yourusername/znuny-installer/issues)

---

**Note**: This is an unofficial installer. For official installation methods, please refer to the [Znuny documentation](https://doc.znuny.org/).