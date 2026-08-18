# GitHub CI + self-hosted APT repository — maintainer setup

The public GitHub mirror (`SteamedFish/web888-debian`) builds every Debian
package this project ships and publishes them to a flat APT repository on the
`gh-pages` branch under `apt/`, served at
`https://web888.steamedfish.org/apt/` (fallback:
`https://steamedfish.github.io/web888-debian/apt/`).
Design research: `docs/dev/github-ci-apt-repo-research.md` (Option A, flat
repo on gh-pages). Workflows run on pushes **to GitHub** `master` — the
forgejo primary remote has no CI.

## 1. Overview and job topology

| Workflow | Trigger | Jobs |
|---|---|---|
| `build-kernel-deb.yml` | push paths (`scripts/build-kernel-6.12.sh`, `config/kernel/**`, `config/kernel-web888-6.12.fragment`) | preflight → build → smoke → publish |
| `build-websdr-deb.yml` | push paths (`config/websdr/**`, `packaging/web888-websdr/**`, scripts) | preflight → build → publish |
| `build-redpitaya-deb.yml` | push paths (`config/redpitaya/**`, `packaging/web888-redpitaya/**`, scripts, `scripts/hw-test/si5351/**`) | preflight → build → publish |
| `build-boot-deb.yml` | push paths (`config/u-boot/**`, `packaging/web888-boot/**`, FSBL reference trees, scripts) | preflight → build → smoke → publish |
| `build-thirdparty-debs.yml` | push paths (`packaging/{libacars,dumphfdl,frpc,noip-duc}/**`), dispatch, `workflow_call` | detect → select → build → publish |
| `upstream-watch.yml` | daily cron `37 5 * * *`, dispatch | check (upstream pins + trixie lib watch) → rebuild / websdr-rebuild / redpitaya-rebuild (`workflow_call`) |
| `build-image.yml` | `repository_dispatch` (debs-published, fired by every publish job), push paths (image machinery only — deb inputs `write-dtb.sh` / `build-kernel-6.12.sh` / `config/web888.dts` are excluded; their changes arrive via dispatch, so one push never queues two image builds), dispatch | image (build-all DEB_SOURCE=apt → QEMU uboot gate → xz) → timestamped `img-*` Release (keep 5) |

Every `publish` job is gated on the repo variable `APT_REPO_ENABLED=true` and
serialized across workflows via the shared concurrency group
`apt-repo-publish` (concurrent pushes to gh-pages would race the git push and
the `apt/Packages`/`apt/Release` index). Each build workflow also has its own
concurrency group (`build-<pkg>`) with `cancel-in-progress: false` so a
half-built deb set is never interrupted mid-publish.

Artifacts: each build job uploads `debs-<pkg>` (retention default) for the
publish job to consume.

The kernel and boot publishers insert a `smoke` job between build and
publish (`scripts/ci/qemu-smoke-deb.sh`): it assembles a card image the
DEB_SOURCE=apt way from the *published* repo, overlays the freshly built
deb into the rootfs via chroot `dpkg -i`, rebuilds the image, and requires
the `web888 login:` prompt in the QEMU serial log. Before this gate the
only QEMU check lived in `build-image.yml`, which runs *after* publish — a
deb that broke boot was already installable via `apt upgrade` by the time
the image build caught it. The websdr/redpitaya publishers have no such
gate: their debs are userspace-only and cannot break boot. The smoke gate
shares every QEMU limitation in `KNOWN-ISSUES.md` §5 — most notably it
never executes the FSBL inside `web888-boot` (hardware gate only).

## 2. One-time GitHub setup

### 2.1 Generate a dedicated signing key

Use a **dedicated ed25519 key** — never a personal key (research §1.3). A
throwaway subkey approach is fine too.

```sh
gpg --quick-generate-key "web888-debian APT repo <steamedfish@hotmail.com>" ed25519 sign never
# note the key ID (long fingerprint) — this becomes APT_REPO_GPG_KEY_ID
gpg --armor --export-secret-keys <key-id> > apt-repo-key.asc   # goes into the secret
gpg --armor --export <key-id> > apt-repo-pubkey.asc            # local backup; the repo exports pubkey.asc itself
```

Keep an offline backup of the key; rotating it means every device must fetch
the new `pubkey.asc`.

### 2.2 Secrets and variables

Repo → Settings → Secrets and variables → Actions:

| Kind | Name | Value |
|---|---|---|
| Secret | `APT_REPO_GPG_PRIVATE_KEY` | contents of `apt-repo-key.asc` |
| Secret | `APT_REPO_GPG_PASSPHRASE` | key passphrase (empty string if none) |
| Secret | `APT_REPO_GPG_KEY_ID` | long key ID / fingerprint |
| Variable | `APT_REPO_ENABLED` | `true` |

Publishing stays off until `APT_REPO_ENABLED=true` exists; builds still run
and upload artifacts either way.

### 2.3 Pages

**Order matters — the `gh-pages` branch must exist before you touch these
settings** (it is created by the first successful publish job), and the
**Custom domain** input only appears on Settings → Pages once a publishing
source is selected:

1. Merge + push to GitHub `master`; wait for any build workflow's publish
   job to create `gh-pages`.
2. Settings → Pages → **Deploy from a branch** → branch `gh-pages`, folder
   `/(root)`. (Neither "master `/`" — that would serve the source tree —
   nor "GitHub Actions" mode, which is for artifact-based deployments and
   does not fit a mutable, accumulating repo.)
3. **Custom domain**: enter `web888.steamedfish.org`, save, wait for the DNS
   check, then enable **Enforce HTTPS** (GitHub auto-provisions the
   certificate). Doing this AFTER step 2 keeps GitHub's auto-committed
   `CNAME` file on `gh-pages`, not on `master`.

The site serves at `https://web888.steamedfish.org/`
(fallback: `https://steamedfish.github.io/web888-debian/`).

**Homepage coexistence.** The APT repo is fully confined to the `apt/`
subdirectory (`apt/*.deb`, `apt/Packages{,.gz}`, `apt/Release`,
`apt/InRelease`, `apt/Release.gpg`, `apt/pubkey.asc`); the site root stays
free for a project homepage. The publish job is strictly incremental and
never touches files outside `apt/` — except a root-level `.nojekyll`
(Pages must serve the site as-is; harmless to the homepage). GitHub's
auto-committed `CNAME` at the root is likewise preserved.

## 3. User side (device)

```sh
curl -fsSL https://web888.steamedfish.org/apt/pubkey.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/web888.gpg
echo "deb [arch=armhf signed-by=/usr/share/keyrings/web888.gpg] https://web888.steamedfish.org/apt/ ./" \
  | sudo tee /etc/apt/sources.list.d/web888.list
sudo apt update
```

(If the custom domain is not configured, substitute
`https://steamedfish.github.io/web888-debian/apt/`.) The trailing `./` is
the flat-repo marker — there is no `dists/` tree.

## 4. Package inventory

| Package | Source | Trigger paths | Version scheme |
|---|---|---|---|
| `linux-image-6.12.100-web888` | Debian-source 6.12 (`scripts/build-kernel-6.12.sh`, pinned KVER/KREV) + `config/kernel/**` | kernel script, `config/kernel/**`, `config/kernel-web888-6.12.fragment`, `scripts/ci/**` | `<KVER>-<KREV>web888.ci<N>` via `KDEB_PKGVERSION` |
| `web888-websdr` | RaspSDR/server pinned in `config/websdr/upstream.pin` | `config/websdr/**`, `packaging/web888-websdr/**`, websdr scripts, stock bitstreams, `scripts/ci/**` | changelog version `+ci<N>` (stamp, not committed) |
| `web888-redpitaya` | RaspSDR/red-pitaya-notes pinned in `config/redpitaya/upstream.pin` | `config/redpitaya/**`, `packaging/web888-redpitaya/**`, redpitaya scripts, `scripts/hw-test/si5351/**`, `resources/redpitaya-bits/**`, `scripts/ci/**` | changelog version `+ci<N>` |
| `web888-boot` | vendored embeddedsw FSBL + mainline U-Boot v2026.07 (`config/u-boot/**`) | u-boot/fsbl/bootbin/boot-deb scripts, `config/u-boot/**`, `packaging/web888-boot/**`, `resources/reference/{embeddedsw-zynq-fsbl,redpitaya-fsbl-hooks}/**`, `scripts/ci/**` | changelog version `+ci<N>` |
| `libacars`, `dumphfdl`, `frpc`, `noip-duc` | pinned upstream tags in `packaging/<name>/upstream.pin` | `packaging/<name>/**`, `scripts/ci/**`, thirdparty workflow | `<pin version>-<pkgrev>` (+ CI run number inside `build-thirdparty-deb.sh`) |

`<N>` = `GITHUB_RUN_NUMBER`. Stamping happens in the CI checkout only via
`scripts/ci/stamp-changelog.sh` (rewrites just the first changelog line's
version); the committed changelogs keep their clean versions.

## 5. Daily watch design (upstream releases + dependency libs)

`upstream-watch.yml` runs daily (cron `37 5 * * *`) and watches two kinds of
upstream change in one `check` job, then commits and triggers rebuilds.

**Commits pushed with `GITHUB_TOKEN` never trigger other workflows** (GitHub
recursion guard) — so no watch commit can start a path-filtered build on its
own. Every rebuild is therefore invoked via `workflow_call`, and every caller
job carries `secrets: inherit` (the publish jobs need the `APT_REPO_GPG_*`
secrets; called workflows receive no secrets by default).

### 5.1 Upstream release watch

`scripts/ci/check-upstream.sh <name>` output is compared against the
`version:` line of each `packaging/<name>/upstream.pin`; bumps are committed
to `master` as `github-actions[bot]`. The `rebuild` job invokes
`build-thirdparty-debs.yml` with the comma-separated changed package list as
the `package` input (the reusable workflow accepts `all`, a single name, or a
comma list; `dumphfdl` always implies `libacars` since dumphfdl links against
the libacars debs built into the same output dir).

### 5.2 Dependency library watch

Trixie is a rolling target for us: a library transition in the archive (say
`libacars2 2.2.1-1 → 2.2.1-2`) silently changes what `${shlibs:Depends}`
resolves to at the next build, and a stale build can become uninstallable for
fully-upgraded users. The watch therefore also tracks the **runtime libraries
our packages link against**:

- `packaging/deps-snapshot.conf` — the watch list: `<pkg-key>: <lib> ...`
  lines naming the trixie armhf binary packages to track per package
  (soname-versioned names like `libconfig++11`, `libcurl4t64`; verified
  against the trixie armhf archive). `frpc`/`noip-duc` are static — nothing
  tracked.
- `scripts/ci/check-deps.sh <pkg-key|ALL>` — fetches the trixie
  `binary-armhf` Packages indices (`main contrib non-free`,
  `$DEBIAN_MIRROR`, cached daily under `~/.cache/web888`) and prints current
  `lib=version` pairs. `ALL` prints exactly the state-file format. A tracked
  library disappearing from the archive (soname bump) fails loudly — that is
  the signal to update the conf.
- `packaging/deps-snapshot.txt` — the committed state: one
  `pkg-key: lib=version ...` line per package. It lives at `packaging/` root
  deliberately: it matches **no** per-package push path filter, so watch
  commits never cause push-trigger rebuild loops.

When the freshly resolved versions differ from the state file:

- **third-party package** (`libacars`, `dumphfdl`): `pkgrev:` in its
  `upstream.pin` is bumped by 1 (packaging revision = "rebuilt against newer
  libs"), the package joins the `rebuild` job's package list (union with the
  upstream-bumped list).
- **own package** (`web888-websdr`, `web888-redpitaya`): no pin to bump —
  the `websdr-rebuild` / `redpitaya-rebuild` jobs invoke
  `build-websdr-deb.yml` / `build-redpitaya-deb.yml` via `workflow_call`
  (both declare a no-input `workflow_call` trigger for exactly this). Their
  version moves via the `+ci<N>` suffix at build time.
- `deps-snapshot.txt` (plus any pin bumps) is updated in the same commit,
  with a message like
  `upstream-watch: trixie lib refresh (libacars: libxml2 2.12.7-1 -> 2.12.7-2)`.

First-run bootstrap: if `deps-snapshot.txt` is absent/empty, the job seeds it
with the current versions and commits **without** triggering any rebuild —
avoids a one-time thundering herd of rebuilds when the feature lands.

### 5.3 Mirror-divergence operational note

Watch commits land on **GitHub** `master`, but the GitHub repo is a mirror
published from the forgejo primary. When republishing the mirror from forgejo,
**merge these bot commits back** (or cherry-pick them onto the forgejo branch
being published) — otherwise the next force-publish drops the pin bumps and
`deps-snapshot.txt`, and the watch will re-bump/re-bootstrap on its next run.

## 6. Dependency versioning policy

- Packages are **always built against a fully-upgraded trixie chroot** —
  `scripts/mk-websdr-chroot.sh` and `scripts/ci/mk-build-chroot.sh` run
  `apt-get update` + `apt-get -y full-upgrade` on both create and reuse, so
  every build sees the current archive. `${shlibs:Depends}` therefore emits
  `>=` minimums matching the current archive:
  fully-upgraded users stay installable (no stale pins against vanished
  versions), and not-yet-upgraded users are **forced to upgrade the lib**
  alongside — never installable-but-broken.
- `scripts/ci/update-apt-repo.sh` keeps the **last 4 versions** of every
  package, so users pinned on an older lib set keep a matching older deb for
  as long as it survives pruning.
- **Version monotonicity is guaranteed by the always-increasing `+ci<N>` /
  `ci<N>` suffix** (`N` = `GITHUB_RUN_NUMBER`) — even if pin state ever
  regresses (e.g. a mirror republish that drops watch commits), the rebuilt
  deb still sorts newer than anything previously published, so `apt upgrade`
  never moves a user backwards.
- The daily dependency-lib watch (§5.2) closes the remaining gap: an archive
  lib refresh triggers a rebuild within a day instead of waiting for the next
  packaging change.

## 7. Pruning and retention

`scripts/ci/update-apt-repo.sh` prunes each package to the **4 newest
versions** (`KEEP_VERSIONS`, compared with `dpkg --compare-versions`) on every
publish. Old versions stay installable for rollback; the kernel deb is the
largest artifact (~10–30 MB), so 4 kernels + 4 of everything else stays well
under the **1 GB Pages site limit**. If the site ever approaches the limit,
drop `KEEP_VERSIONS` to 3 or 2 in the workflow env. Pages soft bandwidth is
100 GB/month — irrelevant at our fleet size.

## 8. Open items

- **QEMU boot gate for `web888-boot` publish** (research §2.8 caveat 1): the
  deb postinst overwrites `/boot/firmware/boot.bin` on the device; a bad payload
  bricks until physical reflash. A `test-qemu.sh uboot` gate job should pass
  on the exact deb payload before publish (part 2).
- **Image build workflow** (part 2): debootstrap → add this repo →
  `apt install` pinned versions → assemble → tag-triggered GitHub Release.
- **`noip-duc` redistribution license**: upstream is PROPRIETARY — verify
  that rebuilding and redistributing the binary deb from our repo is
  permitted before enabling it in the thirdparty build (research §1.7
  licensing note).

## 9. Postmortem: host /dev deletion via scratch chroot (2026-08-16)

During local repro of the FSBL runner failure, a debootstrap chroot under
`.tmp/noble` was left behind by a killed tmux session with its bind mounts
(`/dev`, `/dev/pts`, `/proc`, `/sys`) still active. A later `rm -rf
.tmp/noble` in the repro script traversed the orphaned `/dev` bind mount and
deleted the HOST's device nodes; a root-shell redirect then recreated
`/dev/null` as a regular 644 file, which broke every new shell/process on the
host (`PermissionDenied` on spawn) until the server was rebooted.

Contributing factors: `tmux kill-session` leaves long-running sudo children
(and their mounts) alive; `.tmp/` is the project scratch dir so bind mounts
there are invisible to later cleanup; `rm -rf` gives no warning when crossing
into a mount.

Prevention (hard rule in AGENTS.md — "Hard constraints"): scratch chroots
with bind mounts live under `/tmp`, not `.tmp/`; any cleanup of a directory
that ever held bind mounts must `umount -R` it and verify with
`mountpoint -q` before `rm -rf`; repro scripts must unmount via an EXIT trap.
CI itself was never affected — this was host-side repro tooling only.

## 10. Push efficiency: input-hash preflight skip

Every push to `master` that touches a workflow's path filter queues a build —
kernel and websdr builds take 30-60 minutes, so pushes that only re-trigger
via shared infrastructure wasted runner hours. Two guards keep CI quiet:

1. **Tightened path filters.** The broad `scripts/ci/**` glob is gone from
   build triggers. Each workflow lists only the CI scripts its *build* job
   actually uses (`stamp-changelog.sh` everywhere; plus
   `mk-build-chroot.sh`/`build-thirdparty-deb.sh` for thirdparty). Editing
   publish-only or watch-only scripts (`update-apt-repo.sh`,
   `check-upstream.sh`, `check-deps.sh`) no longer rebuilds anything.

2. **Input-hash preflight skip.** The four own-deb workflows start with a
   `preflight` job running `scripts/ci/preflight-skip.sh`: it hashes the git
   tree objects of every input path at HEAD and compares the result against
   `apt/build-manifest.json` on the gh-pages branch, where the publish job
   records the hash of every build it actually published. Match → the build
   (and publish) jobs are skipped; the repo already carries debs built from
   exactly these inputs. The hash keys on tree *content*, not commits — a
   revert or a merge that lands the tree back on a previously published state
   skips cleanly.

   Never skipped: `workflow_dispatch` and `workflow_call` (upstream-watch
   trixie-lib rebuilds change no repo file — the input hash is unchanged but
   the build must run), and any state where the manifest is missing or
   unreadable (nothing published yet — the first full population must run).
   `build-thirdparty-debs.yml` keeps its per-package `detect` job instead of
   a preflight; its path filter is already per-package.

## 11. Image releases (build-image.yml)

`build-image.yml` turns the APT repo into a downloadable artifact: it runs
`DEB_SOURCE=apt bash scripts/build-all.sh` (all project debs install from
the repo — no local deb builds), gates on the QEMU uboot boot test (the
serial log must reach the `web888 login:` prompt; test-qemu.sh itself
always exits 0, so the workflow greps the log), xz-compresses, and
publishes a GitHub Release tagged `img-YYYYMMDD-HHMMSSZ` (UTC) with the
stable asset name `web888-debian-uboot.img.xz`.

- **Auto-refresh on new debs**: every deb publish job fires
  `repository_dispatch` (type `debs-published`) right after its gh-pages
  push; build-image.yml listens for it. repository_dispatch is one of the
  two events GITHUB_TOKEN may fire, hence `actions: write` in the deb
  workflows. The image build always installs the *latest* repo debs at
  build time, and the `image-build` concurrency group keeps at most one
  running + one pending build, so a burst of dispatches collapses to a
  single rebuild with the freshest packages.
- **Push trigger** only covers the image machinery itself (build-all /
  build-image / initramfs / configure-rootfs / install-debs-apt /
  setup-apt-repo / test-qemu / apt-repo key / the workflow file) — deb
  content changes never rebuild the image via push; they arrive via
  dispatch. Deb *inputs* (write-dtb.sh, build-kernel-6.12.sh, web888.dts)
  are deliberately excluded: listing them would double-trigger one image
  build per push on top of the publisher's dispatch.
- **CDN index race**: the APT repo sits behind Cloudflare, so right after
  a gh-pages publish an edge node can briefly serve a stale `Packages.gz`
  against the new `Release` file, and apt hard-fails ("File has unexpected
  size … Mirror sync in progress?"). `install-debs-apt.sh` retries
  `apt-get update` (20 × 30 s ≈ one edge-cache TTL) to ride out the
  window; a CDN-side cache-bypass rule for `/apt/*` would remove it
  entirely.
- **Permalink**: `/releases/latest` always points at the newest image, so
  `https://github.com/SteamedFish/web888-debian/releases/latest/download/web888-debian-uboot.img.xz`
  never changes. Old `img-*` releases are pruned to the newest 5
  (`gh release delete --cleanup-tag`).
- The job is gated on `vars.APT_REPO_ENABLED == 'true'` like the publish
  jobs; forks skip it.
