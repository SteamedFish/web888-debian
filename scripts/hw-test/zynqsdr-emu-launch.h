/* SPDX-License-Identifier: GPL-2.0-or-later */
/* zynqsdr-emu-launch.h — shared host-side launcher for the QEMU web888-pl
 * system-mode lane (used by zynqsdr-smoke.c and zynqsdr-rearm-test.c).
 *
 * Lane contract (scripts/test-zynqsdr-qemu.sh): the test tool is invoked
 * ON THE BUILD HOST as
 *
 *     TOOL --emu HOST SSH_PORT
 *
 * and must drive the guest itself over ssh (root@HOST:SSH_PORT, password
 * auth — the lane uses sshpass -p changeme with StrictHostKeyChecking=no).
 * This helper implements that: it locates the statically-linked armhf
 * payload, uploads it to the guest as /tmp/<name>, runs it there with
 * `--emu` (guest-side model mode), relays its output and exit status, and
 * removes it afterwards.
 *
 * Payload discovery (first match wins):
 *   1. $ZYNQSDR_REMOTE_BIN (explicit path)
 *   2. <dir-of-this-binary>/<name>.armhf
 *   3. <dir-of-this-binary>/<name>        (only if a 32-bit ARM ELF and
 *      not this binary itself — protects against uploading the host build)
 *   4. ./scripts/hw-test/<name>.armhf, ./scripts/hw-test/<name>
 *   5. walking up from this binary's directory (4 levels): scripts/hw-test/<name>...
 *
 * Env knobs: ZYNQSDR_REMOTE_BIN (payload), ZYNQSDR_SSH_PASS (default
 * "changeme"), ZYNQSDR_SSH_OPTS (extra ssh options, space separated).
 *
 * Private to the hw-test tools — NOT part of the public UAPI.
 */
#ifndef ZYNQSDR_EMU_LAUNCH_H
#define ZYNQSDR_EMU_LAUNCH_H

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

/* 32-bit ARM executable? (ELF header, e_machine == EM_ARM) */
static int zynqsdr_is_armelf(const char *path)
{
	unsigned char eh[20];
	int fd = open(path, O_RDONLY);
	ssize_t n;

	if (fd < 0)
		return 0;
	n = read(fd, eh, sizeof(eh));
	close(fd);
	return n == (ssize_t)sizeof(eh) &&
	       eh[0] == 0x7f && eh[1] == 'E' && eh[2] == 'L' && eh[3] == 'F' &&
	       eh[4] == 1 /* ELFCLASS32 */ &&
	       eh[18] == 40 /* e_machine = EM_ARM (little-endian) */;
}

static int zynqsdr_same_file(const char *a, const char *b)
{
	struct stat sa, sb;

	return stat(a, &sa) == 0 && stat(b, &sb) == 0 &&
	       sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino;
}

/* candidate accepted if readable, an armhf ELF, and not the running binary */
static int zynqsdr_payload_ok(const char *path, const char *self)
{
	if (access(path, R_OK) != 0)
		return 0;
	if (!zynqsdr_is_armelf(path))
		return 0;
	if (self && zynqsdr_same_file(path, self))
		return 0;
	return 1;
}

static int zynqsdr_find_payload(const char *name, const char *argv0,
				char *out, size_t outsz)
{
	char self[1024];
	char dir[1024];
	char cand[1400];
	const char *env = getenv("ZYNQSDR_REMOTE_BIN");
	ssize_t n;

	if (env && zynqsdr_payload_ok(env, NULL)) {
		snprintf(out, outsz, "%s", env);
		return 0;
	}

	n = readlink("/proc/self/exe", self, sizeof(self) - 1);
	if (n > 0)
		self[n] = '\0';
	else
		self[0] = '\0';

	/* directory of argv[0] (or of /proc/self/exe as fallback) */
	if (strchr(argv0, '/')) {
		snprintf(dir, sizeof(dir), "%s", argv0);
		*strrchr(dir, '/') = '\0';
	} else if (self[0]) {
		snprintf(dir, sizeof(dir), "%s", self);
		*strrchr(dir, '/') = '\0';
	} else {
		dir[0] = '\0';
	}

	if (dir[0]) {
		snprintf(cand, sizeof(cand), "%s/%s.armhf", dir, name);
		if (zynqsdr_payload_ok(cand, self)) {
			snprintf(out, outsz, "%s", cand);
			return 0;
		}
		snprintf(cand, sizeof(cand), "%s/%s", dir, name);
		if (zynqsdr_payload_ok(cand, self)) {
			snprintf(out, outsz, "%s", cand);
			return 0;
		}
	}

	/* repo-root convention: CWD (the lane runs from the repo root) */
	snprintf(cand, sizeof(cand), "scripts/hw-test/%s.armhf", name);
	if (zynqsdr_payload_ok(cand, self)) {
		snprintf(out, outsz, "%s", cand);
		return 0;
	}
	snprintf(cand, sizeof(cand), "scripts/hw-test/%s", name);
	if (zynqsdr_payload_ok(cand, self)) {
		snprintf(out, outsz, "%s", cand);
		return 0;
	}

	/* walk up from this binary's directory (payload one tree level away) */
	if (self[0]) {
		char walk[1024];
		int i;

		snprintf(walk, sizeof(walk), "%s", self);
		*strrchr(walk, '/') = '\0';
		for (i = 0; i < 4 && strchr(walk, '/'); i++) {
			*strrchr(walk, '/') = '\0';
			snprintf(cand, sizeof(cand),
				 "%s/scripts/hw-test/%s.armhf", walk, name);
			if (zynqsdr_payload_ok(cand, self)) {
				snprintf(out, outsz, "%s", cand);
				return 0;
			}
			snprintf(cand, sizeof(cand),
				 "%s/scripts/hw-test/%s", walk, name);
			if (zynqsdr_payload_ok(cand, self)) {
				snprintf(out, outsz, "%s", cand);
				return 0;
			}
		}
	}
	return -1;
}

/* run: [sshpass -p PASS] ssh [opts] -p PORT root@HOST <remote-cmd>
 * with stdin redirected from stdin_path (may be NULL).
 * Returns the remote command's exit status (or ssh's own failure code).
 */
static int zynqsdr_ssh_run(const char *host, const char *port,
			   const char *remote_cmd, const char *stdin_path)
{
	const char *pass = getenv("ZYNQSDR_SSH_PASS");
	const char *extra = getenv("ZYNQSDR_SSH_OPTS");
	const char *sshpass_bin;
	char target[600];
	char *args[32];
	int argc = 0, status;
	pid_t pid;

	sshpass_bin = pass && *pass ? "sshpass" : NULL;
	/* sshpass present in PATH? else fall back to plain ssh */
	if (sshpass_bin) {
		pid_t fp = fork();
		if (fp == 0) {
			int dn = open("/dev/null", O_RDWR);
			dup2(dn, 0);
			dup2(dn, 1);
			dup2(dn, 2);
			close(dn);
			execlp("sshpass", "sshpass", "-V", NULL);
			_exit(127);
		}
		if (fp < 0 || waitpid(fp, &status, 0) < 0 || !WIFEXITED(status) ||
		    WEXITSTATUS(status) != 0)
			sshpass_bin = NULL;
	}

	args[argc++] = "ssh";
	if (sshpass_bin) {
		args[0] = "sshpass";
		args[argc++] = "-p";
		args[argc++] = (char *)pass;
		args[argc++] = "ssh";
	}
	args[argc++] = "-o";
	args[argc++] = "StrictHostKeyChecking=no";
	args[argc++] = "-o";
	args[argc++] = "UserKnownHostsFile=/dev/null";
	args[argc++] = "-o";
	args[argc++] = "ConnectTimeout=10";
	args[argc++] = "-o";
	args[argc++] = "PreferredAuthentications=password";
	args[argc++] = "-o";
	args[argc++] = "PubkeyAuthentication=no";
	if (extra && *extra) {
		char *dup = strdup(extra);
		char *tok = strtok(dup, " \t");
		while (tok && argc < 26) {
			args[argc++] = tok;
			tok = strtok(NULL, " \t");
		}
	}
	args[argc++] = "-p";
	args[argc++] = (char *)port;
	snprintf(target, sizeof(target), "root@%s", host);
	args[argc++] = target;
	args[argc++] = (char *)remote_cmd;
	args[argc] = NULL;

	pid = fork();
	if (pid == 0) {
		if (stdin_path) {
			int fd = open(stdin_path, O_RDONLY);
			if (fd >= 0) {
				dup2(fd, 0);
				close(fd);
			}
		}
		execvp(args[0], args);
		fprintf(stderr, "exec %s: %s\n", args[0], strerror(errno));
		_exit(127);
	}
	if (pid < 0) {
		fprintf(stderr, "fork: %s\n", strerror(errno));
		return 127;
	}
	while (waitpid(pid, &status, 0) < 0 && errno == EINTR)
		;
	if (WIFEXITED(status))
		return WEXITSTATUS(status);
	return 128;
}

/* host-side entry for `TOOL --emu HOST SSH_PORT` */
static int zynqsdr_emu_remote_main(const char *tool_name, int argc, char **argv)
{
	const char *host = argv[2];
	const char *port = argv[3];
	char payload[1400];
	char rpath[300];
	char cmd[700];
	int rc;

	(void)argc;
	if (zynqsdr_find_payload(tool_name, argv[0], payload, sizeof(payload)) != 0) {
		fprintf(stderr,
			"FAIL: cannot find the armhf payload for %s\n"
			"      (looked for %s.armhf / %s next to this binary and in\n"
			"       scripts/hw-test/; set ZYNQSDR_REMOTE_BIN to override)\n",
			tool_name, tool_name, tool_name);
		return 2;
	}
	printf("emu system mode: host=%s port=%s payload=%s\n",
	       host, port, payload);

	snprintf(rpath, sizeof(rpath), "/tmp/%s", tool_name);

	snprintf(cmd, sizeof(cmd), "cat > %s && chmod 755 %s", rpath, rpath);
	rc = zynqsdr_ssh_run(host, port, cmd, payload);
	if (rc != 0) {
		fprintf(stderr, "FAIL: payload upload to guest (ssh exit %d)\n", rc);
		return 2;
	}
	printf("payload uploaded to guest %s\n", rpath);

	snprintf(cmd, sizeof(cmd), "%s --emu", rpath);
	rc = zynqsdr_ssh_run(host, port, cmd, NULL);
	printf("guest exit status: %d\n", rc);

	snprintf(cmd, sizeof(cmd), "rm -f %s", rpath);
	zynqsdr_ssh_run(host, port, cmd, NULL); /* best effort */

	return rc;
}

#endif /* ZYNQSDR_EMU_LAUNCH_H */
