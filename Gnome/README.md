# Disable GNOME Print Plugins

This script disables the GNOME printing plugins `gsd-printer` and `gsd-print-notifications` by renaming their binary files.

## Why?

Many users do not use printing services and want to completely remove or disable these background daemons for performance, privacy, or resource reasons. Due to tight integration in GNOME, removing the packages or disabling the plugins via settings is often ineffective.

This script provides a clean and reversible way to disable these plugins without breaking your GNOME session.

## Usage

- To disable printing plugins:
./disable-gnome-print-plugins.sh

- To restore the original plugins:
./disable-gnome-print-plugins.sh --restore

## Requirements
sudo privileges (to rename files in /usr/lib)

Compatible with GNOME 42+ on Arch Linux and similar distributions.

## Notes
After running the script, log out and log back in, or reboot your system.

If you encounter issues, restore the plugins using the --restore option.

This script does not uninstall any packages.

The script renames binaries to avoid GNOME starting the plugins
