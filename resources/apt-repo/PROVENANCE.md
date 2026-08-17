# PROVENANCE — resources/apt-repo/pubkey.asc

- **What**: ASCII-armored GPG public key (ed25519) that signs the project's
  flat APT repository (`InRelease`/`Release.gpg` on the `gh-pages` branch of
  the GitHub mirror, served at <https://web888.steamedfish.org/apt/>).
- **Fingerprint**: `31CE1BBDFA03BD9EEC625C7FC5D4169E3C0896E3`
  (uid: `web888-debian APT repo (GitHub Actions CI) <web888-apt@steamedfish.org>`,
  created 2026-08-16, no expiry).
- **Origin**: generated on the maintainer's build host for the CI publish
  jobs (see `docs/dev/github-ci-apt-repo.md` §2.1). The matching private key
  lives ONLY in the GitHub Actions secrets (`APT_REPO_GPG_PRIVATE_KEY`) and
  the maintainer's local `.tmp/apt-repo-gpg-private.asc` (gitignored).
- **Consumed by**: `scripts/setup-apt-repo.sh` (installs it into the image
  rootfs as `/usr/share/keyrings/web888.asc` + the matching
  `signed-by=` sources entry), and CI (`scripts/ci/update-apt-repo.sh`
  exports it to `pubkey.asc` in the repo root).
- **Verification**: `gpg --show-keys pubkey.asc` must print the fingerprint
  above; on a device, `apt-get update` must verify `InRelease` against it.
