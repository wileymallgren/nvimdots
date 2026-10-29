"""Jupyter bridge for lua/config/kernel: owns the kernels and talks to Neovim
over stdio, one JSON object per line.

Requests (stdin):
  {"op": "start", "id", "kernel_name", "cwd"}
  {"op": "execute", "id", "req", "code", "history"}
  {"op": "complete", "id", "req", "code", "cursor"}
  {"op": "is_complete", "id", "req", "code"}
  {"op": "input_reply", "id", "value"}
  {"op": "interrupt" | "restart" | "shutdown", "id"}

Events (stdout), all with "id" (the kernel) and, for request output, "req":
  started {language}, start_failed {error}, status {state}, restarted, died,
  running (the kernel began a request),
  stream {name, text}, result / display {text, image, count}, clear,
  error {ename, evalue, traceback}, input_request {prompt, password},
  done {ok, count, ename, evalue}, complete {matches, start, end},
  is_complete {status, indent}

Run with ~/.venvs/nvim/bin/python -I (needs jupyter_client). Exits, shutting
the kernels down, when stdin closes (i.e. when Neovim quits).
"""

import base64
import contextlib
import json
import os
import queue
import re
import shutil
import signal
import sys
import tempfile
import threading
import time

import zmq
from jupyter_client.manager import KernelManager

ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
IMAGE_DIR = tempfile.mkdtemp(prefix="nvim-kernel-")
out_lock = threading.Lock()


def emit(**event):
    line = json.dumps(event) + "\n"
    with out_lock:
        sys.stdout.write(line)
        sys.stdout.flush()


def plain(text):
    return ANSI.sub("", text or "")


class Kernel:
    def __init__(self, kid, kernel_name, cwd):
        self.id = kid
        self.km = KernelManager(kernel_name=kernel_name)
        self.km.start_kernel(cwd=cwd or None)
        self.kc = self.km.client()
        self.kc.start_channels()
        self.kc.wait_for_ready(timeout=120)
        info = self.km.kernel_spec
        self.language = (info.language if info else "").lower()
        self.todo = queue.Queue()
        self.reqs = {}  # msg_id -> {"req", "reply", "idle"}
        self.alive = True
        self.n_images = 0
        threading.Thread(target=self.loop, daemon=True).start()

    def channels(self):
        chans = [self.kc.iopub_channel, self.kc.shell_channel, self.kc.stdin_channel]
        poller = zmq.Poller()
        for ch in chans:
            poller.register(ch.socket, zmq.POLLIN)
        return chans, poller

    # All socket work happens on this thread: zmq sockets aren't thread-safe.
    def loop(self):
        chans, poller = self.channels()
        last_check = time.time()
        while self.alive:
            while not self.todo.empty():
                if self.run(self.todo.get()) == "reconnected":
                    chans, poller = self.channels()
                if not self.alive:
                    return
            poller.poll(20)
            for ch in chans:
                while ch.msg_ready():
                    self.handle(ch, ch.get_msg(timeout=0))
            if time.time() - last_check > 1:
                last_check = time.time()
                if not self.km.is_alive():
                    self.died()

    def died(self):
        for msg_id, r in list(self.reqs.items()):
            emit(
                ev="done",
                id=self.id,
                req=r["req"],
                ok=False,
                ename="KernelDied",
                evalue="The kernel died",
            )
        self.reqs.clear()
        self.alive = False
        emit(ev="died", id=self.id)

    def run(self, cmd):
        op = cmd["op"]
        if op == "execute":
            msg_id = self.kc.execute(
                cmd["code"],
                store_history=cmd.get("history", True),
                allow_stdin=True,
                stop_on_error=False,
            )
            self.reqs[msg_id] = {
                "req": cmd["req"],
                "reply": None,
                "idle": False,
                "execute": True,
            }
        elif op == "complete":
            msg_id = self.kc.complete(cmd["code"], cmd.get("cursor"))
            self.reqs[msg_id] = {"req": cmd["req"], "reply": None, "idle": True}
        elif op == "is_complete":
            msg_id = self.kc.is_complete(cmd["code"])
            self.reqs[msg_id] = {"req": cmd["req"], "reply": None, "idle": True}
        elif op == "input_reply":
            self.kc.input(cmd.get("value", ""))
        elif op == "interrupt":
            self.km.interrupt_kernel()
        elif op == "restart":
            for r in self.reqs.values():
                emit(
                    ev="done",
                    id=self.id,
                    req=r["req"],
                    ok=False,
                    ename="Restarted",
                    evalue="",
                )
            self.reqs.clear()
            # The restart closes the old client's sockets: connect a new one
            self.kc.stop_channels()
            self.km.restart_kernel(now=True)
            self.kc = self.km.client()
            self.kc.start_channels()
            self.kc.wait_for_ready(timeout=120)
            emit(ev="restarted", id=self.id)
            return "reconnected"
        elif op == "shutdown":
            self.shutdown()

    def shutdown(self):
        self.alive = False
        with contextlib.suppress(
            zmq.ZMQError, RuntimeError, OSError
        ):  # going away anyway
            self.kc.stop_channels()
            self.km.shutdown_kernel(now=False)

    def bundle(self, data):
        text = data.get("text/plain")
        image = None
        if "image/png" in data:
            self.n_images += 1
            image = os.path.join(
                IMAGE_DIR, f"{self.id.replace(':', '_')}-{self.n_images}.png"
            )
            with open(image, "wb") as f:
                f.write(base64.b64decode(data["image/png"]))
        return plain(text) if text is not None else None, image

    def finish(self, msg_id):
        r = self.reqs.get(msg_id)
        if r and r["reply"] is not None and r["idle"]:
            del self.reqs[msg_id]
            c = r["reply"]
            emit(
                ev="done",
                id=self.id,
                req=r["req"],
                ok=c.get("status") == "ok",
                count=c.get("execution_count"),
                ename=c.get("ename"),
                evalue=plain(c.get("evalue")),
            )

    def handle(self, ch, msg):
        parent = msg.get("parent_header", {}).get("msg_id")
        kind = msg["header"]["msg_type"]
        c = msg["content"]
        r = self.reqs.get(parent)
        if kind == "status":
            emit(ev="status", id=self.id, state=c["execution_state"])
            if r and r.get("execute") and c["execution_state"] == "busy":
                emit(ev="running", id=self.id, req=r["req"])
            if r and c["execution_state"] == "idle":
                r["idle"] = True
                self.finish(parent)
            return
        if not r:
            return
        req = r["req"]
        if kind == "stream":
            emit(
                ev="stream", id=self.id, req=req, name=c["name"], text=plain(c["text"])
            )
        elif kind in ("execute_result", "display_data"):
            text, image = self.bundle(c.get("data", {}))
            emit(
                ev="result" if kind == "execute_result" else "display",
                id=self.id,
                req=req,
                text=text,
                image=image,
                count=c.get("execution_count"),
            )
        elif kind == "error":
            emit(
                ev="error",
                id=self.id,
                req=req,
                ename=c.get("ename"),
                evalue=plain(c.get("evalue")),
                traceback=[plain(t) for t in c.get("traceback", [])],
            )
        elif kind == "clear_output":
            emit(ev="clear", id=self.id, req=req)
        elif kind == "input_request":
            emit(
                ev="input_request",
                id=self.id,
                req=req,
                prompt=c.get("prompt", ""),
                password=c.get("password", False),
            )
        elif kind == "execute_reply":
            r["reply"] = c
            self.finish(parent)
        elif kind == "complete_reply":
            del self.reqs[parent]
            emit(
                ev="complete",
                id=self.id,
                req=req,
                matches=c.get("matches", []),
                start=c.get("cursor_start"),
                end=c.get("cursor_end"),
            )
        elif kind == "is_complete_reply":
            del self.reqs[parent]
            emit(
                ev="is_complete",
                id=self.id,
                req=req,
                status=c.get("status"),
                indent=c.get("indent", ""),
            )


kernels = {}


def start(cmd):
    kid = cmd["id"]
    try:
        k = Kernel(kid, cmd["kernel_name"], cmd.get("cwd"))
    except Exception as e:  # noqa: BLE001 - reported to Neovim
        emit(ev="start_failed", id=kid, error=f"{type(e).__name__}: {e}")
        return
    kernels[kid] = k
    emit(ev="started", id=kid, language=k.language)


def shutdown_all():
    for k in list(kernels.values()):
        k.shutdown()
    shutil.rmtree(IMAGE_DIR, ignore_errors=True)


def main():
    signal.signal(signal.SIGINT, signal.SIG_IGN)  # interrupts go to kernels, not here
    signal.signal(signal.SIGTERM, lambda *_: (shutdown_all(), os._exit(0)))
    for line in sys.stdin:
        try:
            cmd = json.loads(line)
        except ValueError:
            continue
        op, kid = cmd.get("op"), cmd.get("id")
        if op == "start":
            if kid in kernels and kernels[kid].alive:
                emit(ev="started", id=kid, language=kernels[kid].language)
            else:
                threading.Thread(target=start, args=(cmd,), daemon=True).start()
        elif kid in kernels:
            kernels[kid].todo.put(cmd)
            if op == "shutdown":
                del kernels[kid]
    shutdown_all()


if __name__ == "__main__":
    main()
