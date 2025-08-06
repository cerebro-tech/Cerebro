# Disable GNOME Print Plugins

This script disables the GNOME printing plugins `gsd-printer` and `gsd-print-notifications` by renaming their binary files.

## Why?

Many users do not use printing services and want to completely remove or disable these background daemons for performance, privacy, or resource reasons. Due to tight integration in GNOME, removing the packages or disabling the plugins via settings is often ineffective.

This script provides a clean and reversible way to disable these plugins without breaking your GNOME session.

## Usage

- To disable printing plugins:

```bash
./disable-gnome-print-plugins.sh
