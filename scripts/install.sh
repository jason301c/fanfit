#!/bin/zsh
# Installs FanFit on this Mac. Run it as yourself; it asks for your password
# once for the root daemon.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

# Menu bar app, started at login by a LaunchAgent.
pkill -x FanFit 2>/dev/null || true
mkdir -p ~/Applications ~/Library/LaunchAgents
rm -rf ~/Applications/FanFit.app
cp -R build/FanFit.app ~/Applications/FanFit.app
cp support/com.jason301c.fanfit.plist ~/Library/LaunchAgents/
launchctl bootout "gui/$(id -u)/com.jason301c.fanfit" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.jason301c.fanfit.plist

# Two fan controllers fight each other, so stop ThermalForge if it is here.
# This only disables it; `launchctl enable system/com.thermalforge.daemon` brings it back.
pkill -x ThermalForgeApp 2>/dev/null || true

sudo zsh -euo pipefail -c '
  if [[ -f /Library/LaunchDaemons/com.thermalforge.daemon.plist ]]; then
    launchctl bootout system/com.thermalforge.daemon 2>/dev/null || true
    launchctl disable system/com.thermalforge.daemon
    echo "Stopped and disabled the ThermalForge daemon."
  fi
  launchctl bootout system/com.jason301c.fanfitd 2>/dev/null || true
  install -d -o root -g wheel -m 755 /usr/local/libexec
  install -o root -g wheel -m 755 .build/release/fanfitd /usr/local/libexec/fanfitd
  install -o root -g wheel -m 644 support/com.jason301c.fanfitd.plist /Library/LaunchDaemons/com.jason301c.fanfitd.plist
  launchctl bootstrap system /Library/LaunchDaemons/com.jason301c.fanfitd.plist
'

open ~/Applications/FanFit.app
echo "FanFit is running. Daemon log: /var/log/fanfitd.log"
