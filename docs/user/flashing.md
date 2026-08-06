# Flashing the Debian image to a TF card

This replaces the stock Web-888 firmware (Alpine Linux in RAM) with a full
Debian trixie system on the TF card. **Your stock TF card stays untouched —
keep it as the known-good rollback.**

## What you need

- A Linux (or WSL) PC with a **USB SD-card reader** — the flash script
  refuses to touch anything else (NVMe/internal disks are hard-blocked).
- A spare TF card (the stock card's requirements apply: SD/SDHC, ≤32 GB,
  Class 10 — see `quick-reference.md`).
- A DHCP-served Ethernet network for the Web-888 (there is no serial
  console and no WiFi onboarding — first contact is always via Ethernet).

## 1. Build the image

See the **Building** section of the top-level `README.md` for prerequisites
and the full build. The short form:

```sh
scripts/build-all.sh           # incremental build, Debian-source 6.12 kernel
scripts/test-qemu.sh final     # QEMU boot gate — ALWAYS run before flashing
```

The QEMU gate boots the exact image in an emulated Zynq and verifies the
boot chain end-to-end. Never flash an image that has not passed it (there
is no serial adapter on this board — QEMU is the only pre-hardware test).

Output: `output/web888-debian-final.img`.

## 2. Flash

Insert the TF card into a **USB** card reader and identify it (`lsblk` —
it must show transport `usb` and appear as `/dev/sdX`):

```sh
scripts/flash-image.sh /dev/sdX output/web888-debian-final.img
```

The script enforces, in order:

1. target is literally `/dev/sdX` (not `/dev/nvme*`, not `/dev/mmcblk*`);
2. `lsblk` reports USB transport;
3. udev reports `ID_BUS=usb`;
4. you type the exact device path back as confirmation.

Any failed check aborts before a single byte is written.

## 3. First boot

1. Insert the card into the Web-888 (**label side down, contacts up**),
   connect Ethernet and power (5 V / 2 A+ USB-C — see `quick-reference.md`).
2. Wait ~1–2 minutes. LED behavior: D2 (green) on during boot, off when the
   system is up; D0 (blue) on when ready.
3. The device gets its address via DHCP and advertises itself via
   **mDNS/Avahi as `web888.local`** — on any mDNS-capable client
   (Linux with avahi/nss-mdns, macOS, Windows 10+) you can go straight to
   `ssh -p 22 root@web888.local` / `http://web888.local:8073/`. If mDNS
   does not resolve, find the IP by the stable MAC prefix `ce:cf:3f:*`:

   ```sh
   sudo nmap -sn <your-lan-subnet>      # then look for Ce:Cf:3f in the MAC column
   ip neigh | grep -i ce:cf:3f          # or, after any contact attempt
   ```

   …or check your router's DHCP lease table.

4. Log in:

   ```sh
   ssh -p 22 root@<device-ip>           # password: changeme
   ```

   **Change the root password** (`passwd`) before exposing the device to any
   untrusted network — the default is public knowledge (it is documented
   right here).

5. The WebSDR web interface is at `http://<device-ip>:8073/`.

## 4. Rollback

Power off, swap the stock TF card back in, power on — the unit is back to
factory firmware. Nothing on the device itself is modified by this project;
everything lives on the card.

## 5. Updating an already-Debian card

You normally do **not** re-flash for software updates:

- WebSDR / Red Pitaya packages: install the rebuilt `.deb` with
  `dpkg -i` (see `usage.md`).
- Kernel: follow `../dev/kernel-update-sop.md` (host-built pinned deb).
- Device-tree changes: the running DT comes from the DTB **embedded in
  boot.bin**, not from `/boot/web888.dtb` — rebuild with
  `scripts/build-bootbin.sh final`, replace `/boot/boot.bin` on the FAT
  partition, reboot (see `../research/hardware-facts.md`, "DT deploy
  lesson").

Re-flash only for partition-layout or rootfs-base changes.

## Troubleshooting

Boot problems (LEDs, power, card, network): see `troubleshooting.md`.
