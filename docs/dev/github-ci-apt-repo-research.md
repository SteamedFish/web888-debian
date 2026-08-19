# GitHub-hosted APT repository + GitHub Actions image build — feasibility research

**Status: implemented.** Part 1 (deb builds + flat APT repo on gh-pages +
upstream watch) went live 2026-08-16; Part 2 (Actions image build
consuming the repo, `build-image.yml`) went live 2026-08-17 — see
`github-ci-apt-repo.md` for the setup/usage doc. This document is the
underlying feasibility research (user request 2026-08-15).

Two questions investigated:

1. Can we host a real APT repository **entirely on GitHub infrastructure**
   (no external server, no PPA, no self-hosted runner), so that users run
   `apt update && apt upgrade` on their devices?
2. Can the image build (`scripts/build-all.sh`) be moved into a GitHub
   Actions workflow, with git tags driving versioned GitHub Releases?

Both answers are **yes**. No hard blockers were found at this project's
scale.

**Read Part 1 first.** The research surfaced a structural insight that
reorders the original plan: the APT repository is the *foundation*, and the
image build becomes its *consumer*. Today `build-all.sh` compiles everything
from source on every image build. Once our kernel deb, `web888-websdr` /
`web888-redpitaya` debs, and third-party debs (dumphfdl, …) are built in CI
and published to our own APT repo, the image build degenerates to
*debootstrap → add our repo → `apt install` → assemble image* — no
from-scratch builds in the image path at all. Even U-Boot/`boot.bin` can be
shipped as a deb (§2.8), so a fully deb-driven image build is possible.

---

## Part 1 — APT repository hosted entirely on GitHub

**Verdict: fully feasible, no hard blockers at our scale** (armhf only, a
handful of packages, kernel deb ~10–30 MB). Three viable architectures, all
with production users:

| | A. Flat repo on gh-pages | B. Pool repo on gh-pages | C. Flat repo on Releases |
|---|---|---|---|
| Layout | `Packages(.gz)`, `Release`, `InRelease` + debs at repo root | `dists/stable/main/binary-armhf/` + `pool/` | same as A, as release assets |
| sources.list | `deb [signed-by=...] https://<user>.github.io/web888-debian/ ./` | `deb [signed-by=...] https://<user>.github.io/web888-debian/ stable main` | `deb [signed-by=...] https://github.com/<user>/web888-debian/releases/latest/download/ ./` |
| Tooling | `dpkg-scanpackages` + `apt-ftparchive release` + gpg | reprepro / aptly / apt-ftparchive pool mode | `gh release upload --clobber` |
| Version history | `--multiversion` keeps old versions in index | natural, prune to N | only what the latest release carries |
| Limits | Pages: 1 GB site, 100 GB/mo soft bandwidth | same | Releases: 2 GiB/file, **no bandwidth limit** |
| Production users | [davidboulay/Clippy](https://github.com/davidboulay/Clippy), [K0IN/apt-github-pages](https://github.com/K0IN/apt-github-pages) | **NoPorts** ([atsign-foundation/noports-apt](https://github.com/atsign-foundation/noports-apt)), [artifactx-rs/artifactx](https://github.com/artifactx-rs/artifactx) | [mieweb/opensource-server](https://github.com/mieweb/opensource-server), [jsgrrchg/NeverWrite](https://github.com/jsgrrchg/NeverWrite), [OpenListTeam/OpenList-APT](https://github.com/OpenListTeam/OpenList-APT) |

### 1.1 GitHub Pages limits (official)

[GitHub Pages limits — GitHub Docs](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits)

- Published site **≤ 1 GB**; source repo recommended ≤ 1 GB.
- Deployment timeout **10 minutes** (only matters near the 1 GB scale).
- Soft bandwidth **100 GB/month**; soft 10 builds/hour (**not** applicable
  to Actions-driven deploys).
- Git file limits: >50 MiB warning, **>100 MiB blocked**
  ([About large files](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github))
  — kernel deb is fine.
- ToS: Pages is not for commercial SaaS/e-commerce hosting — footnote only.

At our package sizes, dozens of kernel versions fit in the 1 GB budget.

### 1.2 HTTP behavior (empirically verified 2026-08-15)

Probed live repos with `curl -I`:

- **Pages** serves `.deb` / `Release` / `InRelease` as
  `application/octet-stream`, `Packages.gz` as `application/gzip`. apt does
  not validate Content-Type (magic bytes) — all fine. Pages also sends
  `ETag`, `Last-Modified`, `accept-ranges: bytes`, `cache-control:
  max-age=600`, so apt's `If-Modified-Since` incremental updates work.
- **Releases CDN**: `/releases/latest/download/X` → 302 →
  `release-assets.githubusercontent.com` with `Content-Disposition:
  attachment` — apt ignores this; three production repos prove it works.

### 1.3 GPG signing

- Store the armored **private key in an Actions secret**
  (`GPG_PRIVATE_KEY`), plus passphrase/key-id secrets as needed; import via
  `gpg --batch --import` or
  [crazy-max/ghaction-import-gpg](https://github.com/crazy-max/ghaction-import-gpg).
- Sign: `gpg --detach-sign --armor -o Release.gpg Release` +
  `gpg --clearsign -o InRelease Release`.
- Publish the **public key** at the repo root; users install it with
  `curl ... | gpg --dearmor -o /usr/share/keyrings/web888.gpg`.
- Use a **dedicated ed25519 signing key** (with expiry), never a personal
  key. NeverWrite uses exactly this pattern (secrets
  `APT_REPO_GPG_PRIVATE_KEY` / `..._PASSPHRASE` / `..._KEY_ID`).

### 1.4 Tooling landscape (checked 2026-08-15)

The three actions commonly cited in older blog posts are **all deleted**:

- `burneracct/deb-action` — 404
- `sarusso/tinydeb` — 404
- `drom92/debian-repo` — 404
- `malaupa/composite-apt-repo-action`, `radxa-repo/apt-repo-action` — archived

Maintained options:

- [morph027/apt-repo-action](https://github.com/morph027/apt-repo-action) —
  reprepro-based, deployable to gh-pages; last commit **2026-08-05**
- [Vr00mm/deb-publish](https://github.com/Vr00mm/deb-publish) — build +
  publish .deb to a Pages APT repo, multi-arch incl. armhf; 2026-04-25
- [jrandiny/apt-repo-action](https://github.com/jrandiny/apt-repo-action) —
  Python; 2026-01-08
- [aptly-dev/aptly](https://github.com/aptly-dev/aptly) — alive, v1.6.3
  (2026-06-25); reprepro is the classic stable alternative
- Deploy helpers: [peaceiris/actions-gh-pages@v4](https://github.com/peaceiris/actions-gh-pages)
  or official `actions/configure-pages` + `upload-pages-artifact` +
  `deploy-pages`

### 1.5 Reference implementations worth copying

- **NoPorts** (strongest production reference): `apt.noports.com` is GitHub
  Pages behind a CNAME (verified `server: GitHub.com`). Workflow
  [update-repo.yaml](https://github.com/atsign-foundation/noports-apt/blob/trunk/.github/workflows/update-repo.yaml):
  `gh release download *.deb` → `apt-ftparchive packages` per arch
  (**amd64 armhf arm64 riscv64 i386**) → `apt-ftparchive release` →
  `gpg --clearsign`/`gpg -abs` → push; prunes to 4 newest versions.
  Writeup: [Chris Swan, 2026-02-27](https://blog.thestateofme.com/2026/02/27/publishing-apt-and-yum-dnf-repos-on-github-pages/).
  Note the decoupling: the repo workflow pulls debs **from the release
  assets**, so "publish a release" and "update the APT repo" are separate
  workflows — the repo job never needs build artifacts directly.
- **Clippy**
  [packaging/apt/build-repo.sh](https://github.com/davidboulay/Clippy/blob/main/packaging/apt/build-repo.sh) —
  complete copyable **flat-repo** recipe: `dpkg-scanpackages
  --multiversion . /dev/null > Packages` → gzip → `apt-ftparchive release`
  → Release.gpg + InRelease → pubkey export → `.nojekyll` → push gh-pages.
- Blog recipes: [linsomniac.com, 2025-03-18](https://linsomniac.com) (reprepro +
  peaceiris), [blog.woojiahao.com, 2026-01-01](https://blog.woojiahao.com/posts/2026-01-01-hosting-an-apt-repository-on-github-pages/)
  (multi-arch reprepro).

### 1.6 Recommended design for web888-debian

**Option A — flat repo on the `gh-pages` branch** (simplest; Clippy-proven;
no pool tooling). Publish from a repo-update workflow triggered by the
tag release (NoPorts pattern: `gh release download *.deb` → index → sign →
deploy with `peaceiris/actions-gh-pages@v4`, `publish_dir`, `publish_branch:
gh-pages`; Pages source = "Deploy from a branch → gh-pages → /").

User-side (Debian trixie, armhf):

```sh
curl -fsSL https://steamedfish.github.io/web888-debian/pubkey.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/web888.gpg
echo "deb [arch=armhf signed-by=/usr/share/keyrings/web888.gpg] https://steamedfish.github.io/web888-debian/ ./" \
  | sudo tee /etc/apt/sources.list.d/web888.list
sudo apt update && sudo apt install web888-websdr
```

**Fallback — Option C (Releases flat repo)**: zero Pages setup and no
1 GB / 100 GB limits, but the index must be rebuilt and all referenced debs
re-uploaded on **every** release (assets are flat — no subdirectories, the
reason CrossPaste eventually moved to a CDN), and only the latest release
acts as the repo. Good escape hatch if Pages ever becomes a problem.

Switch to Option B (pool layout, reprepro) only if we ever need multiple
suites/components or per-arch indices.

### 1.7 Third-party packages we build ourselves (e.g. dumphfdl)

**Also fine.** An APT repo serves whatever debs we publish — apt makes no
distinction between our own packages (`web888-websdr`, `web888-redpitaya`)
and rebuilt third-party tools. This also directly solves the known problem
that the debs in the stock Web-888's built-in APT source were compiled
against older library versions and no longer install on trixie: building
them inside **our own trixie armhf chroot** produces `Depends:` lines that
match the libraries the image actually ships. (Our Debian image replaces
the stock system entirely, so the stock APT source is simply not used.)

- **No existing APT source to reuse** (verified 2026-08-15): there is no
  Debian/Ubuntu channel for these tools, so self-maintaining is required,
  not optional.
  - [Repology](https://repology.org/project/dumphfdl/versions) shows
    `dumphfdl` only in AUR, Nix, and the openSUSE `hardware:sdr` project
    (RPM only — no armhf deb); it is absent from Debian and Ubuntu, no
    Launchpad PPA ships it, and it is not in
    [deb-get](https://github.com/wimpysworld/deb-get).
  - Its mandatory dependency `libacars >= 2.1.0` is likewise absent from
    Debian ([Repology](https://repology.org/project/libacars/versions):
    Fedora carries only the too-old 1.3.1; current builds exist only as
    AUR/openSUSE-RPM/Nix), so it must be packaged alongside dumphfdl.
  - Upstream `szpajder/dumphfdl` is source-only (no `debian/` directory,
    no release debs; `make install` targets `/usr/local`).
  - Remaining deps (`libliquid-dev`, glib2, libconfig++, fftw3, libzmq,
    sqlite3, librdkafka) are already in the Debian archive; optional
    `statsd-c-client` would also need our own build.
- **Build in CI**: same pattern as our own debs — fetch the pinned upstream
  source (e.g. `szpajder/dumphfdl` at a fixed tag/commit), build in the
  trixie armhf chroot under QEMU, emit a deb artifact. Fold into the
  `debs` job (§2.4) or a separate `thirdparty-debs` job; ccache applies
  equally.
- **Pinning**: always pin the upstream tag/commit (same discipline as
  `config/websdr/upstream.pin`) so releases are reproducible and upgrades
  are deliberate.
- **Versioning**: upstream version + Debian revision,
  `dumphfdl_<upstream>-1_armhf.deb`. These packages are not in the Debian
  archive, so there is no collision today; if one ever enters Debian, apt
  pinning or a local suffix (`-1web8881`) keeps our build authoritative.
  Record provenance (upstream URL + commit) in the deb changelog and in
  `packaging/`.
- **Repo layout**: unchanged — the flat repo carries them next to our own
  debs, and `--multiversion` keeps old versions installable for rollback.
- **Licensing**: verify at packaging time that each upstream license
  permits binary redistribution (routine for GPL-family projects) and note
  it in the provenance — much lower-risk than the FPGA-stack question
  (§2.9.1), but record it.

### 1.8 Alternatives considered (for comparison only)

- **packagecloud** free tier: 2 GB storage, 10 GB bandwidth
  ([pricing](https://packagecloud.io/pricing/)).
- **Cloudsmith** Core free: 500 MB storage / 1 GB delivery (hard limits);
  OSS plan 50 GB / 200 GB ([pricing](https://cloudsmith.com/pricing)).
- Self-hosted: full control but requires a server — what this project wants
  to avoid.

GitHub-native hosting wins: no third-party dependency, no quotas that bite
at our scale, same trust/domain story as the releases themselves.

---

## Part 2 — Image build & release on GitHub Actions

### 2.1 Runner capabilities (official numbers)

[Choosing the runner for a job — GitHub Docs](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job)

| Runner | Public repos | Private repos | Arch |
|---|---|---|---|
| `ubuntu-latest` (= `ubuntu-24.04`) | **4 CPU / 16 GB RAM / 14 GB SSD** | 2 CPU / 8 GB / 14 GB | x64 |
| `ubuntu-24.04-arm` | 4 CPU / 16 GB RAM / 14 GB SSD | 2 CPU / 8 GB / 14 GB | **arm64 only** |
| `ubuntu-slim` | 1 CPU / 5 GB / 14 GB | — | x64 |

Key facts:

- The public GitHub mirror gets **free minutes and free artifact storage**
  ([billing docs](https://docs.github.com/en/billing/managing-billing-for-your-products/managing-billing-for-github-actions/about-billing-for-github-actions)).
  The private forgejo repo is unaffected by any of this.
- `ubuntu-24.04-arm` is **aarch64 only** — there is no armhf (32-bit ARM)
  runner anywhere. GA for public repos 2025-08-07
  ([changelog](https://github.blog/changelog/2025-08-07-arm64-hosted-runners-for-public-repositories-are-now-generally-available/)).
  It adds nothing for this project: everything we do is cross-compile or
  QEMU user-mode, which works identically on x64. **Use x64.**
- **14 GB free SSD is the binding resource constraint**: kernel source
  (~2 GB) + armhf rootfs (~1–2 GB) + 2 GiB image + ccache + staging must
  coexist. It fits, with cleanup steps and job splitting (§2.4).
- Runner image (20260810.271.1) preinstalls: Docker 28.0.4, `gh` CLI 2.97.0,
  `xz-utils`, `zstd`, `dpkg-dev`, `fakeroot`, gcc 12/13/14, `rsync`, `jq`.
  **NOT preinstalled** (must `apt install`): `qemu-user-static`,
  `qemu-system-arm`, `crossbuild-essential-armhf`, `parted`, `dosfstools`,
  `kpartx`.

### 2.2 Hard limits

[Actions limits — GitHub Docs](https://docs.github.com/en/actions/reference/limits)

- **Job execution time: 6 hours (GitHub-hosted) — cannot be increased.**
  Workflow run: 35 days.
- Docker Hub rate limits **do not apply** to hosted runners pulling public
  images (relevant if we ever use `arm32v7/debian:trixie` containers).
- Artifact storage quota applies to private repos only (Free 500 MB /
  Pro 1 GB / Team 2 GB); public repos are free. Cache: 10 GB/repo default,
  7-day retention (can exceed with pay-as-you-go since Nov 2025).
- No per-artifact size cap in current official docs (older third-party
  guides claim 2 GB/artifact); multi-GB artifacts are widely reported
  working. **Verify empirically on first run** — fallback: attach the image
  directly to the release instead of passing it via artifacts.

[About releases — GitHub Docs](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)

- Up to 1,000 assets per release, **each file strictly < 2 GiB**, no total
  size limit, **no bandwidth limit**, no retention expiry.
- Consequence: the raw 2 GiB image cannot be attached uncompressed — ship
  `web888-debian-<mode>.img.xz` (a zero-padded 2 GiB image compresses to
  roughly ~1 GiB with `xz -9e`; measure on first run).

### 2.3 Mapping our pipeline to CI

Everything `scripts/build-all.sh` does locally is reproducible on
`ubuntu-24.04`:

**Toolchain install** (maps our Arch prereqs to Ubuntu):

```bash
sudo apt-get update && sudo apt-get install -y \
  debootstrap qemu-user-static binfmt-support qemu-system-arm \
  crossbuild-essential-armhf device-tree-compiler u-boot-tools \
  dosfstools parted e2fsprogs kpartx cpio rsync ccache
```

**QEMU user-mode / binfmt** for the armhf chroots (`mk-websdr-chroot.sh`,
debootstrap): either `qemu-user-static + binfmt-support` via apt, or
[`docker/setup-qemu-action@v4`](https://github.com/docker/setup-qemu-action).
Proven in production CI by
[Eugeny/tabby](https://github.com/Eugeny/tabby/blob/14e2d60b9b6dee84a53c37f05eefeb803787de04/.github/workflows/build.yml)
(exactly `debootstrap qemu-user-static binfmt-support` + `qemu-debootstrap
--arch arm`), also SimonKagstrom/kcov, potassco/clingo (pbuilder),
ElementsProject/lightning. Note: `setup-qemu-action` provides **user-mode
only** — the QEMU boot gate (`scripts/test-qemu.sh uboot`) needs
`qemu-system-arm` from apt regardless. TCG (no KVM) on hosted runners; the
boot test is slow but works.

**Loop-device image assembly** (`build-image.sh` already uses
`sudo -n losetup --find --show --partscan`, `mkfs.vfat`, `mkfs.ext4`):
hosted runners have passwordless sudo and loop devices work — verified by
production projects:

- [DietPi](https://github.com/MichaIng/DietPi/blob/bf553e37c186f0dba740a3cc12c1f156c65e0208/.github/workflows/dietpi-software.bash)
  (full SBC image builds: `losetup -f`, `losetup -P`, sfdisk)
- [systemd/systemd mkosi.yml](https://github.com/systemd/systemd/blob/e3a224a46dea61b861d3f6ea79ad4abb0fab4b3a/.github/workflows/mkosi.yml)
  (`sudo losetup --find --show` + mount on `ubuntu-latest`)
- [RROrg/rr](https://github.com/RROrg/rr/blob/14543b952d00a5dc06029196065203268120c788/.github/workflows/data.yml)
  (SDR-adjacent project shipping `.img.zip` releases)
- kpartx also works: [google/security-research kernelctf](https://github.com/google/security-research/blob/40a83b44cb4ad2766521316b311e0fe5da3307fb/.github/workflows/kernelctf-vuln-verify.yaml)

⚠️ Caveat: **losetup inside a Docker container needs `--privileged`**
([monero build.yml](https://github.com/monero-project/monero/blob/3646f648db57f60cca86430e25a635d19fa9b92a/.github/workflows/build.yml)).
Run image assembly as runner steps, never inside a container.

**Kernel cross-build**: `crossbuild-essential-armhf` + `make bindeb-pkg`
matches our current flow; official how-to:
[wiki.debian.org/HowToCrossBuildAnOfficialDebianKernelPackage](https://wiki.debian.org/HowToCrossBuildAnOfficialDebianKernelPackage).
Our local pipeline already produces the kernel as a deb
(`output/kernel/linux-image-*_armhf.deb`, installed into the rootfs by
`scripts/install-kernel-deb.sh`) — so the kernel is already shaped for the
repo-consumer model of §2.7.

### 2.4 Build time, caching, job topology

Cold-build estimate on a 4-core runner: kernel 6.12 armhf cross ~30–60 min;
debootstrap trixie armhf under QEMU ~15–40 min; websdr + redpitaya chroot
builds under QEMU ~1–2 h combined; image assembly + xz ~15 min.
**Total ≈ 2–4 h — inside the 6 h cap, but caching is mandatory, not
optional.**

- Kernel: [`hendrikmuhs/ccache-action@v1.2`](https://github.com/hendrikmuhs/ccache-action)
  (works with `CROSS_COMPILE`; kernel rebuilds drop to minutes).
- Rootfs: `actions/cache` on the debootstrap stage / `work/rootfs` saves the
  QEMU debootstrap on every run.
- Job split (each job stays well under the 14 GB disk):

  1. `debs` — kernel `bindeb-pkg` + websdr/redpitaya chroot builds +
     third-party debs → artifact `deb-files`
  2. `image` — `needs: debs`; download artifacts (or pull from the APT
     repo, §2.7), debootstrap, rootfs config, `build-image.sh`, `xz`
     → artifact + `SHA256SUMS`
  3. optionally `qemu-gate` — `test-qemu.sh uboot` before publishing
  4. `release` — `needs: [image, qemu-gate]`; publish release assets
  5. `apt-repo` — `on: release` (NoPorts pattern): download the release's
     debs, rebuild the index, sign, deploy to gh-pages (Part 1)

- Set `timeout-minutes: 330` on long jobs so overruns surface as timeouts.

### 2.5 Tag-triggered releases

Canonical pattern (proven by
[linux-surface](https://github.com/linux-surface/linux-surface/blob/bf1921fc63f33d03a007fb38c4f88ff7e7bc1a55/.github/workflows/debian.yml),
[rizinorg/cutter](https://github.com/rizinorg/cutter/blob/96be4f060be1d420c5cf870e428f790e26e2c542/.github/workflows/ci.yml)):

```yaml
on:
  push:
    tags: ['v*']
# ...
permissions:
  contents: write
```

Publishing: [softprops/action-gh-release@v3](https://github.com/softprops/action-gh-release)
(most popular; `files:` globs, `generate_release_notes: true`,
`prerelease`, `draft`) or plain `gh release create "$TAG" output/*.img.xz
output/*.deb SHA256SUMS --generate-notes`. Generate `SHA256SUMS` over all
assets in the step before publishing.

⚠️ `GITHUB_TOKEN` cannot trigger `on: release` workflows — either keep
build and release in **one** tag-triggered workflow and let the `apt-repo`
job run inside it, or use a PAT to let the release event fire the separate
repo-update workflow (NoPorts pattern).

### 2.6 Versioning from tags

`GITHUB_REF_NAME=v1.2.3` → `VERSION=${GITHUB_REF_NAME#v}` → Debian version
`1.2.3-1`. Set it into `packaging/*/debian/changelog` in CI with
`dch -v "1.2.3-1" --distribution trixie` (devscripts) or `gbp dch --auto`
(git-buildpackage, [Debian GitPackaging wiki](https://wiki.debian.org/GitPackaging)).
Since we ship binary debs only, a single generated changelog entry suffices.

### 2.7 The image build becomes an APT consumer once Part 1 exists

This is the reordering insight at the top of this document, made concrete:

- **Today**: `build-all.sh` compiles the kernel, WebSDR, and Red Pitaya
  software from source on every image build, then installs them into the
  rootfs (`install-kernel-deb.sh`, `install-websdr.sh`,
  `install-redpitaya.sh`).
- **With our APT repo live**: the image job stops building software. It
  bootstraps a trixie armhf rootfs, drops our keyring +
  `/etc/apt/sources.list.d/web888.list` in, and runs
  `apt install linux-image-6.12.100-web888 web888-websdr web888-redpitaya
  dumphfdl …` inside the chroot. Dependency resolution against trixie comes
  from apt itself. This is exactly how Raspberry Pi OS and Armbian image
  builders consume their own repositories.
- **Reproducibility**: pin exact deb versions in the image job
  (`apt install pkg=version`, driven by the release tag), so an image is a
  deterministic function of the repo state + tag.
- **CI consequence**: the from-scratch chroot builds move out of the image
  path entirely. They run only in the `debs` job when a package version
  actually changes (and the results are reused by every subsequent image
  build via the repo). Image-build wall time drops to debootstrap + apt +
  assembly.
- **Local builds keep working**: `build-all.sh` can gain a mode that adds a
  `file:` or `https://` repo URL instead of running the compile steps —
  same consumer model on a developer machine.

### 2.8 U-Boot / boot.bin: also shippable as a deb — IMPLEMENTED 2026-08-16 as `web888-boot` (pre-publication)

Question: can the bootloader escape the from-scratch image build too, or
must the image job always build U-Boot itself? **It can be a deb — and on
this board it is easier than on most**, but it carries the highest
publishing-risk of any package:

- **Why it works here**: in the `uboot` chain, `boot-uboot.bin` contains
  only the source-built FSBL + mainline U-Boot (`scripts/build-bootbin.sh`) — the
  kernel, DTB, `boot.scr`, and `uEnv.txt` are separate files on the FAT
  partition, and the Debian system **mounts that FAT partition at `/boot`**
  (`configure-rootfs.sh` fstab: `/dev/mmcblk0p1 /boot vfat`). Installing a
  new bootloader is therefore a plain file copy into `/boot` — the
  Raspberry Pi OS `raspberrypi-bootloader` deb model. (Debian's own
  `u-boot-*` packages only drop binaries under `/usr/lib/u-boot/` and
  require manual `dd`; Armbian's u-boot debs `dd` raw sectors in postinst.
  Ours is simpler than both: no raw offsets, just a file on a mounted
  filesystem.) The `web888-boot` deb ships `boot.bin` + `boot.scr` +
  `uEnv.txt` + `fsbl.bin` + `u-boot.bin` under `/usr/lib/web888-boot/`
  ("package as much as you can" — uEnv.txt is only written on the device
  when absent, since boot.cmd treats it as the user's kernel-update knob);
  the DTB stays in the kernel deb.
- **Only the `uboot` chain fits**: the stub chain embeds zImage+dtb *inside*
  boot.bin, which couples the bootloader package to every kernel build —
  one more reason stub stays rollback-only.
- **Caveat 1 — brick risk**: an `apt upgrade` that installs a bad
  `boot.bin` bricks the device until the TF card is physically reflashed
  (the untouched stock card remains the rollback). Mitigations **as
  implemented in the postinst**: skip unless `/boot` is the vfat boot
  partition and already has a `boot.bin` (no-op inside the build chroot);
  validate the Zynq sync word (`0xAA995566` LE at offset 0x20) before
  writing anything; write via temp file + `sync` + rename, keeping one
  `boot.bin.bak` / `boot.scr.bak` generation; never touch an existing
  `uEnv.txt`. Still open: the QEMU boot gate (`test-qemu.sh uboot`) should
  pass on the exact payload **before the deb is published**, and consider
  shipping the package held/opt-in (`apt-mark hold web888-boot`) so
  bootloader updates are deliberate.
- **Caveat 2 — FSBL redistribution: resolved**. `boot.bin` used to embed
  the factory FSBL blob; the default chain is now `FSBL=source` (vendored
  embeddedsw `zynq_fsbl`, MIT/Xilinx licensed), so every byte in the deb is
  freely redistributable. `FSBL=stock` remains a local-only escape hatch
  and is never published.
- **Implemented 2026-08-16** (per this recommendation): `packaging/web888-boot/`
  + `scripts/build-boot-deb.sh` build `web888-boot_2026.07-1_armhf.deb` in
  the armhf chroot; `build-all.sh` gained steps 9b (rebuild the deb on
  payload/packaging changes) and 9c (`install-boot-deb.sh` installs it into
  the rootfs chroot, where the postinst deliberately skips); `build-image.sh`
  now copies the FAT boot files from the installed payload instead of the
  host-side `output/` copies; `flash-image.sh` refuses images whose rootfs
  lacks the payload. Verified: postinst dry-run matrix
  (install/upgrade/refusal-to-write-corrupt-payload), QEMU boot of the exact
  deb `boot.bin`, on-device postinst execution. Still owed: freshly-flashed
  image hardware boot, apt-repo publication per chapter 2.

### 2.9 Part-2 blockers & considerations

1. **⚠️ Closed-source FPGA stack redistribution** — the image contains
   factory bitstreams (`websdr_{hf,vhf}.bit`) and the closed driver/FPGA
   stack. (The `web888-boot` deb from §2.8 now contains the **source-built**
   FSBL, so it is no longer part of this redistribution question.)
   Publishing releases from the **public** GitHub mirror makes these
   permanently, publicly downloadable. Review redistribution rights before
   enabling public releases. Alternatives: releases on a private repo (then
   2-core/8 GB runners + storage quotas apply), or publish only open
   components.
2. 14 GB disk — mitigated by job split + cleanup.
3. `DEBIAN_MIRROR` default (`mirrors.tuna.tsinghua.edu.cn`) — from
   Azure-hosted runners `deb.debian.org` is typically faster; make it a
   workflow input.
4. Tag propagation — the workflow fires on tags pushed **to GitHub**; the
   mirror publish process must push tags along with cleaned `master`.
5. Per-artifact size limit unverified in official docs (§2.2).

---

## Open decisions before implementation

1. **Redistribution review** of the closed FPGA/driver stack and the stock
   FSBL inside `boot.bin` in public release artifacts (§2.9.1, §2.8) —
   this gates everything public-facing.
2. GPG signing key: generate a dedicated ed25519 repo key, decide custody
   (Actions secret + offline backup) and rotation/expiry policy.
3. Tag naming convention (`v*` vs `debian-*` style) and ensuring tags are
   pushed to the GitHub mirror.
4. APT layout: Option A (flat/gh-pages, recommended) vs C (releases).
5. CI mirror override (`deb.debian.org` from Azure runners).
6. Whether the QEMU boot gate runs in CI on every tag (recommended: yes,
   as the final job before release — and mandatory before a `web888-boot`
   deb ever publishes, §2.8).
7. Inventory of third-party packages to (re)build and publish alongside
   our own debs (dumphfdl, …) — with pinned upstream versions, since the
   stock Web-888 APT source ships builds against incompatible library
   versions (§1.7).
8. Whether `boot.bin` (+ `boot.scr`/`uEnv.txt`) ships as a `web888-boot`
   deb (recommended, gated) or U-Boot is built only inside the image job
   (§2.8).

## Sources

GitHub official docs:
[Pages limits](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits) ·
[Actions limits](https://docs.github.com/en/actions/reference/limits) ·
[Runner choice](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job) ·
[About releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases) ·
[About large files](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github) ·
[Actions billing](https://docs.github.com/en/billing/managing-billing-for-your-products/managing-billing-for-github-actions/about-billing-for-github-actions)

Changelogs:
[arm64 runners GA 2025-08-07](https://github.blog/changelog/2025-08-07-arm64-hosted-runners-for-public-repositories-are-now-generally-available/) ·
[arm64 free preview 2025-01-16](https://github.blog/changelog/2025-01-16-linux-arm64-hosted-runners-now-available-for-free-in-public-repositories-public-preview/) ·
[cache >10 GB 2025-11-20](https://github.blog/changelog/2025-11-20-github-actions-cache-size-can-now-exceed-10-gb-per-repository/)

Tools/actions:
[softprops/action-gh-release](https://github.com/softprops/action-gh-release) ·
[peaceiris/actions-gh-pages](https://github.com/peaceiris/actions-gh-pages) ·
[docker/setup-qemu-action](https://github.com/docker/setup-qemu-action) ·
[hendrikmuhs/ccache-action](https://github.com/hendrikmuhs/ccache-action) ·
[crazy-max/ghaction-import-gpg](https://github.com/crazy-max/ghaction-import-gpg) ·
[morph027/apt-repo-action](https://github.com/morph027/apt-repo-action) ·
[Vr00mm/deb-publish](https://github.com/Vr00mm/deb-publish) ·
[aptly-dev/aptly](https://github.com/aptly-dev/aptly)

Production references (APT on GitHub):
[atsign-foundation/noports-apt](https://github.com/atsign-foundation/noports-apt) ·
[davidboulay/Clippy](https://github.com/davidboulay/Clippy) ·
[K0IN/apt-github-pages](https://github.com/K0IN/apt-github-pages) ·
[artifactx-rs/artifactx](https://github.com/artifactx-rs/artifactx) ·
[mieweb/opensource-server](https://github.com/mieweb/opensource-server) ·
[jsgrrchg/NeverWrite](https://github.com/jsgrrchg/NeverWrite) ·
[OpenListTeam/OpenList-APT](https://github.com/OpenListTeam/OpenList-APT)

Production references (image builds in CI):
[DietPi](https://github.com/MichaIng/DietPi) ·
[systemd mkosi.yml](https://github.com/systemd/systemd/blob/e3a224a46dea61b861d3f6ea79ad4abb0fab4b3a/.github/workflows/mkosi.yml) ·
[RROrg/rr](https://github.com/RROrg/rr) ·
[Eugeny/tabby](https://github.com/Eugeny/tabby/blob/14e2d60b9b6dee84a53c37f05eefeb803787de04/.github/workflows/build.yml) ·
[linux-surface](https://github.com/linux-surface/linux-surface) ·
[rizinorg/cutter](https://github.com/rizinorg/cutter)
