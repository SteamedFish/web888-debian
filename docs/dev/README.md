# docs/dev — development documentation

Living documents for people working on this repository. User-facing
documentation lives in `../user/`; reverse-engineering facts live in
`../research/`.

## Project state (start here)

| Document | Contents |
|---|---|
| [TODO.md](TODO.md) | Open work items and the completed feature set |
| [KNOWN-ISSUES.md](KNOWN-ISSUES.md) | Known defects, root causes, workarounds, watchlist |
| [CHANGELOG.md](CHANGELOG.md) | Changelog — **every change must be recorded here** (mandatory per `AGENTS.md`) |

## Procedures & plans

| Document | Contents |
|---|---|
| [kernel-update-sop.md](kernel-update-sop.md) | Kernel update SOP (Debian-source 6.12 pinned deb, QEMU gate) |
| [debian-kernel-options-research.md](debian-kernel-options-research.md) | Research behind the kernel choice (options compared, community projects assessed) |
| [redpitaya-port-guide.md](redpitaya-port-guide.md) | Red Pitaya software port to Web-888 (implemented and hardware-verified) |
| [redpitaya-upstream-delta.md](redpitaya-upstream-delta.md) | RaspSDR fork vs pavel-demin/red-pitaya-notes delta analysis |
| [redpitaya-websdr-coexistence.md](redpitaya-websdr-coexistence.md) | Runtime coexistence research (mode switching, FPGA/clock sharing) |
| [web888-kiwisdr-cherry-pick-plan.md](web888-kiwisdr-cherry-pick-plan.md) | KiwiSDR → Web-888 cherry-pick plan and status |
| [armbian-optimizations.md](armbian-optimizations.md) | External research: Armbian's small-memory / flash-protection mechanisms — rationale for the tuning shipped in `configure-rootfs.sh` |
| [github-ci-apt-repo-research.md](github-ci-apt-repo-research.md) | Feasibility research: GitHub Actions image build + tag releases, and a fully GitHub-hosted APT repository (research only, not implemented) |
