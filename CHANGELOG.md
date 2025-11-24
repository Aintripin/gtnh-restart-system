# Changelog

## [1.0.2]

### Changed
- Updated production defaults for better responsiveness
- TPS threshold: 19.0 → 17.0 (less aggressive)
- Vote threshold: 60% → 50% (simple majority)
- Vote scan interval: 10s → 5s (faster feedback)
- TPS check interval: 60s → 30s (faster detection)
- Vote cooldown: 10min → 9min
- TPS cooldown: 60min → 45min
- TPS sensitivity: 5/7 → 4/7 checks required

## [1.0.1]

### Fixed
- Monitor service crash-loop (infinite restarts) - changed to use `exec`
- Screen session naming now uses underscores for better pattern matching

## [1.0.0]

- Initial release
- Vote-based restart system
- Automatic TPS monitoring
- Systemd integration
- Self-contained installer
- Multi-server support

