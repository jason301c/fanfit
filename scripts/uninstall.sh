#!/bin/zsh
# Removes FanFit and hands the fans back to Apple.
set -euo pipefail

pkill -x FanFit 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.jason301c.fanfit" 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.jason301c.fanfit.plist
rm -rf ~/Applications/FanFit.app

sudo zsh -c '
  launchctl bootout system/com.jason301c.fanfitd 2>/dev/null || true
  /usr/local/libexec/fanfitd --reset 2>/dev/null || true
  rm -f /Library/LaunchDaemons/com.jason301c.fanfitd.plist /usr/local/libexec/fanfitd
  rm -rf /var/run/fanfit
'
echo "FanFit removed. Your feedback history stays in ~/Library/Application Support/FanFit."
