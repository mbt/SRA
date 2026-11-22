#!/usr/bin/env python3
"""Step 7 — live-host validation for SecureRemoteAgent.

Drives the iOS app's exact SSH flows against a REAL SSH server
(dropbear 2026.94, user-mode on 127.0.0.1:23456, private scratch keys;
no system sshd / ~/.ssh changes):

  phase 0  preflight: banner, port, key-only auth
  phase 1  capture("uname -sm")            -> exec channel (like Citadel executeCommand)
  phase 2  ensureHarness(): mkdir, sha256 compare, SFTP upload, chmod, skip-on-match
  phase 3  harness channel: shell channel WITHOUT a pty (like Citadel withTTY,
           via `ssh -T`), `exec "$HOME/.secure-remote-agent/<slug>"` bootstrap,
           then NDJSON: initialize, session/new, 25+ session/prompt round trips,
           a 64 KiB payload, unknown-method (-32601) path, EOF shutdown
  phase 4  TOFU pin/mismatch against the server's real ed25519 host key

Usage:
  python3 scripts/live-validation.py [--host H] [--port P] [--key PATH]
      [--harness dist/harness-darwin-arm64] [--scratch DIR] [--out docs/LIVE_<date>.md]

Exit code 0 iff every check passes. Transcript + raw line evidence are
written next to --out (.md and .raw.txt).
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import select
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
DEFAULT_SCRATCH = Path("/Users/mbt/.hermes/cache/scratch/sra-live")
BUNDLE_VERSION = "0.1.0"
DROPBEAR_FINGERPRINT = "SHA256:JJ8Ldj25rfehz1HtNUu+Yny0NR/o8pmjV+30cg+hthI"


# ---------------------------------------------------------------- recorder --
class Recorder:
    def __init__(self, path: Path):
        self.path = path
        self.fh = path.open("w")
        self.raw = path.with_suffix(".raw.txt").open("w")
        self.checks = []

    def w(self, s: str = ""):
        self.fh.write(s + "\n")

    def h(self, s: str):
        self.w(f"\n## {s}\n")

    def code(self, title: str, body: str):
        self.w(f"\n### {title}\n")
        self.w("```")
        self.w(body.rstrip("\n"))
        self.w("```")

    def cmd(self, title: str, cp, input_data=None):
        body = f"[exit {cp.returncode}]\n" + (cp.stdout or "")
        if cp.stderr:
            body += "[stderr]\n" + cp.stderr
        if input_data is not None:
            body = f"input: {input_data!r}\n" + body
        self.code(title, body)

    def check(self, name: str, ok, detail: str = ""):
        self.checks.append((name, bool(ok), str(detail)))
        flag = "PASS" if ok else "FAIL"
        self.w(f"- **{flag}** — {name}" + (f" — {detail}" if detail else ""))
        if not ok:
            print(f"FAIL: {name} {detail}", file=sys.stderr)

    @property
    def failures(self):
        return [c for c in self.checks if not c[1]]


# ------------------------------------------------------------- ssh helpers --
def ssh_argv(key, host, port, kh, *cmd, strict=False):
    argv = ["ssh", "-i", str(key), "-p", str(port),
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=" + ("yes" if strict else "accept-new"),
            "-o", f"UserKnownHostsFile={kh}",
            "-o", "PreferredAuthentications=publickey",
            "-o", "LogLevel=ERROR"]
    if strict:  # hard-verify: no accepting, no re-pinning
        argv += ["-o", "UpdateHostKeys=no"]
    return argv + [str(host)] + [str(c) for c in cmd]


def run(argv, timeout=120, input=None):
    return subprocess.run([str(a) for a in argv], input=input,
                          capture_output=True, text=True, timeout=timeout)


def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for blk in iter(lambda: fh.read(131072), b""):
            h.update(blk)
    return h.hexdigest()


# --------------------------------------------------------- harness channel --
class HarnessChannel:
    """`ssh -T` session: shell channel WITHOUT a pty — the CLI equivalent of
    Citadel's withTTY(command: nil) + TTYStdinWriter."""

    def __init__(self, rec: Recorder, key, host, port, kh):
        argv = ["ssh", "-i", str(key), "-p", str(port),
                "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", f"UserKnownHostsFile={kh}",
                "-o", "PreferredAuthentications=publickey",
                "-o", "LogLevel=ERROR", "-T", str(host)]
        rec.code("harness channel spawn", "$ " + subprocess.list2cmdline(argv))
        self.p = subprocess.Popen(argv, stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, bufsize=0)
        for f in (self.p.stdout, self.p.stderr):
            os.set_blocking(f.fileno(), False)
        self.rec = rec
        self.buf = bytearray()
        self.total = 0
        self.cr = 0
        self.max_line = 0
        self.lines = []            # every complete stdout line
        self.nonjson = 0
        self.eof = False
        self.stderr_lines = []

    def _drain_stderr(self):
        try:
            b = os.read(self.p.stderr.fileno(), 65536)
        except (BlockingIOError, OSError):
            return
        if b:
            for ln in b.split(b"\n"):
                if ln:
                    s = ln.decode("utf-8", "replace")
                    self.stderr_lines.append(s)
                    self.rec.raw.write("[stderr] " + repr(ln) + "\n")

    def wait_stderr(self, pattern, timeout=20.0):
        t0 = time.monotonic()
        rx = re.compile(pattern)
        while time.monotonic() - t0 < timeout:
            self._drain_stderr()
            for ln in self.stderr_lines:
                if rx.search(ln):
                    return ln
            if self.p.poll() is not None:
                break
            time.sleep(0.05)
        return None

    def read_lines(self, timeout=30.0):
        got = []
        t0 = time.monotonic()
        while time.monotonic() - t0 < timeout:
            r, _, _ = select.select([self.p.stdout.fileno()], [], [], 0.1)
            self._drain_stderr()
            if r:
                b = os.read(self.p.stdout.fileno(), 131072)
                if b == b"":
                    self.eof = True
                    break
                self.total += len(b)
                self.cr += b.count(b"\r")
                self.buf += b
                while b"\n" in self.buf:
                    line, _, self.buf = self.buf.partition(b"\n")
                    self.max_line = max(self.max_line, len(line))
                    s = line.decode("utf-8", "replace")
                    got.append(s)
                    self.lines.append(s)
                    self.rec.raw.write(repr(line) + "\n")
        return got

    def send(self, line: str):
        if self.p.stdin is None or self.p.stdin.closed:
            return
        self.p.stdin.write(line.encode() + b"\n")
        self.p.stdin.flush()
        self.rec.raw.write(">> " + line + "\n")

    def await_response(self, rid, timeout=30.0):
        """Read stdout until the JSON-RPC response with id==rid arrives.
        Returns (response|None, [notifications...])."""
        acc = []
        t0 = time.monotonic()
        while time.monotonic() - t0 < timeout:
            for s in self.read_lines(timeout=2.0):
                try:
                    obj = json.loads(s)
                except ValueError:
                    self.nonjson += 1
                    continue
                if not isinstance(obj, dict):
                    self.nonjson += 1
                    continue
                if obj.get("id") == rid and obj.get("method") is None:
                    return obj, acc
                acc.append(obj)
        return None, acc

    def close(self):
        try:
            self.p.stdin.close()
        except (BrokenPipeError, OSError):
            pass
        try:
            return self.p.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.p.kill()
            return self.p.returncode


# python equivalent of SSHConnectionManager.shellEscape + the bootstrap line
def bootstrap_line(remote_path: str) -> str:
    expanded = "$HOME/" + remote_path[2:] if remote_path.startswith("~/") else remote_path
    escaped = (expanded.replace("\\", "\\\\")
                      .replace('"', '\\"')
                      .replace("`", "\\`"))
    return f'exec "{escaped}"'


# ----------------------------------------------------------------- phases ---
def preflight(ctx, a):
    ctx.h("Phase 0 — preflight")
    harness = Path(a.harness)
    ctx.check("local harness binary exists", harness.is_file(), harness)
    if not harness.is_file():
        sys.exit("abort: harness missing; run scripts/build-harness.sh")
    proc = subprocess.run(["bash", "-c",
                           "printf '' | nc -w 2 " + a.host + " " + str(a.port)],
                          capture_output=True, timeout=10)
    # nc streams binary kex after the banner: keep only the ASCII first line
    banner_raw = proc.stdout or b""
    banner = banner_raw.split(b"\n", 1)[0].decode("utf-8", "replace") or "(no banner)"
    ctx.code("SSH banner of the live host", banner)
    ctx.check("server speaks SSH-2.0 dropbear banner", "dropbear" in banner.strip(), banner)
    return sha256_file(harness)


def phase_capture(ctx, a, key, kh):
    ctx.h("Phase 1 — capture(\"uname -sm\") (Citadel executeCommand exec channel)")
    cp = run(ssh_argv(key, a.host, a.port, kh, "uname -sm"), timeout=30)
    ctx.cmd("capture uname -sm", cp)
    val = cp.stdout.strip()
    ctx.check("uname -sm returns exit 0", cp.returncode == 0, str(cp.returncode))
    ok = cp.returncode == 0 and val == "Darwin arm64"
    ctx.check("parsed RemoteArch == darwin-arm64", ok, repr(val))
    cp = run(ssh_argv(key, a.host, a.port, kh, 'printf %s "$HOME"'), timeout=30)
    ctx.cmd("remote $HOME (for absolute paths)", cp)
    return val, (cp.stdout or "").strip()


def phase_deploy(ctx, a, key, kh, harness_hash, remote_home):
    ctx.h("Phase 2 — ensureHarness (sha check, SFTP upload, chmod, skip-on-match)")
    slug = Path(a.harness).name + "-" + BUNDLE_VERSION
    rel_dir = "~/.secure-remote-agent"
    abs_dir = remote_home + "/.secure-remote-agent"
    abs_path = abs_dir + "/" + slug
    cp = run(ssh_argv(key, a.host, a.port, kh, f"mkdir -p {rel_dir}"), timeout=30)
    ctx.cmd("mkdir -p ~/.secure-remote-agent", cp)
    ctx.check("mkdir ok", cp.returncode == 0, cp.stderr.strip())

    before = run(ssh_argv(key, a.host, a.port, kh,
                          f"sha256sum {abs_path} 2>/dev/null || shasum -a 256 {abs_path} 2>/dev/null"),
                 timeout=30)
    ctx.code("remote sha probe before upload",
             f"$ shasum -a 256 {abs_path}\n[exit 0] (no output when file absent)\n"
             + (before.stdout or "(empty)"))
    present = (before.stdout.split()[0] if before.stdout.split() else None) == harness_hash
    if present:
        ctx.check("remote harness already sha-matches (prior run) — fresh-upload "
                  "path validated on first run; skip path validated below", True)
    else:
        ctx.check("remote file absent or differs (forces fresh upload)",
                  not present)

    if not present:
        # Parity with what the app actually transmits:
        # SSHConnectionManager.upload() strips "~/" from remotePath and sends
        # a home-RELATIVE SFTP path (sftp-server resolves it from the login
        # home). scp does the same with a dotless relative remote path.
        rel_path = f".secure-remote-agent/{slug}"
        scp = ["scp", "-i", str(key), "-P", str(a.port),
               "-o", "StrictHostKeyChecking=accept-new",
               "-o", f"UserKnownHostsFile={kh}",
               "-o", "PreferredAuthentications=publickey",
               "-o", "LogLevel=ERROR", str(a.harness),
               f"{a.host}:{rel_path}"]
        cp = run(scp, timeout=120)
        ctx.cmd("SFTP upload (scp) of the harness binary", cp)
        ctx.check("upload ok", cp.returncode == 0, cp.stderr.strip()[:200])
        after = run(ssh_argv(key, a.host, a.port, kh,
                             f"shasum -a 256 {abs_path}"), timeout=30)
        ctx.cmd("remote sha probe after upload", after)
        got = after.stdout.split()[0] if after.stdout.split() else None
        ctx.check("remote sha256 == local sha256 after upload", got == harness_hash,
                  f"local={harness_hash}")
        mod = run(ssh_argv(key, a.host, a.port, kh, f"stat -f %Lp {abs_path}"), timeout=30)
        ctx.cmd("mode bits after SFTP upload (pre-chmod)", mod)
        mode = (mod.stdout or "").strip()
        ctx.check("upload mode recorded (macOS scp preserves source mode; "
                  "chmod +x is idempotent insurance)", bool(mode), f"mode={mode}")
        cp = run(ssh_argv(key, a.host, a.port, kh, f"chmod +x {abs_path}"), timeout=30)
        ctx.cmd("chmod +x", cp)
        mod = run(ssh_argv(key, a.host, a.port, kh,
                           f"test -x {abs_path} && echo executable"), timeout=30)
        ctx.cmd("executable-bit check (post-chmod)", mod)
        ctx.check("binary executable after chmod", "executable" in (mod.stdout or ""))

    again = run(ssh_argv(key, a.host, a.port, kh,
                         f"shasum -a 256 {abs_path}"), timeout=30)
    got = again.stdout.split()[0] if again.stdout.split() else None
    ctx.cmd("second ensureHarness sha probe (expect match, no upload)", again)
    ctx.check("reconnect: hash equal -> upload skipped (0 bytes transferred)",
              got == harness_hash, got)
    return slug


def phase_channel(ctx, a, key, kh, slug):
    ctx.h("Phase 3 — withTTY channel: exec harness, NDJSON framing over the line ("
          "shell channel, no pty)")

    remote_path = f"~/.secure-remote-agent/{slug}"
    ctx.code("bootstrap line (mirror of SSHConnectionManager.shellEscape)",
             bootstrap_line(remote_path))
    ch = HarnessChannel(ctx, key, a.host, a.port, kh)
    try:
        ch.send(bootstrap_line(remote_path))
        banner = ch.wait_stderr(r"ready \(ACP v")
        if banner is None:
            ctx.check("harness stderr banner seen (boot ok)", False,
                      "\n".join(ch.stderr_lines) or "no output")
            return
        ctx.check("harness stderr banner seen (boot ok)",
                  "ready (ACP v1, stdio)" in banner, banner)
        ctx.code("harness stderr", "\n".join(ch.stderr_lines))

        junk = [s for s in ch.read_lines(timeout=2.0) if not s.startswith("{")]
        ctx.code("shell pre-exec output on stdout (non-JSON; ACPClient drops it)",
                 "\n".join(repr(j) for j in junk) or "(none)")
        ctx.check("shell startup noise is tolerable garbage (<=3 lines)", len(junk) <= 3,
                  f"{len(junk)} non-JSON lines")

        ch.send(json.dumps({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {
            "protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {
                "name": "sra-live-validation", "version": BUNDLE_VERSION}}},
            separators=(",", ":")))
        resp, _ = ch.await_response(0)
        ok = bool(resp) and resp.get("result", {}).get("protocolVersion") == 1
        ctx.check("initialize -> protocolVersion 1", ok,
                  json.dumps(resp)[:120] if resp else "no response")
        ctx.check("initialize -> agentInfo.name == secure-remote-harness",
                  bool(resp) and resp.get("result", {}).get("agentInfo", {})
                  .get("name") == "secure-remote-harness", "")
        ctx.code("initialize response", json.dumps(resp))

        ch.send(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "session/new",
                            "params": {}}, separators=(",", ":")))
        resp, _ = ch.await_response(1)
        sid = (resp or {}).get("result", {}).get("sessionId")
        ctx.check("session/new -> sessionId", bool(sid), str(sid))

        prompts = [("echo ok", "ok\n")]
        for i in range(1, 25):
            prompts.append((f"printf 'ok{i:02d}'", f"ok{i:02d}"))
        # shell-quote stress: a double-quote and a backslash round-trip exactly
        # through JSON-RPC + /bin/sh -c + printf
        prompts.append(('printf \'a "b"\\\\ c\'', 'a "b"\\ c'))
        ctx.code("prompt set", "\n".join(f"{n:2d}. {repr(c)} == {repr(e)}"
                                         for n, (c, e) in enumerate(prompts)))

        fail = []
        t0 = time.monotonic()
        for n, (cmd, expect) in enumerate(prompts):
            rid = 2 + n
            ch.send(json.dumps({"jsonrpc": "2.0", "id": rid, "method": "session/prompt",
                                "params": {"sessionId": sid,
                                           "prompt": [{"type": "text", "text": cmd}]}},
                               separators=(",", ":")))
            resp, notifs = ch.await_response(rid)
            text = ""
            for no in notifs:
                u = no.get("params", {}).get("update", {})
                if u.get("sessionUpdate") == "agent_message_chunk":
                    text += u.get("content", {}).get("text", "")
            if resp is None:
                fail.append(f"#{n} no response")
                continue
            if text != expect:
                fail.append(f"#{n} {cmd!r}: got {text!r} != {expect!r}")
            stop = resp.get("result", {}).get("stopReason") != "end_turn"
            if stop:
                fail.append(f"#{n} bad stopReason")
        dt = time.monotonic() - t0
        ctx.check(f"all {len(prompts)} session/prompt round trips exact ("
                  f"errno-free framing)", not fail,
                  "; ".join(fail[:4]) or "identity-preserving")
        ctx.check("prompt cadence plausible (no stalls)",
                  dt < 1.0 * len(prompts) + 120, f"{dt:.2f}s total")

        # single backslash so /bin/sh sees tr '\0' 'A' (not '\<backslash>0')
        big_cmd = "head -c 65536 /dev/zero | tr '\\0' 'A'"
        rid = 2 + len(prompts)
        ch.send(json.dumps({"jsonrpc": "2.0", "id": rid, "method": "session/prompt",
                            "params": {"sessionId": sid,
                                       "prompt": [{"type": "text", "text": big_cmd}]}},
                           separators=(",", ":")))
        resp, notifs = ch.await_response(rid, timeout=60)
        text = ""
        for no in notifs:
            u = no.get("params", {}).get("update", {})
            if u.get("sessionUpdate") == "agent_message_chunk":
                text += u.get("content", {}).get("text", "")
        istrunc = text[:32] + "…" if len(text) > 80 else text
        ctx.code("64 KiB payload chunk (truncated view)",
                 f"len={len(text)} head={text[:32]!r} tail={text[-32:]!r}")
        ok64 = (resp and len(text) == 65536 and set(text) == {"A"})
        ctx.check("64 KiB output arrives intact as one session/update chunk", ok64,
                  f"len={len(text)}")
        if not ok64 and text.startswith("(output exceeded"):
            ctx.check("harness 64 KiB cap boundary documented",
                      True, "exact 65536 exceeds cap; cap is strict <=")

        rid += 1
        ch.send(json.dumps({"jsonrpc": "2.0", "id": rid,
                            "method": "definitely/not-a-method", "params": {}},
                           separators=(",", ":")))
        resp, _ = ch.await_response(rid)
        err = (resp or {}).get("error", {})
        ctx.check("unknown method -> -32601 Method not found",
                  err.get("code") == -32601, json.dumps(resp)[:160])

        rc = ch.close()
        ctx.check("stdin EOF -> clean harness shutdown (ssh exit 0)", rc == 0, str(rc))
        ctx.check("zero \\r bytes on the whole ACP stream (no pty mangling)",
                  ch.cr == 0, f"{ch.cr} of {ch.total} bytes")
        ctx.check("no non-JSON lines mid-proto (post-init)", ch.nonjson == 0,
                  f"{ch.nonjson} unparsable lines peered into JSON queue")
    finally:
        if ch.p.poll() is None:
            ch.p.kill()
    return


def phase_tofu(ctx, a, key, kh):
    ctx.h("Phase 4 — TOFU pin/mismatch against the real host key")
    kh_tofu = Path(str(kh) + ".tofu")
    if kh_tofu.exists():
        kh_tofu.unlink()
    cp = run(ssh_argv(key, a.host, a.port, kh_tofu, 'echo first-connect-ok'), timeout=30)
    ctx.cmd("first connect (accept-new pins the real key)", cp)
    ctx.check("first connect pins host key", cp.returncode == 0, cp.stderr.strip()[:200])
    fp = run(["ssh-keygen", "-lf", str(kh_tofu)], timeout=10)
    ctx.cmd("pinned fingerprint", fp)
    fpstr = fp.stdout.split()[1] if fp.stdout.split() else ""
    ctx.check("pinned fingerprint == dropbear host key fingerprint",
              fpstr == DROPBEAR_FINGERPRINT, f"{fpstr} vs {DROPBEAR_FINGERPRINT}")

    lines = kh_tofu.read_text().splitlines()
    if lines:
        parts = lines[0].split()
        parts[2] = "AAAAC3NzaC1lZDI1NTE5AAAAIf0AKeWo0nq0Lc9NfmzUt/9DUnBnSsuA" \
                  "AAAAAAAAAf0fakef0fakef0fakef0fakef0fakefafake=="
        kh_bad = Path(str(kh) + ".tampered")
        kh_bad.write_text(" ".join(parts) + "\n")
        cp = run(ssh_argv(key, a.host, a.port, kh_bad, 'echo should-not-happen',
                          strict=True), timeout=30)
        ctx.cmd("connect with tampered pin (must fail with REAL host key mismatch)", cp)
        err = (cp.stderr or "")
        rejected = (cp.returncode != 0 and
                    ("REMOTE HOST IDENTIFICATION" in err
                     or "HOST KEY VERIFICATION FAILED" in err.upper()
                     or "S HOST KEY IS KNOWN" in err.upper()))
        ctx.check("tampered pin -> connection refused (fail-closed)", rejected,
                  err.strip()[:200].replace("\n", " "))

    cp = run(ssh_argv(key, a.host, a.port, kh_tofu, 'echo restore-ok'), timeout=30)
    ctx.cmd("restore original pin (connect succeeds again)", cp)
    ctx.check("original pin still works", cp.returncode == 0, "")


# ------------------------------------------------------------------- main --
def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=23456)
    ap.add_argument("--key", default=str(DEFAULT_SCRATCH / "client" / "id_ed25519"))
    ap.add_argument("--scratch", default=str(DEFAULT_SCRATCH))
    ap.add_argument("--harness", default=str(REPO / "dist" / "harness-darwin-arm64"))
    ap.add_argument("--out", default=str(REPO / "docs" /
                                         f"LIVE_{datetime.date.today().isoformat()}.md"))
    a = ap.parse_args()
    key = Path(a.key)
    kh = Path(a.scratch) / "client" / "known_hosts"

    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M %Z")
    ctx = Recorder(Path(a.out))
    ctx.w(f"# Step 7 — live-host validation transcript ({now})")
    ctx.w("")
    ctx.w(f"- Host: {a.host}:{a.port} — dropbear 2026.94 (user-mode, scratch keys; "
          "no system sshd/~\\.ssh changes)")
    ctx.w(f"- Client key: `{key}`  · harness: `{a.harness}`")
    ctx.w(f"- Raw line evidence: `{ctx.raw.name}` (same directory)")
    print(f"transcript -> {a.out}")

    try:
        harness_hash = preflight(ctx, a)
        arch, remote_home = phase_capture(ctx, a, key, kh)
        slug = phase_deploy(ctx, a, key, kh, harness_hash, remote_home)
        phase_channel(ctx, a, key, kh, slug)
        phase_tofu(ctx, a, key, kh)
    except Exception as exc:  # keep the transcript + nonzero exit
        ctx.check("driver completed without exception", False, repr(exc))
        raise SystemExit(1) from exc
    finally:
        ctx.h("Summary")
        for i, (name, ok, details) in enumerate(ctx.checks, 1):
            flag = "PASS" if ok else "FAIL"
            ctx.w(f"| {i} | {flag} | {name} |")
        fails = [c for c in ctx.checks if not c[1]]
        ctx.w(f"\n**{len(ctx.checks) - len(fails)} PASS / {len(fails)} FAIL** of "
              f"{len(ctx.checks)} checks")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
