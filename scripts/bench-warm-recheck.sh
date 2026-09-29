#!/usr/bin/env bash
# usage: bench-warm-recheck.sh [--rounds N] [--no-cold-check] <command...> [file]
#
# Measures the one number that justifies a long-lived language server at all: how much
# cheaper a recheck of an open buffer is than a cold `check` of the same file. If that
# ratio is not large, the server is a slower way to run `check` and should not exist --
# self-hosted check cost is PER INVOCATION and reloads the whole module closure, so the
# only thing a long-lived process can possibly sell is that closure staying warm.
#
#   scripts/bench-warm-recheck.sh ./out/monad lsp
#   scripts/bench-warm-recheck.sh ./out/monad lsp lang/src/module.mo
#   scripts/bench-warm-recheck.sh ./target/release/monad-rs run cli/src/main.mo lsp
#
# The command is split in two at the last argument that names an existing file: that
# argument is the file to open, and everything before it is the server command. Put the
# file last, or pass --rounds/--no-cold-check and let the default file stand.
#
# WHAT IS MEASURED, all on one process, timed with a monotonic clock:
#
#   startup   spawn -> the `initialize` response. A server that takes longer than a
#             couple of hundred milliseconds to answer the handshake stalls every editor
#             that opens a file.
#   cold      didOpen -> `publishDiagnostics` for that buffer. The server's own first
#             recheck, on a cache nothing has warmed yet.
#   warm      didChange -> `publishDiagnostics`, over several rounds. Each round appends
#             a comment line, which changes the buffer (so the server cannot skip the
#             work on an unchanged-content hash) without changing a single declaration
#             (so dependencies, and therefore the expensive part, stay as they were).
#   check     a separate `check` process on the same file, wall-clock. This is the thing
#             the warm recheck is being compared against.
#
# THE GATE IS THE COMPILED BINARY. The interpreted numbers are evidence about the
# protocol layer and nothing else; codegen is the whole reason this server is written in
# Monad, and a cold `check` of a large file under the interpreter is a different shape of
# slow. Pass the compiled binary's own `lsp` subcommand.
#
# Exit status is 0 only if every target below is met:
#
#   startup < TARGET_STARTUP_MS, warm median < TARGET_WARM_MS, and the warm recheck at
#   least MIN_SPEEDUP times cheaper than the cold `check`.
#
# The numbers are printed either way, because a failing gate whose numbers are not
# recorded is a gate nobody can act on.
#
# MEASURED 2026-09-29, compiled binary (`/tmp/monad-lsp-out2/monad lsp`, the tree at
# 1c37a6f0), default file (lang/src/module.mo, 331154 bytes / 6433 lines):
#
#   startup (spawn -> initialize)        2.1 ms     PASS (< 200 ms)
#   cold recheck (didOpen)            8262.8 ms     (0 diagnostics)
#   warm recheck median               4365.2 ms     (min 3937.6 over 5 rounds)
#   cold `check` process              6275.9 ms
#   ratio                                 1.4x     FAIL (>= 10x)
#
# BOTH warm targets FAIL, and the cache is not the reason. `cold - warm =
# 3897.6 ms` is exactly what a warm closure is worth here, and the whole cold
# `check` is 6275.9 ms -- so subtracting puts `check`'s OWN parse and elaboration
# of the same file at ~2378 ms, i.e. the closure is the smaller half of a cold
# `check`. The server is already collecting the whole of the cache's value; the
# ratio is pinned near its ceiling for this file (6275.9 / 4365.2 = 1.44, measured
# 1.4). MIN_SPEEDUP's 10x assumes a cold `check` dominated by the closure load,
# which is true of a file with a heavy closure and a SMALL text -- not of the
# corpus's largest file.
#
# The irreducible term is the buffer's own parse+check, redone on every change,
# and reading the path shows two costs in it:
#
#   * the buffer is parsed TWICE per recheck: once by
#     `decls_parser_located_with_ranges` for the declaration ranges, then again
#     inside `elaborate_loaded_modules_cached_go`, which is handed the same source
#     string (the entry point's own doc says so: it "parses separately");
#   * the incoming `didChange` JSON -- 331 KB escaped inside one frame -- goes
#     through `Json.parse_string_content`, which is per character: ~10 failed
#     tags, one `String.slice` and one cons per byte of the buffer.
#
# Neither is measured by this script; a probe timing each against a 331 KB source
# is the next step. Neither alone reaches 200 ms on its own while the compiled
# parse stays superlinear (n^1.19 measured on synthetic source), so the 200 ms
# target needs a smaller parse, not a warmer cache.
set -euo pipefail

usage() {
  sed -n '2,3p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

rounds=5
cold_check=1
while [ $# -gt 0 ]; do
  case "$1" in
    --rounds) rounds="${2:-}"; shift 2 ;;
    --rounds=*) rounds="${1#*=}"; shift ;;
    --no-cold-check) cold_check=0; shift ;;
    -h|--help) usage ;;
    *) break ;;
  esac
done

[ $# -ge 1 ] || usage

# The trailing file, if the last argument names one. `check` and the editor both need a
# file, and a command that ends in one is the natural spelling.
file="lang/src/module.mo"
if [ $# -ge 2 ] && [ -f "${!#}" ]; then
  file="${!#}"
  set -- "${@:1:$#-1}"
fi

bin="$1"
case "$bin" in
  /*) ;;
  */*) bin="$PWD/$bin" ;;
  *) bin="$(command -v -- "$bin" || true)" ;;
esac
[ -n "$bin" ] && [ -x "$bin" ] || { echo "bench-warm-recheck: not executable: $1" >&2; exit 2; }
shift
cmd=("$bin" "$@")

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$root/$file" ] || { echo "bench-warm-recheck: no such file: $file" >&2; exit 2; }
file="$root/$file"

exec python3 - "$root" "$file" "$rounds" "$cold_check" "${cmd[@]}" <<'PY'
import json, os, re, select, subprocess, sys, time

root, path, rounds, cold_check = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4] == "1"
cmd = sys.argv[5:]

# The targets. STARTUP and WARM are budget numbers: 200 ms is about where an editor
# action stops feeling immediate, and a keystroke is not much more than that, so a
# recheck that takes longer than the typing it is reacting to is a recheck nobody wants.
# MIN_SPEEDUP is the reading of "dramatically faster" this gate commits to.
TARGET_STARTUP_MS = 200.0
TARGET_WARM_MS = 200.0
MIN_SPEEDUP = 10.0

failures = []


def check(label, ok, detail=""):
    print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f"  -- {detail}" if detail else ""))
    if not ok:
        failures.append(label)


def ms(t):
    return t * 1000.0


# --- A minimal incremental client --------------------------------------------
#
# The whole point of the measurement is the ROUND TRIP, so the session cannot be fed to
# the server as one blob and timed as a whole: every didChange has to be written, and
# its diagnostics read back, before the next one is sent. That means a pipe reader with a
# deadline rather than subprocess.communicate.


class Reader:
    def __init__(self, fd):
        self.fd = fd
        self.buf = bytearray()

    def _need(self, n, deadline):
        while len(self.buf) < n:
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError(f"timed out with {len(self.buf)} byte(s) buffered")
            if not select.select([self.fd], [], [], left)[0]:
                continue
            chunk = os.read(self.fd, 65536)
            if not chunk:
                raise EOFError("the server closed its stdout")
            self.buf += chunk

    def message(self, deadline):
        while True:
            i = self.buf.find(b"\r\n\r\n")
            if i >= 0:
                head = bytes(self.buf[:i])
                m = re.search(rb"Content-Length:\s*(\d+)", head)
                if not m:
                    raise ValueError(f"no Content-Length in {head!r}")
                n = int(m.group(1))
                self._need(i + 4 + n, deadline)
                body = bytes(self.buf[i + 4:i + 4 + n])
                del self.buf[:i + 4 + n]
                return json.loads(body)
            self._need(len(self.buf) + 1, deadline)


class Server:
    def __init__(self):
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, cwd=root)
        self.r = Reader(self.p.stdout.fileno())
        self.n = 0

    def send(self, msg):
        body = json.dumps(msg).encode()
        self.p.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        self.p.stdin.flush()

    def await_(self, pred, what, timeout=1800.0):
        """The next message matching `pred`, and how long it took."""
        t0 = time.monotonic()
        deadline = t0 + timeout
        while True:
            msg = self.r.message(deadline)
            if pred(msg):
                return msg, time.monotonic() - t0

    def close(self):
        try:
            self.p.stdin.close()
        except BrokenPipeError:
            pass
        try:
            self.p.wait(timeout=60)
        except subprocess.TimeoutExpired:
            self.p.kill()


def diagnostics_for(server, uri, timeout=1800.0):
    return server.await_(lambda m: m.get("method") == "textDocument/publishDiagnostics"
                         and m["params"]["uri"] == uri, f"diagnostics for {uri}", timeout)


# --- Session -----------------------------------------------------------------

uri = "file://" + path  # `file://` + an absolute path -- three slashes, per the spec
text = open(path, encoding="utf-8").read()

print(f"=== {os.path.basename(path)}  ({len(text)} bytes, {text.count(chr(10))} lines)")
print(f"    server: {' '.join(cmd)}")

t_spawn = time.monotonic()
server = Server()
try:
    server.send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "rootUri": "file://" + root,
        "capabilities": {"general": {"positionEncodings": ["utf-8"]}}}})
    _init, startup = server.await_(lambda m: m.get("id") == 1, "initialize response", 300.0)
    startup = time.monotonic() - t_spawn

    server.send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
    server.send({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
        "textDocument": {"uri": uri, "languageId": "monad", "version": 1, "text": text}}})
    cold_msg, cold = diagnostics_for(server, uri)
    cold_count = len(cold_msg["params"]["diagnostics"])

    warms, counts = [], []
    for i in range(rounds):
        text = text + f"\n// warm recheck probe {i + 1}\n"
        server.send({"jsonrpc": "2.0", "method": "textDocument/didChange", "params": {
            "textDocument": {"uri": uri, "version": i + 2},
            "contentChanges": [{"text": text}]}})
        msg, dt = diagnostics_for(server, uri)
        warms.append(dt)
        counts.append(len(msg["params"]["diagnostics"]))

    server.send({"jsonrpc": "2.0", "id": 2, "method": "shutdown", "params": None})
    server.await_(lambda m: m.get("id") == 2, "shutdown response", 60.0)
    server.send({"jsonrpc": "2.0", "method": "exit", "params": None})
    rc = server.p.wait(timeout=60)
finally:
    try:
        server.close()
    except Exception:
        pass

warms.sort()
warm_median = warms[len(warms) // 2]
warm_min = warms[0]

# A clean file publishes an empty array, so this is not "we saw diagnostics"; it is
# "the server answered about this buffer and found nothing", which is the answer a warm
# recheck of an unchanged-declaration buffer has to give every single round.
check("every round answers about this buffer", len(counts) == rounds, f"{len(counts)}/{rounds}")
check("the file checked clean throughout", set([cold_count] + counts) == {0},
      f"cold={cold_count}, warm={counts}")

cold_check_ms = None
cold_check_note = ""
if cold_check:
    # A cold `check` of the same file, in its own process, with its own cold cache. The
    # exit status is deliberately not asserted: a non-zero here would mean the file has
    # diagnostics, which the LSP rounds above have already spoken about.
    #
    # The subcommand is the command's LAST argument (`lsp`), so it is replaced rather
    # than appended to: that keeps both spellings working -- `./out/monad lsp` and the
    # host's `./target/release/monad-rs run cli/src/main.mo lsp`.
    #
    # The subprocess is on a leash, and a timeout is not a failure -- it is the ratio
    # being large. Check cost is PER INVOCATION: `check` on one file loads the whole
    # module closure, exactly as `check` on all of them does, so on a big file this leg
    # is expected to run for minutes and a bound is the only way to keep the gate
    # usable. The bound then stands in as a lower bound on the real number.
    limit = float(os.environ.get("BENCH_CHECK_TIMEOUT", "1800"))
    t0 = time.monotonic()
    try:
        subprocess.run(cmd[:-1] + ["check", path], cwd=root, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=limit)
    except subprocess.TimeoutExpired:
        cold_check_note = f">= {limit:.0f}s, timed out (a lower bound)"
    cold_check_ms = ms(time.monotonic() - t0)

print()
print(f"    startup (spawn -> initialize)  {ms(startup):9.1f} ms")
print(f"    cold recheck (didOpen)         {ms(cold):9.1f} ms   ({cold_count} diagnostic(s))")
print(f"    warm recheck median            {ms(warm_median):9.1f} ms   (min {ms(warm_min):.1f} ms over {rounds})")
if cold_check_ms is not None:
    print(f"    cold `check` process           {cold_check_ms:9.1f} ms   {cold_check_note}")
else:
    print(f"    cold `check` process           skipped")
print()

check(f"startup < {TARGET_STARTUP_MS:.0f} ms", ms(startup) < TARGET_STARTUP_MS, f"{ms(startup):.1f} ms")
check(f"warm recheck < {TARGET_WARM_MS:.0f} ms", ms(warm_median) < TARGET_WARM_MS,
      f"{ms(warm_median):.1f} ms")

if cold_check_ms is not None:
    speedup = cold_check_ms / ms(warm_median) if warm_median > 0 else float("inf")
    check(f"warm recheck at least {MIN_SPEEDUP:.0f}x cheaper than a cold `check`",
          speedup >= MIN_SPEEDUP, f"{speedup:.1f}x")

print()
if failures:
    print(f"FAILED {len(failures)} target(s):")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)
print("all targets met")
PY
