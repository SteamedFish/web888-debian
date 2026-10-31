# Optional web888d and experimental FPGA combinations

The default Debian image continues to run **stock WebSDR with the stock FPGA
bitstream**. The optional packages in this guide are not preinstalled and do
not change the running mode when installed or upgraded.

`web888d` is the server from
[jeskko/web888-ng](https://github.com/jeskko/web888-ng). The open FPGA
bitstreams come from the separate
[jeskko/web888-ng-hw](https://github.com/jeskko/web888-ng-hw) project.

## Supported combinations

| Application | FPGA | Status |
|---|---|---|
| WebSDR | stock HF/VHF, selected by WebSDR configuration | Default and recommended |
| web888d | stock HF | Supported optional mode; default for web888d |
| web888d | web888-ng stock-compatible HF | Experimental |
| WebSDR | web888-ng stock-compatible HF | Experimental and not recommended for normal operation |
| Red Pitaya apps | their own packaged bitstreams | Existing supported modes |
| anything | channelizer or web888-ng VHF | Not supported by the selector or services |

Only one application stack can run at a time. The applications share the FPGA,
`/dev/zynqsdr`, and in some cases network ports; `web888-mode` stops the old
stack before selecting or loading another one.

## Install and use web888d with the stock FPGA

```sh
apt update
apt install web888-web888d
web888-mode web888d
```

The package installs the server, its UI and a default-off systemd service.
The daemon runs as the dedicated non-root `web888d` user. It does not need
sudo. A separate root oneshot `web888-web888d-pl.service` loads the selected
FPGA and waits for `prog_done`; the daemon unit has no `/dev/xdevcfg` device
allowance.

Useful commands:

```sh
web888-mode                                      # active app and selected FPGA
systemctl status web888-web888d.service
journalctl -u web888-web888d.service -f
web888-mode websdr                               # return to WebSDR
web888-mode stop                                 # stop all SDR application stacks
```

web888d and WebSDR both use TCP port 8073 but have different UIs and protocols.
Check the TLS setting in `/etc/web888d/web888d.toml` when choosing `http` or
`https`. Mutable configuration lives in `/etc/web888d/`; certificates and
runtime state live in `/var/lib/web888d/`. Back up both if you change them.

Installing the package does not enable the service. After an apt upgrade,
review the package changelog and restart or reselect the mode yourself.

## Experimental web888-ng HF combinations

The open HF bitstream is stock-register-compatible, but it is not the default.
In particular, the open-HF + stock-WebSDR combination has less end-to-end
hardware evidence than the normal combinations. Use it only on a device you
can recover, and keep the stock TF card available as rollback.

Install the separate bitstream package:

```sh
apt install web888-ng-bitstream
sha256sum /usr/share/web888-ng/firmware/websdr_hf.bit
```

Experimental consent is deliberately tied to the **exact bitstream contents**.
As root, create `/etc/web888/fpga-experimental` with one line, replacing the
example digest with the complete value printed above:

```text
web888-ng-hf REPLACE_WITH_THE_COMPLETE_SHA256
```

Then choose exactly one experimental combination:

```sh
# Open HF + web888d
web888-mode web888d --fpga web888-ng-hf --experimental

# Open HF + stock WebSDR (less verified; not recommended)
web888-mode websdr --fpga web888-ng-hf --experimental
```

Both the acknowledgement file and `--experimental` are required. The selector
verifies the digest and copies that exact artifact to a root-owned snapshot in
`/var/lib/web888-fpga/`; it never uses a symlink into the apt-managed package.
Consequently, a later apt upgrade cannot silently change the FPGA that a
service loads. To use a newer bitstream, repeat the digest acknowledgement and
selection procedure deliberately.

With no `--fpga` option, `web888-mode` retains the current selection. To return
to the normal stock FPGA explicitly:

```sh
web888-mode websdr --fpga stock
# or, for web888d:
web888-mode web888d --fpga stock
```

Changing the FPGA validates and stages the requested selection first, then
stops all SDR stacks before any PL load, even if the application name stays
the same. Invalid consent or a digest mismatch leaves the running stack
untouched. `prog_done=1` only proves that some FPGA design is configured; it
does not identify which one.

## Recovery

If an experimental combination fails:

```sh
web888-mode stop
web888-mode websdr --fpga stock
```

Then inspect the logs:

```sh
journalctl -u web888-web888d.service -b
journalctl -u web888-websdr.service -b
```

If the board becomes unreachable after an experimental FPGA load, power-cycle
it when safe, return to the stock selection, and use the stock TF card if the
Debian installation itself cannot be recovered. QEMU cannot validate the real
`/dev/xdevcfg` programming path; package and model tests are not a substitute
for hardware verification.

## Uninstall

Stop web888d and return to the normal combination before removing packages:

```sh
web888-mode websdr --fpga stock
apt remove web888-web888d web888-ng-bitstream
```

Package removal does not delete mutable configuration or the root-owned FPGA
selection state. Remove `/etc/web888d/`, `/var/lib/web888d/`,
`/var/lib/web888-fpga/` and `/etc/web888/fpga-experimental` manually only if
you no longer need them.
