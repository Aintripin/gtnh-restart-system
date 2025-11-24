# gtnh-restart-system

> Auto-restart system for GTNH servers - handles player votes + TPS monitoring with zero hassle

## What This Does

TLDR: Your GTNH server now restarts itself when TPS drops or players vote for it. Self-contained installer that sets up everything: monitoring scripts, systemd services.

**Key features**: 
- Players can vote with `!restart` in chat
- System watches TPS and auto-restarts if it's consistently bad (5/7 checks below threshold)
- Different cooldowns for manual vs automatic restarts (10 min vs 1 hour)
- All modular, production-ready, integrated with systemd

## Where to Run This

```bash
# Your server directory (before)
/home/youruser/GTNH_server/
├── server.jar
├── mods/
├── config/
├── world/
└── setup.sh                     # ← Put setup.sh here and run it

# After running setup.sh, it becomes:
/home/youruser/GTNH_server/
├── server.jar
├── mods/
├── config/
├── world/
├── setup.sh
└── minecraft_scripts/           # ← Created by installer
    ├── lib/
    ├── logs/
    ├── docs/
    └── [all the monitoring scripts]
```

**Important**: Run `setup.sh` from your GTNH server directory (or it'll ask you where it is).

## Quick Start

```bash
# 1. Download setup.sh to your server directory
cd /path/to/your/GTNH_server
wget https://raw.githubusercontent.com/YOUR_USERNAME/gtnh-restart-system/main/setup.sh
chmod +x setup.sh

# 2. Run it (it creates minecraft_scripts/ for you)
./setup.sh

# 3. Follow the prompts (RAM config, thresholds, etc.)

# 4. Done! Services are running
```

## What Gets Created

After running `setup.sh`, here's what you get:

```bash
# System services (managed by systemd)
/etc/systemd/system/
├── gtnh-yourserver.service          # Main server service
└── gtnh-yourserver-monitors.service # Monitoring scripts

# Server directory structure
/your/server/minecraft_scripts/
├── setup.sh                          # The installer (keeps it for reference)
├── start_monitors.sh                 # Launches monitoring system
├── gtnh_master_monitor.sh            # Main orchestrator
├── startserver.sh                    # Optimized server startup script
├── lib/                              # Function libraries
│   ├── common_functions.sh           # Shared utilities
│   ├── restart_functions.sh          # Restart logic
│   ├── vote_functions.sh             # Vote monitoring
│   └── tps_functions.sh              # TPS monitoring
├── logs/                             # Monitoring logs
│   └── master_monitor.log
├── restart_state/                    # Cooldown tracking
│   └── last_any_restart
└── docs/                             # ← Generated documentation
    ├── README.md                     # Full guide
    ├── QUICK_REFERENCE.md            # Command cheat sheet
    ├── CONFIGURATION.md              # How to customize
    ├── TROUBLESHOOTING.md            # Common issues
    └── ARCHITECTURE.md               # How it works internally
```

## Need More Info?

After installation, check the docs it generates in `minecraft_scripts/docs/`:

- **README.md** - Complete guide to your setup
- **QUICK_REFERENCE.md** - All the systemctl commands you'll need
- **CONFIGURATION.md** - How to tweak thresholds, intervals, cooldowns
- **TROUBLESHOOTING.md** - Common issues and fixes
- **ARCHITECTURE.md** - Deep dive into how everything works

These docs are customized with your actual service names and paths!

## Features

- ✅ **Self-contained installer** - One script does everything, no dependencies to hunt down
- ✅ **Smart TPS monitoring** - Requires 5/7 checks below threshold before restart (no false alarms)
- ✅ **Player vote system** - Democracy! Players can vote with `!restart` in chat
- ✅ **Differential cooldowns** - Manual restarts every 10 min, auto-TPS restarts every hour
- ✅ **Systemd integration** - Proper service management, auto-start on boot
- ✅ **Modular architecture** - Clean separation of concerns, easy to extend
- ✅ **Production tested** - Running on live GTNH servers
- ✅ **Multi-server support** - Dynamic service naming based on folder name

## Requirements

- **OS**: tested on Kubuntu. Any linux distro should do
- **Tools**: `systemd`, `screen`, `sudo` access
- **Server**: GTNH Minecraft server (Forge-based)
- **Java**: Whatever your GTNH version needs

## How It Works (Brief)

1. **Vote Monitoring**: Watches server logs every 10 seconds for `!restart` commands, counts votes, triggers restart when threshold hit
2. **TPS Monitoring**: Every 60 seconds, checks TPS 7 times. If 5+ checks are below threshold, initiates auto-restart
3. **Restart Logic**: Countdown sequence (vote: 30s, TPS: 3min with intervals), then triggers systemd restart via `systemctl`
4. **Cooldown System**: Tracks last restart time, blocks new restarts if cooldown active

## Configuration

Default settings (customizable during install):
- Vote threshold: 60% of online players
- TPS threshold: 19.0 (configurable for testing)
- Vote cooldown: 10 minutes
- TPS cooldown: 1 hour
- Vote check interval: 10 seconds
- TPS check cycle: 60 seconds (7 checks per cycle)

