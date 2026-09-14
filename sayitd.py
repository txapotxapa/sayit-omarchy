#!/usr/bin/env python3
"""sayitd — local text-to-speech daemon for Linux, inspired by callebtc/sayit.

Owns one Kokoro model, a FIFO speech queue and the audio device. Clients talk
to it over a Unix socket with one JSON request per connection:

    {"cmd": "say", "text": "...", "voice": null, "speed": null, "replace": false}

Synthesis runs sentence by sentence ahead of playback, so the first words play
after a fraction of a second and queued utterances play back to back. The model
is dropped from memory after `idle_unload_minutes` without speech.
"""

import ctypes
import gc
import json
import os
import re
import signal
import socket
import sys
import threading
import time
from collections import deque
from pathlib import Path

import numpy as np
import sounddevice as sd

HOME = Path.home()
DATA = Path(os.environ.get("XDG_DATA_HOME", HOME / ".local/share")) / "sayit"
STATE = Path(os.environ.get("XDG_STATE_HOME", HOME / ".local/state")) / "sayit"
CONFIG_FILE = Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config")) / "sayit/config.json"
RUNTIME = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
SOCKET = RUNTIME / "sayit.sock"
STATUS_FILE = RUNTIME / "sayit-state.json"   # watched by the bar widget
MODEL = DATA / "models/kokoro-v1.0.onnx"
VOICES = DATA / "models/voices-v1.0.bin"
HISTORY = STATE / "history.jsonl"
HISTORY_KEEP = 200

SAMPLE_RATE = 24000
BLOCK = SAMPLE_RATE // 20          # 50 ms writes: pause/skip react within ~50 ms
MAX_AHEAD_SECONDS = 90             # stop synthesizing this far ahead of playback
CLOSE_DEVICE_AFTER = 3.0           # release the audio sink after this much silence
ENV_STEP = SAMPLE_RATE // 10       # waveform resolution for the player: 100 ms
SECONDS_PER_CHAR = 0.068           # Kokoro at speed 1, used until real timings exist

DEFAULTS = {
    "voice": "af_heart",
    "speed": 1.0,
    "volume": 1.0,
    "auto_language": True,         # read Spanish text with the Spanish voice
    "spanish_voice": "em_alex",
    "idle_unload_minutes": 10,
}

# Kokoro voice-name prefix -> espeak language code.
LANG_BY_PREFIX = {
    "a": "en-us", "b": "en-gb", "e": "es", "f": "fr-fr", "h": "hi",
    "i": "it", "p": "pt-br", "j": "ja", "z": "cmn",
}

ES_WORDS = set("""de la que el en los se del las un por con una su para es al lo
como más pero sus le ya o este sí porque esta entre cuando muy sin sobre también
me hasta hay donde quien desde todo nos durante todos uno les ni contra otros
ese eso ante ellos e esto mí antes algunos qué unos yo otro otras otra él tanto
esa estos mucho quienes nada muchos cual poco ella estar estas algunas algo
nosotros mi mis tú te ti tu tus ellas nosotras vosotros usted ustedes está son
fue ser tiene hola gracias""".split())
EN_WORDS = set("""the be to of and a in that have i it for not on with he as you
do at this but his by from they we say her she or an will my one all would
there their what so up out if about who get which go me when make can like time
no just him know take people into year your good some could them see other than
then now look only come its over think also back after use two how our work
first well way even new want because any these give day most us is are was
were has had been""".split())

log_lock = threading.Lock()


def log(*args):
    with log_lock:
        print(time.strftime("%H:%M:%S"), *args, flush=True)


def load_config():
    cfg = dict(DEFAULTS)
    try:
        cfg.update(json.loads(CONFIG_FILE.read_text()))
    except FileNotFoundError:
        pass
    except Exception as exc:  # a broken config must not take speech down
        log("config ignored:", exc)
    return cfg


def save_config(cfg):
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    changed = {k: v for k, v in cfg.items() if DEFAULTS.get(k) != v}
    CONFIG_FILE.write_text(json.dumps(changed, indent=2) + "\n")


def looks_spanish(text):
    words = re.findall(r"[a-záéíóúüñ]+", text.lower())
    if not words:
        return False
    es = sum(w in ES_WORDS for w in words)
    en = sum(w in EN_WORDS for w in words)
    accents = len(re.findall(r"[áéíóúñ¿¡]", text.lower()))
    return es + accents > en * 1.3 and es + accents >= 2


def clean_text(text):
    """Make pasted Markdown / terminal text pleasant to hear."""
    text = re.sub(r"```.*?```", " (code block) ", text, flags=re.S)
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)           # links
    text = re.sub(r"https?://\S+", "link", text)
    text = re.sub(r"(\*\*|__|\*|~~)(\S.*?\S|\S)\1", r"\2", text)
    text = re.sub(r"^[ \t]*[|:\- \t]+[ \t]*$", "", text, flags=re.M)         # table rules
    text = re.sub(r"^[ \t]*\|[ \t]*|[ \t]*\|[ \t]*$", "", text, flags=re.M)      # table edges
    text = re.sub(r"[ \t]*\|[ \t]*", ", ", text)

    # Headings and list items: drop the marker and end the line with a pause
    # so it is not read as one breath with the next line.
    def item(m):
        body = m.group(2).rstrip()
        return body if re.search(r"[.!?:;,…]$", body) else body + "."
    text = re.sub(r"^[ \t]{0,3}(#{1,6}|>|[-*+]|\d+[.)])[ \t]+(.*)$", item, text, flags=re.M)
    return text


def split_chunks(text, limit=280):
    """Sentence-sized pieces that grow: ~40, 100, 250, then `limit` chars.

    Synthesis runs ~4x faster than playback, so each piece is ready before the
    previous one finishes playing, while the first words start quickly."""
    caps = (40, 100, 250)
    parts = []

    def cap():
        return min(limit, caps[len(parts)]) if len(parts) < len(caps) else limit

    def cut_point(s, c):
        comma = s.rfind(", ", 0, c)
        if comma > c // 3:
            return comma + 1
        space = s.rfind(" ", 0, c)
        return space if space > c // 3 else c

    for para in re.split(r"\n\s*\n", text):
        para = " ".join(para.split())
        if not para:
            continue
        buf = ""
        for s in re.split(r"(?<=[.!?;:…])\s+(?=\S)", para):
            while s:
                c = cap()
                if buf and len(buf) + 1 + len(s) > c:
                    parts.append(buf)
                    buf = ""
                elif not buf and len(s) > c:
                    cut = cut_point(s, c)
                    parts.append(s[:cut].strip())
                    s = s[cut:].lstrip()
                else:
                    buf = f"{buf} {s}".strip()
                    s = ""
            if not parts and len(buf) >= 20:     # first sentence alone: fast start
                parts.append(buf)
                buf = ""
        if buf:
            parts.append(buf)
    return parts


class Job:
    _next = 1

    def __init__(self, text, voice, speed, lang, source):
        self.id = Job._next
        Job._next += 1
        self.text = text
        self.voice = voice
        self.speed = speed
        self.lang = lang
        self.source = source
        self.chunks = split_chunks(clean_text(text))
        self.audio = []            # synthesized arrays, index-aligned with chunks
        self.synth_done = False
        self.cancelled = False
        self.error = None
        self.pos = 0               # samples played across the whole job
        self.epoch = 0             # bumped when synthesized audio is thrown away
        self.env = []              # per-chunk peak envelopes (ENV_STEP buckets)
        self.done = threading.Event()

    def synthesized_samples(self):
        return sum(len(a) for a in self.audio)

    def chunk_at(self, pos):
        offset = 0
        for i, a in enumerate(self.audio):
            if pos < offset + len(a):
                return i
            offset += len(a)
        return max(0, len(self.audio) - 1)

    def resynthesize_from(self, index, speed):
        """Drop audio for chunks >= index so they are redone at a new speed."""
        self.speed = speed
        self.epoch += 1
        del self.audio[index:]
        del self.env[index:]
        self.synth_done = len(self.audio) == len(self.chunks)

    def estimated_seconds(self):
        done_chars = sum(len(c) for c in self.chunks[:len(self.audio)])
        done_secs = self.synthesized_samples() / SAMPLE_RATE
        rate = done_secs / done_chars if done_chars > 40 else SECONDS_PER_CHAR / self.speed
        rest = sum(len(c) for c in self.chunks[len(self.audio):])
        return done_secs + rest * rate

    def timeline(self):
        out, start = [], 0.0
        for i, text in enumerate(self.chunks):
            item = {"text": text}
            if i < len(self.audio):
                dur = len(self.audio[i]) / SAMPLE_RATE
                item.update(start=round(start, 3), dur=round(dur, 3))
                start += dur
            out.append(item)
        return out

    def summary(self, played=None):
        d = {
            "id": self.id,
            "text": self.text if len(self.text) <= 120 else self.text[:117] + "...",
            "voice": self.voice,
            "speed": self.speed,
            "source": self.source,
            "chunks": len(self.chunks),
            "synthesized": len(self.audio),
        }
        if played is not None:
            d["position"] = round(self.pos / SAMPLE_RATE, 1)
            d["buffered"] = round(self.synthesized_samples() / SAMPLE_RATE, 1)
        return d


class Engine:
    def __init__(self):
        self.cfg = load_config()
        self.cond = threading.Condition()
        self.queue = deque()        # jobs waiting to play (current one excluded)
        self.current = None
        self.paused = False
        self.kokoro = None
        self.voices = []
        self.last_activity = time.monotonic()
        self.seek_request = None
        self.flowing = False        # audio is actually being written right now
        STATE.mkdir(parents=True, exist_ok=True)
        with self.cond:
            self._publish()
        threading.Thread(target=self._synth_loop, name="synth", daemon=True).start()
        threading.Thread(target=self._play_loop, name="play", daemon=True).start()
        threading.Thread(target=self._idle_loop, name="idle", daemon=True).start()

    # ---- model -----------------------------------------------------------
    def _model(self):
        if self.kokoro is None:
            import onnxruntime as ort
            from kokoro_onnx import Kokoro
            t = time.monotonic()
            opts = ort.SessionOptions()
            # On a hybrid Intel Core Ultra, 6 threads were ~30% faster than
            # onnxruntime's default and more gave nothing (E-cores).
            default_threads = min(6, os.cpu_count() or 4)
            opts.intra_op_num_threads = int(os.environ.get("SAYIT_THREADS", default_threads))
            session = ort.InferenceSession(str(MODEL), opts, providers=["CPUExecutionProvider"])
            self.kokoro = Kokoro.from_session(session, str(VOICES))
            self.voices = sorted(self.kokoro.get_voices())
            log(f"model loaded in {time.monotonic() - t:.1f}s")
        return self.kokoro

    def voice_list(self):
        if not self.voices:
            with np.load(VOICES) as z:
                self.voices = sorted(z.files)
        return self.voices

    def _idle_loop(self):
        while True:
            time.sleep(30)
            limit = float(self.cfg.get("idle_unload_minutes") or 0) * 60
            with self.cond:
                busy = self.current or self.queue
                idle = time.monotonic() - self.last_activity
                if self.kokoro is not None and limit and not busy and idle > limit:
                    self.kokoro = None
                    unload = True
                else:
                    unload = False
            if unload:
                gc.collect()
                try:
                    ctypes.CDLL("libc.so.6").malloc_trim(0)
                except OSError:
                    pass
                log("model unloaded after idle")

    # ---- queue -----------------------------------------------------------
    def say(self, text, voice=None, speed=None, lang=None, replace=False, source="cli"):
        text = text.strip()
        if not text:
            raise ValueError("nothing to say")
        if voice is None:
            voice = self.cfg["voice"]
            if self.cfg.get("auto_language") and not lang and looks_spanish(text):
                voice = self.cfg.get("spanish_voice") or voice
        if voice not in self.voice_list():
            raise ValueError(f"unknown voice {voice!r} (see: sayit voices)")
        lang = lang or LANG_BY_PREFIX.get(voice[0], "en-us")
        speed = float(speed or self.cfg["speed"])
        job = Job(text, voice, max(0.5, min(2.0, speed)), lang, source)
        if not job.chunks:
            raise ValueError("nothing speakable in text")
        with self.cond:
            if replace:
                self._cancel_all()
                self.paused = False
            self.queue.append(job)
            self.last_activity = time.monotonic()
            self._publish()
            self.cond.notify_all()
        self._remember(job)
        return job

    def _cancel_all(self):
        for j in list(self.queue) + ([self.current] if self.current else []):
            j.cancelled = True
        self.queue.clear()

    def _remember(self, job):
        try:
            with HISTORY.open("a") as f:
                f.write(json.dumps({"t": int(time.time()), "voice": job.voice,
                                    "source": job.source, "text": job.text}) + "\n")
            lines = HISTORY.read_text().splitlines()
            if len(lines) > HISTORY_KEEP * 2:
                HISTORY.write_text("\n".join(lines[-HISTORY_KEEP:]) + "\n")
        except OSError as exc:
            log("history write failed:", exc)

    # ---- synthesis -------------------------------------------------------
    def _next_to_synthesize(self):
        ahead = 0
        for job in ([self.current] if self.current else []) + list(self.queue):
            if job.cancelled:
                continue
            ahead += job.synthesized_samples() - job.pos
            if not job.synth_done:
                return job if ahead < MAX_AHEAD_SECONDS * SAMPLE_RATE else None
        return None

    def _synth_loop(self):
        while True:
            with self.cond:
                job = self._next_to_synthesize()
                while job is None:
                    self.cond.wait()
                    job = self._next_to_synthesize()
                idx = len(job.audio)
                epoch = job.epoch
            try:
                samples, sr = self._model().create(
                    job.chunks[idx], voice=job.voice, speed=job.speed, lang=job.lang)
                if sr != SAMPLE_RATE:
                    raise RuntimeError(f"unexpected sample rate {sr}")
                samples = np.asarray(samples, dtype=np.float32)
            except Exception as exc:
                log(f"job {job.id} chunk {idx} failed: {exc}")
                samples, job.error = np.zeros(0, np.float32), str(exc)
            with self.cond:
                if not job.cancelled and job.epoch == epoch and len(job.audio) == idx:
                    job.audio.append(samples)
                    n = -(-len(samples) // ENV_STEP)
                    padded = np.zeros(n * ENV_STEP, np.float32)
                    padded[:len(samples)] = np.abs(samples)
                    job.env.append(np.round(padded.reshape(n, ENV_STEP).max(axis=1), 3).tolist())
                    if len(job.audio) == len(job.chunks):
                        job.synth_done = True
                    if job is self.current:
                        self._publish()
                self.cond.notify_all()

    # ---- playback --------------------------------------------------------
    def _play_loop(self):
        stream = None
        silent_since = time.monotonic()
        while True:
            with self.cond:
                if self.current is None and self.queue:
                    self.current = self.queue.popleft()
                    log(f"job {self.current.id}: {self.current.summary()['text']!r}"
                        f" [{self.current.voice}]")
                    self._publish()
                job = self.current
                block = None
                if job is not None and self.seek_request is not None:
                    total = job.synthesized_samples()
                    job.pos = int(max(0, min(total, job.pos + self.seek_request * SAMPLE_RATE)))
                    self.seek_request = None
                    self._publish()
                if job is not None and not job.cancelled and not self.paused:
                    block = self._slice(job, job.pos, BLOCK)
                    if block is not None:
                        job.pos += len(block)
                finished = job is not None and (
                    job.cancelled or (job.synth_done and job.pos >= job.synthesized_samples()))
                if finished:
                    job.done.set()
                    self.current = None
                    self.flowing = False
                    self.last_activity = time.monotonic()
                    self._publish()
                    self.cond.notify_all()
                    continue
                if (block is not None) != self.flowing:
                    self.flowing = block is not None
                    self._publish()
                if block is None:
                    # nothing ready (idle, paused, or synthesis behind playback)
                    idle = job is None and not self.queue
                    if idle and stream is not None and time.monotonic() - silent_since > CLOSE_DEVICE_AFTER:
                        stream.close()
                        stream = None
                    self.cond.wait(timeout=0.5 if stream is not None else None)
                    continue
                self.cond.notify_all()   # synth thread may be waiting on buffer room
            if stream is None:
                stream = self._open_stream()
                if stream is None:
                    time.sleep(1)
                    continue
            try:
                gain = float(self.cfg.get("volume", 1.0))
                if gain != 1.0:
                    block = np.clip(block * gain, -1.0, 1.0)
                stream.write(block.reshape(-1, 1).astype(np.float32, copy=False))
            except Exception as exc:
                log("audio write failed, reopening device:", exc)
                try:
                    stream.close()
                except Exception:
                    pass
                stream = None
            silent_since = time.monotonic()

    @staticmethod
    def _slice(job, pos, n):
        """Up to n samples starting at pos across the job's chunk arrays."""
        out, offset = [], 0
        for a in job.audio:
            if pos < offset + len(a):
                start = max(0, pos - offset)
                take = a[start:start + n - sum(len(x) for x in out)]
                out.append(take)
                if sum(len(x) for x in out) >= n:
                    break
            offset += len(a)
        if not out:
            return None
        return np.concatenate(out)

    @staticmethod
    def _open_stream():
        try:
            s = sd.OutputStream(samplerate=SAMPLE_RATE, channels=1, dtype="float32",
                                blocksize=BLOCK, latency="low")
            s.start()
            return s
        except Exception as exc:
            log("cannot open audio device:", exc)
            return None

    # ---- control ---------------------------------------------------------
    def control(self, cmd, arg=None):
        log(f"control {cmd}" + (f" {arg}" if arg is not None else ""))
        with self.cond:
            self.last_activity = time.monotonic()
            if cmd == "pause":
                self.paused = True
            elif cmd == "resume":
                self.paused = False
            elif cmd == "toggle":
                self.paused = not self.paused if (self.current or self.queue) else False
            elif cmd == "skip":
                if self.current:
                    self.current.cancelled = True
                self.paused = False
            elif cmd == "stop":
                self._cancel_all()
                self.paused = False
            elif cmd == "clear":
                for j in self.queue:
                    j.cancelled = True
                self.queue.clear()
            elif cmd == "seek":
                self.seek_request = float(arg)
            elif cmd == "seekto" and self.current:
                self.seek_request = float(arg) - self.current.pos / SAMPLE_RATE
            self._publish()
            self.cond.notify_all()
        return self.status()

    def _state_name(self):
        if self.current:
            return "paused" if self.paused else "speaking"
        return "paused" if self.paused and self.queue else "idle"

    def _publish(self):
        """Write a snapshot for the bar widget. Call with self.cond held.

        Position is published only on changes; readers extrapolate it from `t`
        while `flowing` is true."""
        job = self.current
        snap = {"state": self._state_name(), "flowing": self.flowing, "t": time.time(),
                "queued": len(self.queue), "voice": self.cfg["voice"],
                "speed": self.cfg["speed"]}
        snap["volume"] = self.cfg.get("volume", 1.0)
        if job:
            snap.update(id=job.id, text=job.text[:600], jobVoice=job.voice,
                        source=job.source, jobSpeed=job.speed,
                        position=job.pos / SAMPLE_RATE,
                        total=job.synthesized_samples() / SAMPLE_RATE,
                        estimate=round(job.estimated_seconds(), 2),
                        complete=job.synth_done,
                        chunks=job.timeline(),
                        env=[v for chunk in job.env for v in chunk])
        try:
            STATUS_FILE.write_text(json.dumps(snap))
        except OSError as exc:
            log("state write failed:", exc)

    def status(self):
        with self.cond:
            return {
                "state": self._state_name(),
                "current": self.current.summary(played=True) if self.current else None,
                "queue": [j.summary() for j in self.queue],
                "voice": self.cfg["voice"],
                "speed": self.cfg["speed"],
                "volume": self.cfg.get("volume", 1.0),
                "auto_language": self.cfg.get("auto_language"),
                "spanish_voice": self.cfg.get("spanish_voice"),
                "model_loaded": self.kokoro is not None,
                "idle_unload_minutes": self.cfg.get("idle_unload_minutes"),
            }

    def set_config(self, key, value):
        if key == "voice" or key == "spanish_voice":
            if value not in self.voice_list():
                raise ValueError(f"unknown voice {value!r}")
        elif key == "speed":
            value = max(0.5, min(2.0, float(value)))
        elif key == "volume":
            value = max(0.0, min(1.5, float(value)))
        elif key == "idle_unload_minutes":
            value = max(0, float(value))
        elif key == "auto_language":
            value = str(value).lower() in ("1", "true", "on", "yes")
        else:
            raise ValueError(f"unknown setting {key!r}")
        with self.cond:
            self.cfg[key] = value
            save_config(self.cfg)
            if key == "speed":
                # Apply now: redo everything after the sentence that is playing.
                if self.current and not self.current.cancelled:
                    job = self.current
                    job.resynthesize_from(job.chunk_at(job.pos) + 1, value)
                for job in self.queue:
                    job.resynthesize_from(0, value)
                self.cond.notify_all()
            self._publish()
        return self.status()


def handle(engine, conn):
    with conn:
        conn.settimeout(10)
        data = b""
        while not data.endswith(b"\n"):
            piece = conn.recv(65536)
            if not piece:
                break
            data += piece
        try:
            req = json.loads(data or b"{}")
            cmd = req.get("cmd")
            if cmd == "say":
                job = engine.say(req.get("text", ""), req.get("voice"), req.get("speed"),
                                 req.get("lang"), bool(req.get("replace")),
                                 req.get("source") or "cli")
                resp = {"ok": True, "id": job.id, "voice": job.voice}
                if req.get("wait"):
                    conn.settimeout(None)
                    conn.sendall((json.dumps({"ok": True, "queued": job.id}) + "\n").encode())
                    job.done.wait()
                    resp["cancelled"] = job.cancelled
                    if job.error:
                        resp = {"ok": False, "error": job.error, "id": job.id}
            elif cmd in ("pause", "resume", "toggle", "skip", "stop", "clear", "seek", "seekto"):
                resp = {"ok": True, **engine.control(cmd, req.get("arg"))}
            elif cmd == "status":
                resp = {"ok": True, **engine.status()}
            elif cmd == "voices":
                resp = {"ok": True, "voices": engine.voice_list()}
            elif cmd == "set":
                resp = {"ok": True, **engine.set_config(req["key"], req["value"])}
            elif cmd == "ping":
                resp = {"ok": True}
            else:
                resp = {"ok": False, "error": f"unknown command {cmd!r}"}
        except Exception as exc:
            resp = {"ok": False, "error": str(exc)}
        try:
            conn.sendall((json.dumps(resp) + "\n").encode())
        except OSError:
            pass


def main():
    engine = Engine()
    if SOCKET.exists():
        SOCKET.unlink()
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(str(SOCKET))
    os.chmod(SOCKET, 0o600)
    srv.listen(16)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    log(f"listening on {SOCKET}")
    try:
        while True:
            conn, _ = srv.accept()
            threading.Thread(target=handle, args=(engine, conn), daemon=True).start()
    finally:
        for path in (SOCKET, STATUS_FILE):
            try:
                path.unlink()
            except FileNotFoundError:
                pass


if __name__ == "__main__":
    main()
