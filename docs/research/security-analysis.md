# Web-888 / RaspSDR Security Analysis

Date: 2026-03-30

## Scope and sources

This document analyzes the Web-888 / RaspSDR security posture from two angles:

1. Implementation behavior visible in the current `RaspSDR/server` codebase and extracted firmware/configuration artifacts.
2. Publicly visible project discussions, issues, and repository security metadata for `RaspSDR/server` and upstream `jks-prv/KiwiSDR`.

Primary implementation sources used here:

- `RaspSDR/server` `rx/rx_cmd.cpp`
- `RaspSDR/server` `rx/rx_server.cpp`
- `RaspSDR/server` `web/kiwi/kiwi.js`
- `RaspSDR/server` `web/kiwi/admin.js`
- Stock firmware config: `admin.json` (factory defaults — see `packaging/web888-websdr/debian/default/admin.json` for the sanitized Debian copy)
- Stock firmware config: `websdr.json` (factory defaults — see `packaging/web888-websdr/debian/default/websdr.json`)

Important limitation: this is a source-and-config review, not a live penetration test. It identifies exposed mechanisms and likely risks, but it does not prove exploitability unless explicitly stated.

## Executive assessment

Web-888 inherits a meaningful amount of defensive logic from KiwiSDR: command gating before authentication, separate admin authentication state, local-network shortcuts, optional admin IP restriction, optional duplicate-IP limits, and a 24-hour per-IP usage limit with blacklist escalation. Those are real controls, and several of them are implemented server-side in `rx/rx_cmd.cpp`, not just in JavaScript.

However, the overall security posture still looks closer to a hardened hobbyist appliance than a modern internet-facing service. The largest concerns are:

- passwords may still be accepted by direct case-insensitive comparison when compile-time crypto support is absent, which implies recoverable or plaintext-equivalent password handling in config;
- the main server process has been publicly noted by users as running as `root`;
- the project publishes no `SECURITY.md` policy and no GitHub security advisories;
- authentication appears to have no rate limiting or backoff on wrong-password attempts;
- the admin and general WebSocket/API surface is broad, with a monolithic C/C++ binary and many privileged commands;
- HTTPS exists only as an optional/admin-facing feature and HTTP remains the normal exposure model.

In practice, a carefully configured private deployment can be reasonably defended. A casually internet-exposed deployment with default or weak passwords is high risk.

## 1. Authentication system implementation

### Overall flow

Authentication is enforced in the WebSocket command handler. In `rx/rx_cmd.cpp`, the server rejects all incoming commands before successful authentication except:

- `SET keepalive`
- `SET options`
- `SET auth`

If any other command arrives before auth completes, the server logs a security event and kicks the connection:

- `### SECURITY: NO AUTH YET ...`

This is a strong first-line control because it is server-side and not dependent on client behavior.

### Auth types and stream separation

The implementation distinguishes at least three authentication types:

- `t=kiwi` for normal user access
- `t=prot` for explicitly requesting a password-protected channel
- `t=admin` for administrative access

The WebSocket protocol and JS client use multiple stream types:

- sound/user stream
- waterfall stream
- extension stream
- admin stream

Auth state is tracked with separate flags in the connection object:

- `conn->auth`
- `conn->auth_kiwi`
- `conn->auth_prot`
- `conn->auth_admin`

That separation matters: a connection can gain admin capability in addition to an existing user session, and admin authorization is then propagated to associated stream objects on the same receiver channel.

### Admin session rules

Admin login is more restrictive than normal user login:

- only one admin connection is allowed at a time (`BADP_ADMIN_CONN_ALREADY_OPEN`)
- a local-network admin auto-login path exists when configured
- when no admin password is set, admin access is allowed only from the same local network
- an explicit single-IP admin restriction file `/etc/opt.admin_ip` can further limit who may administer the box

This is better than an unrestricted admin page, but it also means local-network trust is a major security assumption.

### Auto-login behavior

The config defaults observed in extracted firmware are:

- `user_auto_login: true`
- `admin_auto_login: true`
- empty `user_password`
- empty `admin_password`

That means a factory/default system can effectively rely on network locality rather than explicit authentication. This is convenient for setup, but dangerous if the network boundary is weak, bridged, proxied, or accidentally exposed.

### Notable strengths

- Pre-auth command suppression is implemented server-side.
- Admin and user auth states are distinct.
- Admin access can be limited to same-subnet or a specific IP.
- Duplicate concurrent admin sessions are blocked.

### Notable concerns

- Local-network trust is heavily relied on.
- Empty passwords are a supported operational mode, not an error.
- There is no visible brute-force throttling or lockout on failed password attempts.

## 2. Password hashing and storage

### What the code shows

`rx/rx_cmd.cpp` has two password-validation modes:

- `kiwi_crypt_validate(pwd_m, salt, hash)` when compiled with `CRYPT_PW`
- otherwise `strcasecmp(pwd_m, pwd_s)`

This is a critical distinction.

When `CRYPT_PW` is enabled, the system reads encrypted password metadata from files such as:

- `DIR_CFG "/.eup"` for user password state
- `DIR_CFG "/.eap"` for admin password state

When those files are missing or corrupt, the code logs a danger message and falls back to clearing the configured password, effectively turning the password into an empty value until reconfigured.

When `CRYPT_PW` is not enabled, the code directly compares the supplied password string with the configured string using case-insensitive comparison. That strongly suggests the configured value is stored in directly reusable form rather than as a one-way salted hash.

### What the extracted firmware config shows

The extracted `admin.json` contains:

- `"user_password":""`
- `"admin_password":""`

This alone does not prove plaintext storage for non-empty passwords, but it does prove the JSON config carries password fields directly. Combined with the non-`CRYPT_PW` code path, the fallback design is plainly weaker than a mandatory salted hash design.

### Assessment

Best case:

- builds intended for production enable `CRYPT_PW`, store salted password material outside the normal JSON config, and use `kiwi_crypt_validate()`.

Worst case:

- some builds accept case-insensitive direct comparison against values stored in config, meaning passwords are effectively plaintext or plaintext-equivalent.

### Security concerns

- Security depends on a compile-time option, not an always-on property.
- Fallback on crypt-file failure clears the password instead of failing closed.
- Case-insensitive password comparison reduces entropy if plaintext mode is used.
- Empty-password operation is normal and explicitly supported.

### Bottom line

Password handling is potentially acceptable only if `CRYPT_PW` is guaranteed in deployed builds. If not, this is a material weakness.

## 3. IP-based access control

### Local-network detection

The auth path classifies clients as local or non-local using interface-aware checks. The code also contains an explicit defensive comment explaining that it uses the actual connection IP from `mc->remote_ip`/`ip_remote(mc)` rather than the stored `conn->remote_ip` when deciding locality, because the latter could be spoofed using `X-Real-IP` or `X-Forwarded-For`.

That comment is important: the developers were aware of header-spoofing risk and intentionally avoided using spoofable forwarded data for local-trust decisions.

### Forwarded/proxied IP handling

In `rx/rx_server.cpp`, connection setup checks both forwarded and unforwarded IPs against the blacklist. The logic around `check_if_forwarded()` and `check_ip_blacklist()` suggests the server expects to sit behind proxies in some deployments and tries to preserve the "real client IP" while still defending against blacklist bypass.

This is a defensive strength, especially since blacklist checks are applied both to forwarded and transport IPs.

### Admin IP restriction

Admin access can be further limited by a file:

- `/etc/opt.admin_ip`

If this file exists and contains a local IP address matching the incoming admin request, the request can be recognized as local and allowed under the restricted policy. This is a fairly primitive but effective allowlist for single-admin deployments.

### Duplicate-IP controls

If `no_dup_ip` is enabled, the server rejects additional sound/waterfall sessions from the same remote IP unless an exemption applies. Exemptions include:

- some local/auto-login paths
- successful time-limit-exemption-password use
- certain admin conditions

This is not primarily an authentication control, but it does reduce abuse by single-IP multi-session flooding.

### Per-IP time limits and auto-blacklisting

The code enforces a 24-hour per-IP connection time budget via `ip_limit_mins`. When an IP exceeds the configured threshold:

- the client receives an `ip_limit` message
- retry counters for that IP are incremented
- after repeated excess attempts, the code calls `ip_blacklist_add_iptables(conn->remote_ip)`

This is one of the more aggressive defensive features in the stack: repeated abuse can escalate into firewall-level blocking.

### Concerns

- Local-network trust remains a soft perimeter and may be unsafe on shared or poorly segmented LANs.
- The `opt.admin_ip` mechanism appears single-entry and operationally brittle.
- IP-based controls do little against attackers already on the same LAN or behind the same NAT.

## 4. WebSocket security

### Positive controls

The WebSocket layer has several meaningful protections:

- pre-auth command suppression in `rx/rx_cmd.cpp`
- per-stream typing (`STREAM_SOUND`, `STREAM_WATERFALL`, `STREAM_ADMIN`, `STREAM_EXT`, etc.)
- stream/type mismatch rejection during auth
- duplicate session and resource checks in `rx/rx_server.cpp`
- connection cleanup and forced close handling

This reduces trivial privilege confusion between UI modes and raw socket endpoints.

### Message design

Commands use plain-text `SET ...` messages and responses use `MSG ...`. This is simple and auditable, but it also means the parser is a custom C/C++ command parser in a large privileged process.

The attack surface includes:

- auth parser
- config save handlers
- DX database update parser
- admin commands
- extension commands

Because this parsing happens inside a monolithic native binary, memory-safety bugs remain a credible concern even if none are directly demonstrated here.

### WebSocket/session exposure points

- user and waterfall sockets are separate and both must auth successfully
- admin uses a dedicated stream
- some admin privileges can be attached to a user session for editing operations

This improves segmentation, but it also means the authorization model is stateful and complex enough that regression risk is real.

### Concerns

- Broad command surface in a native parser means bug density matters.
- No visible CSRF-style origin enforcement is evident from the reviewed code snippets.
- No visible authentication rate limiting exists at the WebSocket boundary.
- If HTTP is exposed without TLS, all auth traffic is exposed to interception unless the password is transformed in a way that prevents replay. The reviewed material says "hashed client-side", but the command and code paths still handle password material as a reusable credential, so replay resistance is not clear.

## 5. Admin interface security

### Existing protections

The admin interface has stronger controls than the user interface:

- separate `admin` auth type
- optional admin password
- optional local-network auto-login
- fallback to local-only access when no admin password is set
- optional `/etc/opt.admin_ip` restriction
- single concurrent admin connection limit
- server-side `conn->auth_admin` checks before sensitive handlers

Several sensitive operations in `rx/rx_cmd.cpp` explicitly gate on `conn->auth_admin`, including DX update/set style operations and other privileged commands.

### Operational exposure

The admin UI can configure high-impact settings, including:

- software updates and installation policy
- ports and SSL mode
- reverse proxy registration
- DUC/DDNS credentials
- Wi-Fi credentials
- MQTT credentials
- local and downloaded IP blacklist content
- user kicking / server restart / reboot

That makes the admin UI the highest-value target in the system.

### Concerns

- `admin_auto_login` defaults to true in extracted config.
- no admin password is a supported initial state.
- the UI stores or handles multiple credentials for external services.
- because the process is reportedly running as `root`, admin compromise likely becomes full-device compromise.

### Additional note on privilege

A public issue in `RaspSDR/server` explicitly points out that `websdr.bin` runs as `root` and requests running it as a non-privileged user instead. That issue is a strong external signal that least-privilege hardening is currently incomplete.

## 6. Network security features

### Defensive features present

- optional user/admin passwords
- optional local auto-login shortcuts
- admin IP restriction file
- duplicate-IP blocking (`no_dup_ip`)
- 24-hour per-IP time limits (`ip_limit_mins`)
- automatic IP blacklist download plus local blacklist editing
- firewall/iptables blacklist escalation for repeated time-limit abuse
- optional HTTPS/SSL setting in admin network config
- support for reverse proxy / FRP-style deployments

### Useful security engineering choices

- the code explicitly considers forwarded-IP spoofing risk
- blacklists are checked during connection establishment
- local-vs-remote classification affects trust decisions
- busy/exclusive/admin-occupied conditions are surfaced to clients instead of silently overloading

### Weaknesses and gaps

- HTTP is still the normal baseline; HTTPS is optional, not mandatory.
- The project appears to rely significantly on deployment hygiene (router rules, firewall, reverse proxy, network segmentation).
- Running the server as `root` magnifies any remotely reachable bug.
- Update/integrity mechanisms appear checksum-based in local docs, but there is no visible strong signed-update story in the reviewed material.
- There is no visible security policy or advisory workflow in GitHub.

## 7. Potential vulnerabilities and security concerns

This section focuses on realistic risks, ordered roughly from highest confidence to more conditional concerns.

### A. Empty/default passwords and local-trust defaults

Confidence: high

Observed defaults show empty `user_password` and `admin_password` with auto-login enabled. If a device is placed on a hostile, bridged, guest, campus, or ISP-managed LAN, local trust may be insufficient.

Impact:

- unauthorized user access
- unauthorized admin access in some local-network scenarios

### B. Password security depends on build-time crypto option

Confidence: high

The presence of both `kiwi_crypt_validate()` and plain `strcasecmp()` means deployed security depends on whether `CRYPT_PW` is enabled. If not enabled, password protection is substantially weaker.

Impact:

- plaintext-equivalent password exposure in config or memory
- lower password entropy because matching is case-insensitive

### C. Fail-open behavior on password-file corruption

Confidence: high

When encrypted password files are missing/corrupt, the code clears the corresponding configured password and continues. That is safer for recoverability than availability, but unsafe from a hard-fail security perspective.

Impact:

- local filesystem corruption or malicious tampering may disable password enforcement rather than lock the system down

### D. No visible brute-force rate limiting

Confidence: high

The reviewed auth path returns `BADP_TRY_AGAIN` on failure, but there is no visible retry delay, per-IP password throttling, or lockout. Time-limit logic is about connection duration, not password guessing.

Impact:

- online password guessing is easier than it should be, especially for internet-exposed instances

### E. Root execution of the monolithic web server

Confidence: high

The public issue about `websdr.bin` running as root is a serious hardening concern. Any RCE or memory-corruption issue in HTTP/WebSocket parsing likely becomes full-device compromise.

Impact:

- full system takeover if a remote memory-safety bug is found

### F. Large native attack surface in a single stripped binary

Confidence: medium-high

`websdr.bin` is a large, static, stripped native executable that embeds the web server, WebSocket handler, DSP logic, admin logic, and extensions. Even absent a known CVE, that architecture raises exploitability risk.

Impact:

- memory corruption, parser bugs, or extension bugs can have broad consequences

### G. Broad admin configuration surface includes secrets

Confidence: high

The admin interface handles Wi-Fi, MQTT, DDNS/DUC, reverse proxy, and update settings. If admin auth is compromised, the attacker gains both control and additional secret material.

Impact:

- persistence, credential theft, traffic interception, or redirection

### H. Potential information disclosure through UI and protocol

Confidence: medium

The protocol reports items such as `client_public_ip`, local-vs-remote state, channel counts, and config-derived content. This is operationally useful, but it also leaks environment information to authenticated clients and sometimes during early auth flows.

Impact:

- reconnaissance value for attackers

### I. Optional HTTPS means many deployments may be plaintext

Confidence: high

If administrators expose the service over plain HTTP, auth exchanges and admin activity may be vulnerable to interception or replay depending on the exact frontend password transformation and network path.

Impact:

- credential theft on hostile networks
- session hijack/replay risk

### J. Client-side HTML/status customization may enable stored XSS if not sanitized everywhere

Confidence: medium

Configuration examples show HTML-capable fields such as `status_msg`, `reason_disabled`, and related admin previews. These may be intended features. Without a full sink-by-sink audit, stored XSS risk cannot be ruled out.

Impact:

- malicious admin or compromised config could inject script into user/admin pages

## Public advisories, CVEs, and discussions

### GitHub security metadata

For both repositories reviewed:

- `RaspSDR/server`: no `SECURITY.md`, no published GitHub security advisories
- `jks-prv/KiwiSDR`: no `SECURITY.md`, no published GitHub security advisories

That does not prove absence of vulnerabilities, only absence of a formal disclosure process on GitHub.

### Public issues/discussions relevant to security posture

#### `RaspSDR/server` issue #52: run server as non-privileged user

This issue directly states that `websdr.bin` runs as root and argues this is suboptimal because the web server is embedded in the same binary. This is the clearest public hardening concern found.

#### `RaspSDR/server` issue #20: external port mapping/admin port-check behavior

This is not a security bug by itself, but it confirms the project is frequently deployed internet-facing and that operators depend on the admin UI for external reachability. Misconfiguration in this area can easily lead to unintended exposure.

#### Other issue searches

The repository issue search did not reveal any obvious public CVE disclosure thread or formal vulnerability report focused on auth bypass, password bypass, or admin compromise.

### CVEs

No confirmed public CVE specific to KiwiSDR or Web-888/RaspSDR was found from the sources reviewed in this investigation.

That should be interpreted cautiously:

- no CVE found is not the same as no vulnerability present;
- small appliance/open-source radio projects are often under-enumerated in public CVE databases;
- the lack of `SECURITY.md` lowers the chance of coordinated/public disclosure via GitHub.

## Defensive features summary

The strongest defensive features currently visible are:

- server-side command rejection before auth
- separation of user/admin auth state
- optional encrypted password validation path
- local-network/admin-IP-aware access logic
- duplicate-IP suppression option
- 24-hour per-IP quota with blacklist escalation
- single-admin-session rule
- blacklist support including downloaded and local entries
- some awareness of reverse-proxy header spoofing risk

## Highest-priority concerns summary

The most important security concerns are:

1. empty/default password mode combined with local auto-login
2. uncertain guarantee that password hashing is always enabled in deployed builds
3. fail-open behavior when password files are missing/corrupt
4. no visible brute-force throttling
5. root execution of the web-facing monolithic binary
6. optional rather than mandatory TLS
7. large native parsing/command surface in a privileged process

## Practical hardening recommendations

### For operators

- Set a strong admin password immediately.
- Set a strong user password if the receiver is internet-accessible.
- Disable `admin_auto_login` and preferably `user_auto_login` for exposed deployments.
- Restrict admin access using `opt.admin_ip` or, better, a firewall/VPN.
- Enable HTTPS if the platform supports it reliably, or place the device behind a TLS-terminating reverse proxy.
- Do not expose the admin interface directly to the public internet.
- Use network segmentation; do not trust "local network" if the LAN is shared or guest-accessible.
- Enable `no_dup_ip` and sensible `ip_limit_mins` values where abuse is a concern.
- Monitor config changes and downloaded blacklist behavior.

### For developers/maintainers

- Make hashed password verification mandatory; remove plaintext/case-insensitive fallback.
- Fail closed if password metadata is missing/corrupt, especially for admin auth.
- Add authentication rate limiting and/or exponential backoff.
- Drop privileges and run `websdr.bin` as a dedicated unprivileged user.
- Add a `SECURITY.md` disclosure policy and publish advisories when needed.
- Consider mandatory TLS for admin endpoints or split admin onto a private-only interface.
- Audit HTML-capable config fields for stored XSS.
- Fuzz and harden WebSocket/native command parsers.

## OWASP-style vulnerability scan (negative findings)

Beyond the concerns A–J above, a focused scan for classic web vulnerability
classes found the following **mitigated / not present** (from `rx_cmd.cpp` /
`kiwi.js` review):

- **CSRF** — WebSocket auth uses no cookies (tokens over the WS frame
  protocol), so classical cookie-based CSRF does not apply; token-based auth
  is the norm.
- **Command injection** — not found. Commands are parsed with strict
  `sscanf`-style format matchers (e.g. `if (sscanf(cmd, "SET freq=%lf", &freq) == 1)`).
- **Path traversal** — mitigated: file serving uses a static allowlist
  (`mkiwi.html`, `kiwi.js`, `kiwi.css`, …).
- **Stored XSS** — partial: some user-controlled config fields (`rx_name`,
  location) are rendered via `.html()`; the build-time/crypto option and the
  admin-only edit path reduce but do not eliminate this (see concern J).
- **Information disclosure** — present (server version banner, detailed error
  strings, public-IP reporting).

## Addendum — Debian image privilege surface (step 3.5 fixes)

The Debian packaging (step 3 WebSDR fixes) makes
websdr's root-only admin actions work without running the server as root.
Net effect on the attack surface:

- **New: sudo surface** — `/etc/sudoers.d/web888` (mode 0440, deb-shipped,
  postinst-validated with `visudo -c`) grants user `web888` NOPASSWD on
  exactly two root-owned scripts in `/usr/lib/web888/root-helpers/`:
  `web888-netconfig` (installs a validated ifupdown drop-in + resolv.conf
  staged in `/var/lib/web888/netconfig/`) and `web888-poweroff` (fixed
  reboot/halt/poweroff verbs via systemctl). Helpers take fixed verbs only,
  validate all staged content line-by-line against an allowlist grammar
  (dotted-quad IPv4 checked per octet), and never eval. A websdr RCE can
  therefore change network configuration or reboot the box — a denial of
  service / config-tampering impact, but not arbitrary root command
  execution; nothing else in the sudoers policy is reachable.
- **New: CAP_NET_ADMIN** (ambient, on the websdr unit) — needed for the
  KIWI iptables blacklist chain. A websdr RCE can reconfigure nftables
  firewall rules (traffic redirection/DoS), but not read/write arbitrary
  files or load kernel modules.
- **Removed: NoNewPrivileges** on the websdr unit — required because sudo is
  setuid-root and NNP blocks every setuid/file-capability transition. The
  compensating controls are the two-entry sudoers surface above,
  `ProtectSystem=strict` (with `ReadWritePaths` limited to
  `/etc/network/interfaces.d` and `/etc/resolv.conf` — the only
  helper-writable system paths), `DevicePolicy=closed` with explicit
  DeviceAllow entries, and the unchanged `MemoryMax`/`LimitMEMLOCK` bounds.
- **Removed: websdr root-password auto-hardening** (chpasswd path) — it
  could only fail as non-root and fought the image's documented `changeme`
  credential. Root password policy is now unambiguously an image-layer
  concern (set in `configure-rootfs.sh`, changed over SSH).
- **SSH**: dropbear replaced by openssh-server (the websdr admin console
  spawns its own `sshd -D` instance; `netcat-openbsd` provides the
  localhost tunnel endpoint).

## Operator security checklist

- [ ] Set a strong admin password (not the default / empty)
- [ ] Set a strong user password if internet-accessible
- [ ] Disable `admin_auto_login` / `user_auto_login` for exposed deployments
- [ ] Restrict admin access via `opt.admin_ip` or firewall/VPN
- [ ] Enable HTTPS / WSS (or front with a TLS-terminating reverse proxy)
- [ ] Do not expose the admin interface directly to the public internet
- [ ] Enable `no_dup_ip` and a sensible `ip_limit_mins`
- [ ] Configure firewall rules (allow only 8073 + SSH from trusted subnets)
- [ ] Disable unused extensions
- [ ] Keep the firmware updated
- [ ] Monitor access logs and review the IP blacklist periodically
- [ ] Back up the configuration

## Supply-chain remnants and stock SSH access behaviour

Two findings from live inspection of the stock firmware that operators should
know about (folded from the retired raw investigation report):

### `config/v.sed` — patched-out backdoor remnants

The stock FAT partition ships `config/v.sed`, a sed script applied during
config loading that comments out three suspicious crontab/profile entries:

```
s/\* \* \* \* \* nohup \/usr\/bin\/.koworker 100 > \/dev\/null 2>\&1 \&/#/
s/^.*\/umek.*$/#/
s/^.*\/root\/\.profiles\/y.*$/#/
```

- `.koworker` — a hidden binary launched via nohup from cron
- `umek` — unknown reference
- `.profiles/y` — hidden profile script

These look like remnants of a supply-chain compromise or backdoor that the
vendor neutralised with this sed script rather than removing at the source.
No such binaries were found on the inspected card, but the finding argues for
treating the stock firmware's update channel with caution.

### SSH access behaviour (stock firmware)

- The stock root password is the well-known default printed in the vendor
  manual (`changeme`), with password auth enabled.
- `/etc/rc.local` (from the apkovl overlay) checks for
  `/media/mmcblk0p1/authorized_keys` on the FAT partition; if present, it
  installs it as root's `authorized_keys`, enables `PubkeyAuthentication`,
  **disables `PasswordAuthentication`**, and restarts sshd. Dropping an
  `authorized_keys` file onto the FAT partition from any PC is therefore the
  vendor-sanctioned way to harden SSH without logging in.

## Conclusion

Web-888 / RaspSDR is not devoid of security controls; in fact, it contains several thoughtful server-side defenses inherited from KiwiSDR and extended for appliance use. But it still carries multiple architectural and operational risks that are common in embedded web appliances: permissive defaults, optional cryptographic hardening, heavy trust in local networks, broad native parser surface, and insufficient process isolation.

For a private, well-segmented station managed by a technically careful operator, the platform can be deployed with acceptable risk. For a casually exposed public deployment, especially one left with default/empty passwords or plain HTTP, the risk profile is materially worse and should be considered unsuitable without additional hardening.
