# docs/research — reverse-engineering knowledge base

Facts and analysis gathered about the Web-888 hardware, the stock firmware,
and the surrounding ecosystem. **`hardware-facts.md` is the authoritative,
live-verified source** — everything else here is analysis material; verify
load-bearing claims against binaries before relying on them.

## Hardware & boot chain

| Document | Contents |
|---|---|
| [hardware-facts.md](hardware-facts.md) | **Authoritative.** Live-verified hardware facts: MAC/EEPROM, LEDs, clocks, GPIO/ExtIO, RX data path root-cause + operational lessons, QEMU gaps |
| [hardware-reference.md](hardware-reference.md) | Hardware reference: board layout, pinout, GPSDO, connectors |
| [bootbin-repack-spec.md](bootbin-repack-spec.md) | boot.bin partition layout and repack specification (bootgen-verified) |
| [stock-kernel-analysis.md](stock-kernel-analysis.md) | Stock kernel analysis: provenance, config, boot chain, firmware evolution, GPL compliance |
| [firmware-analysis.md](firmware-analysis.md) | Stock firmware (Alpine) analysis: update package vs live on-device layout |

## Stock software architecture

| Document | Contents |
|---|---|
| [software-architecture.md](software-architecture.md) | Overall software architecture of the stock system |
| [configuration-system.md](configuration-system.md) | Web-888 configuration system (websdr.json et al.) |
| [web-interface-architecture.md](web-interface-architecture.md) | Web UI architecture |
| [protocol-api.md](protocol-api.md) | WebSocket protocol and API reference |
| [extension-api-guide.md](extension-api-guide.md) | Extension API developer guide |
| [build-system.md](build-system.md) | Upstream RaspSDR `server` build system (reference) |
| [security-analysis.md](security-analysis.md) | Security analysis of the stock system + Debian image privilege surface |

## Ecosystem & comparisons

| Document | Contents |
|---|---|
| [ecosystem-and-related-projects.md](ecosystem-and-related-projects.md) | Ecosystem map: related projects, clients (SuperSDR etc.), integrations |
| [kiwisdr-comparison.md](kiwisdr-comparison.md) | Web-888 vs KiwiSDR feature comparison |
| [web888-kiwisdr-code-comparison.md](web888-kiwisdr-code-comparison.md) | Comprehensive code-level comparison of the Web-888 fork vs upstream KiwiSDR |
| [red-pitaya-firmware.md](red-pitaya-firmware.md) | Red Pitaya firmware ecosystem as it relates to the Web-888 |
| [zynqsdr-port-notes.md](zynqsdr-port-notes.md) | zynqsdr driver port notes: register map, ioctl table, milestones M3/M4, BUG 3 fix, Appendix A raw evidence |
