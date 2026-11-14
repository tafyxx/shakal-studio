@echo off & cd /d "%~dp0" & chcp 65001 >nul & title Shakal Studio v9.0 Motion & echo Loading Shakal Studio v9.0 Motion... & python -m pip install pillow opencv-python numpy sounddevice scipy imageio-ffmpeg --quiet & python -x "%~f0" & exit /b
# -*- coding: utf-8 -*-

import os
import io
import math
import time
import json
import random
import struct
import threading
import subprocess
import ctypes
import ctypes.wintypes
import tkinter as tk
from tkinter import filedialog
from datetime import datetime
from PIL import Image, ImageGrab, ImageDraw, ImageOps, ImageChops, ImageEnhance, ImageFont, ImageTk

try:
    import cv2
    import numpy as np
    HAS_CV2 = True
except Exception:
    HAS_CV2 = False

try:
    import sounddevice as sd
    import scipy.io.wavfile as wavfile
    HAS_SOUNDDEVICE = True
except Exception:
    HAS_SOUNDDEVICE = False

try:
    import imageio_ffmpeg
    FFMPEG_EXE = imageio_ffmpeg.get_ffmpeg_exe()
except Exception:
    FFMPEG_EXE = None

try:
    import winsound
    HAS_WINSOUND = True
except ImportError:
    HAS_WINSOUND = False

# DPI Awareness
try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
except Exception:
    try:
        ctypes.windll.user32.SetProcessDPIAware()
    except Exception:
        pass

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32

NATIVE_W = user32.GetSystemMetrics(0) or 1920
NATIVE_H = user32.GetSystemMetrics(1) or 1080

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PRESETS_FILE = os.path.join(BASE_DIR, "presets.json")
DIRS = {
    "ads": os.path.join(BASE_DIR, "ads"),
    "screamers": os.path.join(BASE_DIR, "screamers"),
    "cam_audio": os.path.join(BASE_DIR, "sounds_camera"),
    "scr_audio": os.path.join(BASE_DIR, "sounds_screamer"),
    "screenshots": os.path.join(BASE_DIR, "screenshots"),
    "videos": os.path.join(BASE_DIR, "videos")
}
for d in DIRS.values():
    os.makedirs(d, exist_ok=True)

def copy_image_to_clipboard(img):
    try:
        output = io.BytesIO()
        img.convert("RGB").save(output, "BMP")
        bmp_data = output.getvalue()
        output.close()
        dib_data = bmp_data[14:]

        kernel32.GlobalAlloc.restype = ctypes.c_void_p
        kernel32.GlobalAlloc.argtypes = [ctypes.c_uint, ctypes.c_size_t]
        kernel32.GlobalLock.restype = ctypes.c_void_p
        kernel32.GlobalLock.argtypes = [ctypes.c_void_p]
        kernel32.GlobalUnlock.restype = ctypes.c_void_p
        kernel32.GlobalUnlock.argtypes = [ctypes.c_void_p]
        user32.OpenClipboard.argtypes = [ctypes.c_void_p]
        user32.SetClipboardData.argtypes = [ctypes.c_uint, ctypes.c_void_p]
        user32.CloseClipboard.argtypes = []
        user32.EmptyClipboard.argtypes = []

        if user32.OpenClipboard(None):
            try:
                user32.EmptyClipboard()
                h_mem = kernel32.GlobalAlloc(0x0042, len(dib_data))
                if h_mem:
                    p_mem = kernel32.GlobalLock(h_mem)
                    if p_mem:
                        ctypes.memmove(p_mem, dib_data, len(dib_data))
                        kernel32.GlobalUnlock(h_mem)
                        user32.SetClipboardData(8, h_mem)
            finally:
                user32.CloseClipboard()
    except Exception:
        pass

def get_real_user_path():
    candidates = [
        os.environ.get("USERPROFILE"),
        os.environ.get("APPDATA"),
        os.environ.get("LOCALAPPDATA"),
        os.path.join(os.environ.get("WINDIR", "C:\\Windows"), "System32"),
        os.path.join(os.environ.get("USERPROFILE", "C:\\"), "Downloads"),
        os.environ.get("PROGRAMFILES")
    ]
    pool = []
    for c in candidates:
        if c and os.path.exists(c):
            pool.append(c)
            try:
                sub = [os.path.join(c, d) for d in os.listdir(c) if os.path.isdir(os.path.join(c, d))]
                pool.extend(sub[:6])
            except Exception:
                pass
    chosen_dir = random.choice(pool) if pool else "C:\\Windows\\System32"
    fake_files = ["service_host.exe", "kernel_patcher.sys", "injector_x64.dll", "client_update.exe", "token_grabber.dat", "driver_x86.sys"]
    return os.path.join(chosen_dir, random.choice(fake_files))

def get_sys_font(hints, size):
    wdir = os.environ.get("WINDIR", "C:\\Windows")
    fdir = os.path.join(wdir, "Fonts")
    for h in hints:
        path = os.path.join(fdir, h)
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except Exception:
                pass
    return ImageFont.load_default()

def get_system_monitors():
    monitors = []
    def _cb(hmon, hdc, rect_p, lparam):
        r = rect_p.contents
        monitors.append({
            "handle": hmon,
            "x": r.left,
            "y": r.top,
            "w": r.right - r.left,
            "h": r.bottom - r.top
        })
        return True
    try:
        CB = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.wintypes.RECT), ctypes.c_long)
        user32.EnumDisplayMonitors(0, 0, CB(_cb), 0)
    except Exception:
        pass
    return monitors or [{"handle": 0, "x": 0, "y": 0, "w": NATIVE_W, "h": NATIVE_H}]

# =========================================================================
#                         SHAKAL AUDIO ENGINE
# =========================================================================
class ShakalAudioEngine:
    SAMPLE_RATE = 44100
    _cached_screamers = []
    _cached_camera = []

    @classmethod
    def init_audio(cls):
        threading.Thread(target=cls._load_audio_cache, daemon=True).start()

    @classmethod
    def _decode_file_to_pcm(cls, path):
        if not os.path.exists(path) or not FFMPEG_EXE:
            return None
        try:
            cmd = [
                FFMPEG_EXE, "-v", "error", "-i", path,
                "-f", "s16le", "-ar", str(cls.SAMPLE_RATE), "-ac", "1", "-"
            ]
            res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            if res.stdout:
                return np.frombuffer(res.stdout, dtype=np.int16).astype(np.float32) / 32768.0
        except Exception:
            pass
        return None

    @classmethod
    def _load_audio_cache(cls):
        valid = {".mp3", ".wav", ".ogg", ".m4a"}
        cls._cached_screamers = []
        if os.path.exists(DIRS["scr_audio"]):
            for f in os.listdir(DIRS["scr_audio"]):
                if os.path.splitext(f)[1].lower() in valid:
                    pcm = cls._decode_file_to_pcm(os.path.join(DIRS["scr_audio"], f))
                    if pcm is not None:
                        cls._cached_screamers.append(pcm)

        cls._cached_camera = []
        if os.path.exists(DIRS["cam_audio"]):
            for f in os.listdir(DIRS["cam_audio"]):
                if os.path.splitext(f)[1].lower() in valid:
                    pcm = cls._decode_file_to_pcm(os.path.join(DIRS["cam_audio"], f))
                    if pcm is not None:
                        cls._cached_camera.append(pcm)

    @classmethod
    def play(cls, mode):
        threading.Thread(target=cls._play_worker, args=(mode,), daemon=True).start()

    @classmethod
    def _play_worker(cls, mode):
        try:
            if mode == "camera":
                if cls._cached_camera and HAS_SOUNDDEVICE:
                    raw = random.choice(cls._cached_camera)
                    sd.play(raw, cls.SAMPLE_RATE)
                    return
                cls.synth_beep([(1800, 0.03), (900, 0.05)])
            elif mode == "screamer":
                if cls._cached_screamers and HAS_SOUNDDEVICE:
                    raw = random.choice(cls._cached_screamers)
                    sd.play(np.clip(raw * 1.5, -0.99, 0.99), cls.SAMPLE_RATE)
                    return
                cls.synth_beep([(2400, 0.1), (1800, 0.1), (3000, 0.15)])
            elif mode == "screamer_ear_rape":
                if cls._cached_screamers and HAS_SOUNDDEVICE:
                    raw = random.choice(cls._cached_screamers).copy()
                    t = np.linspace(0, len(raw) / cls.SAMPLE_RATE, len(raw))
                    sub = 0.45 * np.sin(2 * np.pi * 48 * t)
                    extreme = np.clip(np.tanh((raw + sub) * 6.5) * 2.5, -0.99, 0.99)
                    sd.play(extreme.astype(np.float32), cls.SAMPLE_RATE)
                    return
                cls.synth_beep([(3200, 0.15), (2800, 0.2), (3600, 0.35)])
            elif mode == "bass_drop":
                if HAS_SOUNDDEVICE:
                    dur = 0.9
                    t = np.linspace(0, dur, int(cls.SAMPLE_RATE * dur))
                    sweep = np.sin(2 * np.pi * (110 - 70 * (t / dur)) * t)
                    bass = np.clip(np.tanh(sweep * 8.0) * 2.0, -0.99, 0.99).astype(np.float32)
                    sd.play(bass, cls.SAMPLE_RATE)
                    return
                cls.synth_beep([(150, 0.4), (80, 0.5)])
            elif mode == "usb_disconnect":
                if HAS_WINSOUND:
                    try:
                        winsound.PlaySound("DeviceDisconnect", winsound.SND_ALIAS | winsound.SND_ASYNC)
                        return
                    except Exception:
                        pass
                cls.synth_beep([(880, 0.08), (660, 0.12)])
            elif mode == "usb_connect":
                if HAS_WINSOUND:
                    try:
                        winsound.PlaySound("DeviceConnect", winsound.SND_ALIAS | winsound.SND_ASYNC)
                        return
                    except Exception:
                        pass
                cls.synth_beep([(660, 0.08), (880, 0.12)])
            elif mode == "win_error":
                if HAS_WINSOUND:
                    try:
                        winsound.PlaySound("SystemHand", winsound.SND_ALIAS | winsound.SND_ASYNC)
                        return
                    except Exception:
                        pass
                cls.synth_beep([(350, 0.18), (180, 0.25)])
            elif mode == "icq":
                cls.synth_beep([(750, 0.08), (1200, 0.12)])
            elif mode == "dpc_freeze":
                if HAS_SOUNDDEVICE:
                    dur = 0.55
                    t = np.linspace(0, dur, int(cls.SAMPLE_RATE * dur))
                    buzz = 0.7 * np.sign(np.sin(2 * np.pi * 120 * t)) + 0.3 * np.sin(2 * np.pi * 360 * t)
                    buzz = np.clip(buzz * 1.6, -0.99, 0.99).astype(np.float32)
                    sd.play(buzz, cls.SAMPLE_RATE)
                    return
                cls.synth_beep([(120, 0.5)])
        except Exception:
            pass

    @classmethod
    def synth_beep(cls, notes):
        if not HAS_WINSOUND:
            return
        rate = 22050
        raw = bytearray()
        for f, d in notes:
            cnt = int(rate * d)
            for i in range(cnt):
                v = int(127.0 * math.sin(2.0 * math.pi * f * (i / rate)))
                raw.append(v + 128)
        wav = bytearray(b"RIFF")
        wav.extend(struct.pack("<I", 36 + len(raw)))
        wav.extend(b"WAVEfmt ")
        wav.extend(struct.pack("<I", 16))
        wav.extend(struct.pack("<H", 1))
        wav.extend(struct.pack("<H", 1))
        wav.extend(struct.pack("<I", rate))
        wav.extend(struct.pack("<I", rate))
        wav.extend(struct.pack("<H", 1))
        wav.extend(struct.pack("<H", 8))
        wav.extend(b"data")
        wav.extend(struct.pack("<I", len(raw)))
        wav.extend(raw)
        try:
            winsound.PlaySound(bytes(wav), winsound.SND_MEMORY | winsound.SND_ASYNC)
        except Exception:
            pass

    @classmethod
    def process_shakal_audio(cls, audio_data, settings, screamer_triggers=[]):
        if audio_data is None or len(audio_data) == 0:
            return None
        data = audio_data.copy().astype(np.float32)

        if len(data.shape) > 1:
            data = data.mean(axis=1)

        N = len(data)
        sr = cls.SAMPLE_RATE

        scr_gain = settings.get("screamer_vol", 150) / 100.0
        if scr_gain > 0 and cls._cached_screamers and screamer_triggers:
            for trig_sec in screamer_triggers:
                start_idx = int(trig_sec * sr)
                if start_idx < N:
                    scr_clip = random.choice(cls._cached_screamers)
                    scr_clip = np.tanh(scr_clip * (3.0 * scr_gain)) * 1.8
                    end_idx = min(N, start_idx + len(scr_clip))
                    clip_len = end_idx - start_idx
                    data[start_idx:end_idx] += scr_clip[:clip_len]

        bass_amt = settings.get("bass_boost", 0) / 100.0
        if bass_amt > 0:
            t = np.linspace(0, N / sr, N)
            sub_drone = np.sin(2 * np.pi * 55 * t) * (bass_amt * 0.35)
            gain = 1.0 + (bass_amt * 18.0)
            data = np.tanh((data + sub_drone) * gain)

        clip_amt = settings.get("hard_clip", 0) / 100.0
        if clip_amt > 0:
            threshold = max(0.08, 1.0 - (clip_amt * 0.9))
            data = np.clip(data * (1.0 + clip_amt * 3.5), -threshold, threshold) / threshold

        drop_rate = settings.get("dropouts", 0) / 100.0
        if drop_rate > 0:
            chunk_size = int(sr * 0.3)
            num_chunks = max(1, N // chunk_size)
            for ch in range(num_chunks):
                if random.random() < drop_rate:
                    s_idx = ch * chunk_size
                    mode = random.choice(["mute", "stutter"])
                    if mode == "mute":
                        dur = random.randint(int(sr * 0.05), int(sr * 0.25))
                        data[s_idx:min(N, s_idx + dur)] = 0.0
                    elif mode == "stutter":
                        loop_len = random.randint(int(sr * 0.01), int(sr * 0.04))
                        repeats = random.randint(3, 8)
                        for r in range(repeats):
                            pos = s_idx + r * loop_len
                            if pos + loop_len < N and s_idx + loop_len < N:
                                data[pos:pos + loop_len] = data[s_idx:s_idx + loop_len]

        bit_amt = settings.get("bitcrush", 0) / 100.0
        if bit_amt > 0:
            levels = max(4, int(256 * (1.0 - bit_amt * 0.94)))
            data = np.round(data * (levels / 2.0)) / (levels / 2.0)
            step = max(1, int(1 + bit_amt * 12))
            if step > 1:
                for i in range(0, N, step):
                    data[i:min(N, i + step)] = data[i]

        hum_amt = settings.get("mic_hum", 0) / 100.0
        if hum_amt > 0:
            t = np.linspace(0, N / sr, N)
            hum = 0.12 * np.sin(2 * np.pi * 50 * t) + 0.06 * np.sin(2 * np.pi * 150 * t)
            white = np.random.normal(0, 0.08, N)
            data = data + (hum + white) * hum_amt

        return np.clip(data, -0.99, 0.99)


# =========================================================================
#                         COMPACT MOTION UI
# =========================================================================
THEME = {
    "bg_root": "#0a0c10",
    "bg_card": "#11141c",
    "bg_card_inner": "#161a24",
    "border_card": "#1d2330",
    "border_highlight": "#2a3447",
    "accent_blue": "#38bdf8",
    "accent_rose": "#f43f5e",
    "accent_amber": "#f59e0b",
    "text_main": "#f8fafc",
    "text_muted": "#64748b",
    "text_dim": "#94a3b8",
    "btn_bg": "#151922",
    "btn_hover": "#1e2433",
    "trough": "#161b26"
}

class MotionDropdown(tk.Frame):
    def __init__(self, parent, variable, options, display_names=None, callback=None, hover_cb=None, hover_title="", hover_desc=""):
        super().__init__(parent, bg=THEME["btn_bg"], highlightbackground=THEME["border_card"], highlightthickness=1)
        self.variable = variable
        self.options = options
        self.display_names = display_names or {o: o for o in options}
        self.callback = callback

        self.lbl = tk.Label(self, text=self.get_text(), font=("Segoe UI", 8), bg=THEME["btn_bg"], fg=THEME["accent_blue"], padx=6, pady=2, cursor="hand2", anchor="w")
        self.lbl.pack(side="left", fill="x", expand=True)

        self.arr = tk.Label(self, text="▾", font=("Segoe UI", 8), bg=THEME["btn_bg"], fg=THEME["text_muted"], padx=5, cursor="hand2")
        self.arr.pack(side="right")

        self.menu = tk.Menu(self, tearoff=0, bg=THEME["bg_card"], fg=THEME["text_main"], activebackground=THEME["border_highlight"], activeforeground=THEME["accent_blue"], bd=1, relief="solid", font=("Segoe UI", 8))
        self.refresh_menu()

        for w in (self, self.lbl, self.arr):
            w.bind("<Button-1>", self.open_menu)
            w.bind("<Enter>", lambda e: self.configure(highlightbackground=THEME["border_highlight"]))
            w.bind("<Leave>", lambda e: self.configure(highlightbackground=THEME["border_card"]))

        if hover_cb and hover_desc:
            for w in (self, self.lbl, self.arr):
                w.bind("<Enter>", lambda e: hover_cb(hover_title or self.get_text(), hover_desc), add="+")
                w.bind("<Leave>", lambda e: hover_cb("", ""), add="+")

    def refresh_menu(self):
        self.menu.delete(0, "end")
        for opt in self.options:
            disp = self.display_names.get(opt, opt)
            self.menu.add_command(label=disp, command=lambda v=opt: self.select(v))

    def get_text(self):
        v = self.variable.get()
        return self.display_names.get(v, v)

    def select(self, val):
        self.variable.set(val)
        self.lbl.config(text=self.get_text())
        if self.callback:
            self.callback(val)

    def open_menu(self, event=None):
        try:
            x = self.winfo_rootx()
            y = self.winfo_rooty() + self.winfo_height()
            self.menu.tk_popup(x, y)
        except Exception:
            pass

class MotionSlider:
    def __init__(self, parent, label_text, var, from_, to_, info_text="", is_float=False, res=1, hover_cb=None):
        self.var = var
        self.is_float = is_float
        self.res = res
        self.label_text = label_text
        self.info_text = info_text

        self.frame = tk.Frame(parent, bg=THEME["bg_card"])
        self.frame.pack(fill="x", padx=4, pady=1)

        header = tk.Frame(self.frame, bg=THEME["bg_card"])
        header.pack(fill="x")

        self.lbl = tk.Label(header, text=label_text, font=("Segoe UI", 8), bg=THEME["bg_card"], fg=THEME["text_dim"])
        self.lbl.pack(side="left")

        self.entry = tk.Entry(header, width=5, font=("Segoe UI", 8, "bold"), bg=THEME["bg_card_inner"], fg=THEME["accent_blue"], bd=0, justify="right", highlightbackground=THEME["border_card"], highlightthickness=1)
        self.entry.pack(side="right")
        self.entry.bind("<Return>", self.commit)
        self.entry.bind("<FocusOut>", self.commit)

        self.scale = tk.Scale(
            self.frame, from_=from_, to=to_, orient="horizontal", variable=var,
            resolution=res if is_float else 1, showvalue=False,
            bg=THEME["bg_card"], fg=THEME["accent_blue"], highlightthickness=0,
            troughcolor=THEME["trough"], activebackground=THEME["accent_blue"],
            command=lambda v: self.update_entry(), sliderlength=12, width=7
        )
        self.scale.pack(fill="x", pady=(0, 1))
        self.update_entry()

        if hover_cb and info_text:
            for w in (self.frame, header, self.lbl, self.scale):
                w.bind("<Enter>", lambda e: hover_cb(label_text, info_text))
                w.bind("<Leave>", lambda e: hover_cb("", ""))

    def update_entry(self):
        self.entry.delete(0, tk.END)
        val = self.var.get()
        txt = f"{val:.1f}" if self.is_float else str(int(val))
        self.entry.insert(0, txt)

    def commit(self, event=None):
        try:
            val = float(self.entry.get()) if self.is_float else int(self.entry.get())
            mn, mx = self.scale.cget("from"), self.scale.cget("to")
            val = max(mn, min(mx, val))
            self.var.set(val)
        except Exception:
            pass
        self.update_entry()

class MotionCheck:
    def __init__(self, parent, text, var, info_text="", is_extreme=False, hover_cb=None):
        self.var = var
        self.is_extreme = is_extreme
        self.text = text
        self.info_text = info_text

        self.frame = tk.Frame(parent, bg=THEME["bg_card"])
        self.frame.pack(fill="x", padx=4, pady=1)

        fg_col = THEME["accent_rose"] if is_extreme else THEME["accent_blue"]
        self.box = tk.Label(self.frame, text="✓" if var.get() else " ", font=("Segoe UI", 7, "bold"), bg=THEME["bg_card_inner"], fg=fg_col, width=2, height=1, highlightbackground=THEME["border_card"], highlightthickness=1, cursor="hand2")
        self.box.pack(side="left", padx=(0, 6))

        title_col = THEME["accent_rose"] if is_extreme else THEME["text_main"]
        self.lbl = tk.Label(self.frame, text=text, font=("Segoe UI", 8, "bold" if is_extreme else "normal"), bg=THEME["bg_card"], fg=title_col, cursor="hand2")
        self.lbl.pack(side="left", fill="x", expand=True, anchor="w")

        for w in (self.box, self.lbl):
            w.bind("<Button-1>", self.toggle)
            w.bind("<Enter>", lambda e: self.box.configure(highlightbackground=THEME["border_highlight"]))
            w.bind("<Leave>", lambda e: self.box.configure(highlightbackground=THEME["border_card"]))

        if hover_cb and info_text:
            for w in (self.frame, self.box, self.lbl):
                w.bind("<Enter>", lambda e: hover_cb(text, info_text), add="+")
                w.bind("<Leave>", lambda e: hover_cb("", ""), add="+")

    def toggle(self, event=None):
        self.var.set(not self.var.get())
        self.sync()

    def sync(self):
        self.box.config(text="✓" if self.var.get() else " ")

class SnippingOverlay:
    def __init__(self, parent, on_complete):
        self.on_complete = on_complete
        self.top = tk.Toplevel(parent)
        self.top.attributes("-fullscreen", True)
        self.top.attributes("-alpha", 0.3)
        self.top.configure(bg="#000000", cursor="cross")
        self.top.lift()
        self.top.attributes("-topmost", True)

        self.canvas = tk.Canvas(self.top, bg="#000000", highlightthickness=0)
        self.canvas.pack(fill="both", expand=True)

        self.start_x = None
        self.start_y = None
        self.rect = None

        self.canvas.bind("<ButtonPress-1>", self.on_press)
        self.canvas.bind("<B1-Motion>", self.on_drag)
        self.canvas.bind("<ButtonRelease-1>", self.on_release)
        self.top.bind("<Escape>", lambda e: self.top.destroy())

    def on_press(self, event):
        self.start_x = event.x
        self.start_y = event.y
        self.rect = self.canvas.create_rectangle(self.start_x, self.start_y, self.start_x, self.start_y, outline="#38bdf8", width=2, fill="#38bdf8")

    def on_drag(self, event):
        self.canvas.coords(self.rect, self.start_x, self.start_y, event.x, event.y)

    def on_release(self, event):
        x1, y1 = min(self.start_x, event.x), min(self.start_y, event.y)
        x2, y2 = max(self.start_x, event.x), max(self.start_y, event.y)
        self.top.destroy()
        if (x2 - x1) > 10 and (y2 - y1) > 10:
            self.on_complete((x1, y1, x2, y2))


# =========================================================================
#                         MAIN STUDIO APPLICATION
# =========================================================================
class ShakalStudioApp:
    def __init__(self, root):
        self.root = root
        self.running = True
        self.current_mode = "screen"
        self.is_recording_video = False
        self.cached_ads = []
        self.cached_screamers = []
        self.save_dir = DIRS["screenshots"]
        self.video_save_dir = DIRS["videos"]
        self.custom_presets = self.load_custom_presets()

        # Discord prank live state & Cheat check features
        self.discord_stream_active = False
        self.discord_window = None
        self.live_active_ads = []
        self.live_active_av_timer = 0
        self.live_prev_burn_img = None
        self.prank_screamer_flash = False
        self.prank_bsod_active = False
        self.ghost_windows_var = tk.IntVar(value=0)
        self.gpu_art_var = tk.IntVar(value=0)
        self.v_ghost_var = tk.IntVar(value=0)
        self.v_gpu_art_var = tk.IntVar(value=0)
        self.tdr_flash_active = False
        self.tdr_toast_timer = 0
        self.mem_error_active = False
        self.is_overlay_active = False
        self.overlay_window = None
        self.overlay_canvas = None
        self._ghost_history = []

        # COMPACT GEOMETRY: 1020x640 fits cleanly on any display
        self.root.title("Shakal Studio v9.0 Motion")
        self.root.geometry("1020x640")
        self.root.resizable(False, False)
        self.root.configure(bg=THEME["bg_root"])

        ShakalAudioEngine.init_audio()

        # Hide studio window from Discord screen capture
        self.wda_active = tk.BooleanVar(value=True)
        self.apply_display_affinity()

        # ==================== TOP MOTION BAR ====================
        top_motion_bar = tk.Frame(root, bg=THEME["bg_card"], highlightbackground=THEME["border_card"], highlightthickness=1)
        top_motion_bar.pack(fill="x", padx=8, pady=(6, 3))

        # Brand Title
        brand_frame = tk.Frame(top_motion_bar, bg=THEME["bg_card"])
        brand_frame.pack(side="left", padx=(8, 12), pady=4)
        tk.Label(brand_frame, text="SHAKAL", font=("Segoe UI", 10, "bold"), bg=THEME["bg_card"], fg=THEME["text_main"]).pack(side="left")
        tk.Label(brand_frame, text="STUDIO", font=("Segoe UI", 10, "bold"), bg=THEME["bg_card"], fg=THEME["accent_blue"]).pack(side="left", padx=(2, 4))
        tk.Label(brand_frame, text="v9.0", font=("Consolas", 8, "bold"), bg=THEME["bg_card_inner"], fg=THEME["text_dim"], padx=5, pady=1).pack(side="left")

        # Mode Buttons
        self.btn_mode_screen = tk.Button(
            top_motion_bar, text="📸 СКРИНШОТЫ", font=("Segoe UI", 8, "bold"),
            bg=THEME["accent_blue"], fg="#000000", activebackground=THEME["border_highlight"], activeforeground=THEME["text_main"],
            bd=0, padx=14, pady=4, cursor="hand2", command=lambda: self.switch_mode("screen")
        )
        self.btn_mode_screen.pack(side="left", padx=2, pady=4)

        self.btn_mode_video = tk.Button(
            top_motion_bar, text="🎥 ВИДЕО", font=("Segoe UI", 8, "bold"),
            bg=THEME["btn_bg"], fg=THEME["text_dim"], activebackground=THEME["border_highlight"], activeforeground=THEME["text_main"],
            bd=0, padx=14, pady=4, cursor="hand2", command=lambda: self.switch_mode("video")
        )
        self.btn_mode_video.pack(side="left", padx=2, pady=4)

        self.btn_mode_discord = tk.Button(
            top_motion_bar, text="🟣 ДИСКОРД ПРАНК", font=("Segoe UI", 8, "bold"),
            bg=THEME["btn_bg"], fg=THEME["text_dim"], activebackground=THEME["border_highlight"], activeforeground=THEME["text_main"],
            bd=0, padx=14, pady=4, cursor="hand2", command=lambda: self.switch_mode("discord")
        )
        self.btn_mode_discord.pack(side="left", padx=2, pady=4)

        # Quick Utility Tools on Top Right
        tools_frame = tk.Frame(top_motion_bar, bg=THEME["bg_card"])
        tools_frame.pack(side="right", padx=6, pady=4)

        self.chk_wda = MotionCheck(tools_frame, "Скрыть студию от стрима", self.wda_active, "Исключает окно программы из захвата экрана Windows API.", hover_cb=self.show_hover_description)
        self.chk_wda.frame.pack(side="left", padx=(0, 6))
        self.wda_active.trace_add("write", lambda *args: self.apply_display_affinity())

        btn_chaos = tk.Button(tools_frame, text="🎲 Хаос", font=("Segoe UI", 8, "bold"), bg=THEME["btn_bg"], fg=THEME["accent_amber"], bd=0, padx=7, pady=2, cursor="hand2", command=self.randomize_everything)
        btn_chaos.pack(side="left", padx=2)

        btn_test_snd = tk.Button(tools_frame, text="🔊 Тест Звука", font=("Segoe UI", 8, "bold"), bg=THEME["btn_bg"], fg=THEME["accent_rose"], bd=0, padx=7, pady=2, cursor="hand2", command=self.test_extreme_sound)
        btn_test_snd.pack(side="left", padx=2)

        # ==================== CONTAINER FRAMES ====================
        self.screen_mode_frame = tk.Frame(root, bg=THEME["bg_root"])
        self.video_mode_frame = tk.Frame(root, bg=THEME["bg_root"])
        self.discord_mode_frame = tk.Frame(root, bg=THEME["bg_root"])

        self.build_screen_mode_ui(self.screen_mode_frame)
        self.build_video_mode_ui(self.video_mode_frame)
        self.build_discord_mode_ui(self.discord_mode_frame)

        self.screen_mode_frame.pack(fill="both", expand=True)

        # ==================== GLOBAL HOVER DESCRIPTION BAR ====================
        desc_bar = tk.Frame(root, bg=THEME["bg_card"], highlightbackground=THEME["border_card"], highlightthickness=1)
        desc_bar.pack(fill="x", padx=8, pady=(0, 4), side="bottom")

        self.lbl_hover_desc = tk.Label(desc_bar, text="Наведите курсор на любую настройку для подробного описания эффекта", font=("Segoe UI", 8), bg=THEME["bg_card"], fg=THEME["text_dim"], anchor="w", padx=8, pady=3)
        self.lbl_hover_desc.pack(fill="x")

        self.reload_media()

        # Bind App Key Shortcuts
        self.root.bind("<F8>", lambda e: self.capture_fullscreen())
        self.root.bind("<F9>", lambda e: self.start_region_select())
        self.root.bind("<F10>", lambda e: self.toggle_video_recording())
        self.root.bind("<F11>", lambda e: self.toggle_overlay_screen1())
        self.root.bind("<F12>", lambda e: self.stop_all_prank_streams())

        # Start Direct Windows API Hotkey Poller
        self.hotkey_thread = threading.Thread(target=self._native_hotkey_listener, daemon=True)
        self.hotkey_thread.start()

        # Start Background Live Stream Loop
        self.live_stream_thread = threading.Thread(target=self._discord_live_worker, daemon=True)
        self.live_stream_thread.start()

        self.root.protocol("WM_DELETE_WINDOW", self.on_close)

    def show_hover_description(self, title, desc):
        if title and desc:
            self.lbl_hover_desc.config(text=f"📌 {title}: {desc}", fg=THEME["accent_blue"])
        else:
            self.lbl_hover_desc.config(text="Наведите курсор на любую настройку для подробного описания эффекта", fg=THEME["text_dim"])

    def apply_display_affinity(self):
        try:
            hwnd = ctypes.windll.user32.GetAncestor(self.root.winfo_id(), 2)
            if hwnd:
                val = 0x11 if self.wda_active.get() else 0x0
                ctypes.windll.user32.SetWindowDisplayAffinity(hwnd, val)
        except Exception:
            pass

    def switch_mode(self, mode):
        self.current_mode = mode
        self.screen_mode_frame.pack_forget()
        self.video_mode_frame.pack_forget()
        self.discord_mode_frame.pack_forget()

        self.btn_mode_screen.config(bg=THEME["btn_bg"], fg=THEME["text_dim"])
        self.btn_mode_video.config(bg=THEME["btn_bg"], fg=THEME["text_dim"])
        self.btn_mode_discord.config(bg=THEME["btn_bg"], fg=THEME["text_dim"])

        if mode == "screen":
            self.screen_mode_frame.pack(fill="both", expand=True)
            self.btn_mode_screen.config(bg=THEME["accent_blue"], fg="#000000")
        elif mode == "video":
            self.video_mode_frame.pack(fill="both", expand=True)
            self.btn_mode_video.config(bg=THEME["accent_rose"], fg="#ffffff")
        elif mode == "discord":
            self.discord_mode_frame.pack(fill="both", expand=True)
            self.btn_mode_discord.config(bg=THEME["accent_amber"], fg="#000000")

    # =========================================================================
    #                         1. SCREENSHOT MODE UI
    # =========================================================================
    def build_screen_mode_ui(self, parent):
        top_bar = tk.Frame(parent, bg=THEME["bg_root"])
        top_bar.pack(fill="x", padx=8, pady=(1, 2))

        tk.Label(top_bar, text="Пресет:", font=("Segoe UI", 8), bg=THEME["bg_root"], fg=THEME["text_dim"]).pack(side="left")

        ordered_priority = [
            "Сброс",
            "🛡️ Чит-Проверка: Сбой Windows и Видеокарты",
            "Проверка на читы",
            "МАМА"
        ]
        preset_list = []
        for k in ordered_priority:
            if k == "Сброс" or k in self.custom_presets:
                preset_list.append(k)
        for k in self.custom_presets.keys():
            if k not in preset_list:
                preset_list.append(k)
        self.preset_options = preset_list

        self.selected_preset_var = tk.StringVar(value="Сброс")
        self.menu_presets = MotionDropdown(top_bar, self.selected_preset_var, self.preset_options, callback=self.on_preset_picked, hover_cb=self.show_hover_description, hover_title="Пресеты", hover_desc="Выбор готовой комбинации искажений, ретро-стилей и экстрим-скримеров.")
        self.menu_presets.pack(side="left", padx=(3, 8))

        tk.Label(top_bar, text="Имя:", font=("Segoe UI", 8), bg=THEME["bg_root"], fg=THEME["text_dim"]).pack(side="left")
        self.entry_preset_name = tk.Entry(top_bar, width=12, font=("Segoe UI", 8), bg=THEME["bg_card_inner"], fg=THEME["accent_blue"], bd=0, highlightbackground=THEME["border_card"], highlightthickness=1)
        self.entry_preset_name.pack(side="left", padx=3)

        btn_save_pre = tk.Button(top_bar, text="Сохранить", font=("Segoe UI", 8, "bold"), bg=THEME["btn_bg"], fg=THEME["accent_blue"], activebackground=THEME["accent_blue"], activeforeground="#000", bd=0, padx=6, pady=1, cursor="hand2", command=self.save_current_as_preset)
        btn_save_pre.pack(side="left", padx=2)

        # Compact Master Resolution Slider right on the top bar
        res_f = tk.Frame(top_bar, bg=THEME["bg_root"])
        res_f.pack(side="right", padx=(8, 0))

        self.lbl_master_res = tk.Label(res_f, text="", font=("Segoe UI", 8, "bold"), bg=THEME["bg_root"], fg=THEME["accent_blue"])
        self.lbl_master_res.pack(side="left", padx=(0, 4))

        self.global_res_var = tk.IntVar(value=NATIVE_H)
        self.scale_master_res = tk.Scale(res_f, from_=72, to=NATIVE_H, orient="horizontal", variable=self.global_res_var, showvalue=False, bg=THEME["bg_root"], fg=THEME["accent_blue"], highlightthickness=0, troughcolor=THEME["trough"], activebackground=THEME["accent_blue"], command=self.update_master_res_label, sliderlength=12, width=8, length=120)
        self.scale_master_res.pack(side="left")
        self.update_master_res_label()

        # 3 Main Columns
        grid_f = tk.Frame(parent, bg=THEME["bg_root"])
        grid_f.pack(fill="both", expand=True, padx=8, pady=1)
        grid_f.columnconfigure(0, weight=1)
        grid_f.columnconfigure(1, weight=1)
        grid_f.columnconfigure(2, weight=1)

        # Col 1: Искажения и геометрия
        c1 = tk.Frame(grid_f, bg=THEME["bg_card"], highlightbackground=THEME["border_card"], highlightthickness=1)
        c1.grid(row=0, column=0, sticky="nsew", padx=(0, 2), pady=1)

        tk.Label(c1, text="● Искажения и геометрия", font=("Segoe UI", 8, "bold"), bg=THEME["bg_card"], fg=THEME["accent_blue"]).pack(anchor="w", padx=6, pady=(3, 1))

        self.q_var = tk.IntVar(value=70)
        self.ctrl_q = MotionSlider(c1, "JPEG сжатие", self.q_var, 1, 100, "Степень сжатия кадра в квадратные пиксельные блоки и шум компрессии.", hover_cb=self.show_hover_description)

        self.pix_var = tk.IntVar(value=1)
        self.ctrl_pix = MotionSlider(c1, "Пикселизация", self.pix_var, 1, 40, "Мозаичный эффект, укрупняющий пиксели изображения в огромные однотонные блоки.", hover_cb=self.show_hover_description)

        self.fry_var = tk.DoubleVar(value=1.1)
        self.ctrl_fry = MotionSlider(c1, "Deep-Fry выжигание", self.fry_var, 1.0, 6.0, "Экстремальное выжигание контраста, насыщенности и цветовой гаммы.", is_float=True, res=0.1, hover_cb=self.show_hover_description)

        self.sharp_var = tk.IntVar(value=1)
        self.ctrl_sharp = MotionSlider(c1, "Овершарп резкость", self.sharp_var, 1, 25, "Многопроходное задирание резкости, создающее белые ореолы вокруг контуров.", hover_cb=self.show_hover_description)

        self.rgb_var = tk.IntVar(value=3)
        self.ctrl_rgb = MotionSlider(c1, "Сдвиг каналов RGB", self.rgb_var, 0, 150, "Хроматическая аберрация с раздвоением красного и синего цветовых каналов.", hover_cb=self.show_hover_description)

        self.datamosh_var = tk.IntVar(value=0)
        self.ctrl_datamosh = MotionSlider(c1, "Датамошинг", self.datamosh_var, 0, 100, "Имитация сбоя видеокодека при потере опорных кадров, размазывающая куски кадра.", hover_cb=self.show_hover_description)

        self.swirl_var = tk.IntVar(value=0)
        self.ctrl_swirl = MotionSlider(c1, "Штопор", self.swirl_var, 0, 100, "Психоделическое закручивание центра изображения в спиральный вихрь.", hover_cb=self.show_hover_description)

        self.bitcrush_var = tk.IntVar(value=0)
        self.ctrl_bitcrush = MotionSlider(c1, "Биткраш палитры", self.bitcrush_var, 0, 100, "Срезает цветовую палитру до уровня ретро-консолей 2-4-8 бит.", hover_cb=self.show_hover_description)

        self.crt_var = tk.IntVar(value=0)
        self.ctrl_crt = MotionSlider(c1, "CRT Scanlines кинескопа", self.crt_var, 0, 100, "Горизонтальные строчные полосы кинескопа старого аналогового телевизора.", hover_cb=self.show_hover_description)

        self.jitter_var = tk.IntVar(value=0)
        self.ctrl_jitter = MotionSlider(c1, "Дрожание строк Jitter", self.jitter_var, 0, 100, "Хаотичный горизонтальный сдвиг четных и нечетных строк пикселей.", hover_cb=self.show_hover_description)

        self.vignette_var = tk.IntVar(value=0)
        self.ctrl_vignette = MotionSlider(c1, "Виньетка кинескопа", self.vignette_var, 0, 100, "Затемнение по краям кадра, имитирующее выпуклый пузатый кинескоп.", hover_cb=self.show_hover_description)

        self.solarize_var = tk.BooleanVar(value=False)
        self.chk_solarize = MotionCheck(c1, "Соляризация пленки", self.solarize_var, "Инвертирует пиксели выше пороговой яркости, создавая эффект засвеченной пленки.", hover_cb=self.show_hover_description)

        self.invert_var = tk.BooleanVar(value=False)
        self.chk_invert = MotionCheck(c1, "Инверсия цветов", self.invert_var, "Полный цветовой негатив изображения.", hover_cb=self.show_hover_description)

        # Col 2: Реклама, матрица и сбои
        c2 = tk.Frame(grid_f, bg=THEME["bg_card"], highlightbackground=THEME["border_card"], highlightthickness=1)
        c2.grid(row=0, column=1, sticky="nsew", padx=2, pady=1)

        tk.Label(c2, text="● Реклама, матрица и сбои", font=("Segoe UI", 8, "bold"), bg=THEME["bg_card"], fg=THEME["accent_amber"]).pack(anchor="w", padx=6, pady=(3, 1))

        self.art_var = tk.IntVar(value=200)
        self.ctrl_art = MotionSlider(c2, "Разрывы экрана", self.art_var, 0, 50000, "Нарезка кадра на горизонтальные полосы и их хаотичный сдвиг в стороны.", res=100, hover_cb=self.show_hover_description)

        self.vhs_tracking_var = tk.IntVar(value=0)
        self.ctrl_vhs = MotionSlider(c2, "VHS шум видеоголовки", self.vhs_tracking_var, 0, 100, "Полоса срыва синхронизации и цветного шума внизу экрана как на видеокассете.", hover_cb=self.show_hover_description)

        self.ctrl_ghost = MotionSlider(c2, "Залагивание окон и кадров", self.ghost_windows_var, 0, 100, "При открытии и перемещении окон старые кадры не закрываются и залипают.", hover_cb=self.show_hover_description)
        self.ctrl_gpu_art = MotionSlider(c2, "Артефакты памяти GPU", self.gpu_art_var, 0, 100, "Шахматные цветные артефакты сбоя видеопамяти и перегрева видеокарты.", hover_cb=self.show_hover_description)

        self.ads_var = tk.IntVar(value=10)
        self.ctrl_ads = MotionSlider(c2, "Количество реклам", self.ads_var, 0, 500, "Сколько рекламных баннеров случайно выбирается из папки ads и впечатывается в кадр.", hover_cb=self.show_hover_description)

        self.ad_alpha_var = tk.IntVar(value=90)
        self.ctrl_ad_alpha = MotionSlider(c2, "Непрозрачность реклам", self.ad_alpha_var, 10, 100, "Прозрачность накладываемых баннеров от призрачных до сплошных.", hover_cb=self.show_hover_description)

        self.noise_var = tk.IntVar(value=2)
        self.ctrl_noise = MotionSlider(c2, "Зернистость и шум", self.noise_var, 0, 100, "Аналоговый цифровой шум матрицы фотосенсора.", hover_cb=self.show_hover_description)

        self.dialup_var = tk.IntVar(value=0)
        self.ctrl_dialup = MotionSlider(c2, "Dial-Up срез экрана", self.dialup_var, 0, 90, "Срезает нижнюю часть экрана серым полотном с полосами загрузки интернета 90-х.", hover_cb=self.show_hover_description)

        self.fisheye_var = tk.IntVar(value=0)
        self.ctrl_fisheye = MotionSlider(c2, "Рыбий глаз CCTV", self.fisheye_var, 0, 100, "Бочкообразное искажение уличной камеры наблюдения с зеленой меткой CAM 03.", hover_cb=self.show_hover_description)

        self.xp_drag_var = tk.IntVar(value=0)
        self.ctrl_xp_drag = MotionSlider(c2, "Каскад окон XP", self.xp_drag_var, 0, 50, "Баг Windows XP: размножение застывших системных окон ошибок лесенкой.", hover_cb=self.show_hover_description)

        self.matrix_lines_var = tk.BooleanVar(value=False)
        self.chk_matrix = MotionCheck(c2, "Полосы битой матрицы", self.matrix_lines_var, "Вертикальные цветные нити поврежденного дисплейного шлейфа.", hover_cb=self.show_hover_description)

        self.dead_pixels_var = tk.BooleanVar(value=False)
        self.chk_dead = MotionCheck(c2, "Битые пиксели", self.dead_pixels_var, "Россыпь выгоревших субпикселей красного, зеленого и синего цветов.", hover_cb=self.show_hover_description)

        self.cursor_trail_var = tk.BooleanVar(value=False)
        self.chk_cursor = MotionCheck(c2, "Шлейф курсоров мыши", self.cursor_trail_var, "Цепочка зависших стрелок курсора мыши при зависании ОС.", hover_cb=self.show_hover_description)

        self.win_activate_var = tk.BooleanVar(value=False)
        self.chk_activate = MotionCheck(c2, "Активация Windows", self.win_activate_var, "Водяной знак Активация Windows в правом нижнем углу.", hover_cb=self.show_hover_description)

        # Col 3: Система, скримеры и звук
        c3 = tk.Frame(grid_f, bg=THEME["bg_card"], highlightbackground=THEME["border_card"], highlightthickness=1)
        c3.grid(row=0, column=2, sticky="nsew", padx=(2, 0), pady=1)

        tk.Label(c3, text="● Система, скримеры и звук", font=("Segoe UI", 8, "bold"), bg=THEME["bg_card"], fg=THEME["accent_rose"]).pack(anchor="w", padx=6, pady=(3, 1))

        av_f = tk.Frame(c3, bg=THEME["bg_card"])
        av_f.pack(fill="x", padx=4, pady=1)
        tk.Label(av_f, text="Антивирус:", font=("Segoe UI", 8), bg=THEME["bg_card"], fg=THEME["text_dim"]).pack(side="left")
        self.av_type_var = tk.StringVar(value="random")
        av_names = {
            "random": "Случайный",
            "kaspersky": "Kaspersky Total",
            "drweb": "Dr.Web CureIt!",
            "defender": "Windows Defender",
            "avast": "Avast Free",
            "eset": "ESET NOD32"
        }
        self.menu_av = MotionDropdown(av_f, self.av_type_var, ["random", "kaspersky", "drweb", "defender", "avast", "eset"], display_names=av_names, hover_cb=self.show_hover_description, hover_title="Антивирус", hover_desc="Стиль тревожного окна антивируса с обнаружением троянов.")
        self.menu_av.pack(side="right", fill="x", expand=True, padx=(6, 0))

        self.antivirus_alert_var = tk.BooleanVar(value=False)
        self.chk_anti = MotionCheck(c3, "Окно обнаружения вируса", self.antivirus_alert_var, "Выводит тревожное окно антивируса поверх создаваемого кадра.", hover_cb=self.show_hover_description)

        self.bsod_var = tk.BooleanVar(value=False)
        self.chk_bsod = MotionCheck(c3, "Синий экран BSOD", self.bsod_var, "Заменяет рабочий стол на настоящий синий экран смерти Windows с QR-кодом.", hover_cb=self.show_hover_description)

        self.bsod_glitch_var = tk.BooleanVar(value=False)
        self.chk_bsod_glitch = MotionCheck(c3, "Лаг и срыв BSOD", self.bsod_glitch_var, "Срывает BSOD на куски, сжимает в угол или отображает наполовину.", hover_cb=self.show_hover_description)

        self.screamer_img_var = tk.BooleanVar(value=False)
        self.chk_scr = MotionCheck(c3, "Лицо скримера на экране", self.screamer_img_var, "Впечатывает лицо скримера из папки screamers прямо в кадр.", hover_cb=self.show_hover_description)

        self.scr_extreme_var = tk.BooleanVar(value=False)
        self.chk_scr_ext = MotionCheck(c3, "ЭКСТРИМ Скример", self.scr_extreme_var, "Ультра-зум скримера на весь экран с выжиганием насыщенности.", is_extreme=True, hover_cb=self.show_hover_description)

        snd_f = tk.Frame(c3, bg=THEME["bg_card"])
        snd_f.pack(fill="x", padx=4, pady=1)
        tk.Label(snd_f, text="Звук:", font=("Segoe UI", 8), bg=THEME["bg_card"], fg=THEME["text_dim"]).pack(side="left")

        snd_names = {
            "camera": "Затвор камеры",
            "win_error": "Ошибка Windows",
            "usb_disconnect": "USB Отключение",
            "usb_connect": "USB Подключение",
            "icq": "ICQ О-оу",
            "screamer": "Крик скримера",
            "screamer_ear_rape": "ЭКСТРИМ Ear-Rape Крик",
            "bass_drop": "ЭКСТРИМ Взрыв баса"
        }
        self.sound_choice_var = tk.StringVar(value="usb_disconnect")
        self.menu_sound = MotionDropdown(snd_f, self.sound_choice_var, ["camera", "win_error", "usb_disconnect", "usb_connect", "icq", "screamer", "screamer_ear_rape", "bass_drop"], display_names=snd_names, hover_cb=self.show_hover_description, hover_title="Звук", hover_desc="Звуковой эффект при снимке: системные звуки Windows или оглушительные вопли.")
        self.menu_sound.pack(side="right", fill="x", expand=True, padx=(6, 0))

        hk_f = tk.Frame(c3, bg=THEME["bg_card"])
        hk_f.pack(fill="x", padx=4, pady=1)
        tk.Label(hk_f, text="Бинд:", font=("Segoe UI", 8), bg=THEME["bg_card"], fg=THEME["text_dim"]).pack(side="left")
        self.bind_var = tk.StringVar(value="F9")
        self.menu_bind = MotionDropdown(hk_f, self.bind_var, ["F8", "F9", "F10", "F11", "F12"], hover_cb=self.show_hover_description, hover_title="Бинд снимка", hover_desc="Глобальная системная горячая клавиша снимка экрана.")
        self.menu_bind.pack(side="right", fill="x", expand=True, padx=(6, 0))

        self.delay_var = tk.IntVar(value=0)
        self.ctrl_delay = MotionSlider(c3, "Задержка снимка", self.delay_var, 0, 10, "Таймер в секундах перед снимком экрана.", hover_cb=self.show_hover_description)

        save_box = tk.Frame(c3, bg=THEME["bg_card_inner"], highlightbackground=THEME["border_card"], highlightthickness=1)
        save_box.pack(fill="x", padx=4, pady=2)
        sb_top = tk.Frame(save_box, bg=THEME["bg_card_inner"])
        sb_top.pack(fill="x", padx=4, pady=1)
        self.lbl_save_dir = tk.Label(sb_top, text="Папка: screenshots", font=("Segoe UI", 8), bg=THEME["bg_card_inner"], fg=THEME["accent_blue"])
        self.lbl_save_dir.pack(side="left")

        sb_btn = tk.Frame(save_box, bg=THEME["bg_card_inner"])
        sb_btn.pack(fill="x", padx=4, pady=(0, 2))
        tk.Button(sb_btn, text="Открыть папку", font=("Segoe UI", 8), bg=THEME["btn_bg"], fg=THEME["text_main"], bd=0, padx=4, pady=1, cursor="hand2", command=lambda: os.startfile(self.save_dir)).pack(side="left", fill="x", expand=True, padx=(0, 2))
        tk.Button(sb_btn, text="Сменить", font=("Segoe UI", 8), bg=THEME["btn_bg"], fg=THEME["text_main"], bd=0, padx=4, pady=1, cursor="hand2", command=self.pick_save_folder).pack(side="right", fill="x", expand=True)

        # Bottom Bar
        bot_bar = tk.Frame(parent, bg=THEME["bg_root"])
        bot_bar.pack(fill="x", padx=8, pady=(1, 4))

        btn_row = tk.Frame(bot_bar, bg=THEME["bg_root"])
        btn_row.pack(fill="x", pady=(0, 2))

        tk.Button(btn_row, text="СДЕЛАТЬ ПОЛНЫЙ СКРИНШОТ", font=("Segoe UI", 9, "bold"), bg=THEME["accent_blue"], fg="#000000", activebackground="#2563eb", activeforeground="#ffffff", bd=0, pady=5, cursor="hand2", command=self.capture_fullscreen).pack(side="left", fill="x", expand=True, padx=(0, 2))
        tk.Button(btn_row, text="ВЫДЕЛИТЬ ОБЛАСТЬ", font=("Segoe UI", 9, "bold"), bg=THEME["btn_bg"], fg=THEME["accent_blue"], activebackground=THEME["border_highlight"], activeforeground=THEME["text_main"], bd=0, pady=5, cursor="hand2", command=self.start_area_snip, highlightbackground=THEME["accent_blue"], highlightthickness=1).pack(side="right", fill="x", expand=True, padx=(2, 0))

        b_sub2 = tk.Frame(bot_bar, bg=THEME["bg_root"])
        b_sub2.pack(fill="x")

        self.clip_var = tk.BooleanVar(value=True)
        self.chk_clip = MotionCheck(b_sub2, "Копировать в буфер", self.clip_var, "Помещает снимок прямо в буфер обмена для быстрой отправки в Discord или Telegram.", hover_cb=self.show_hover_description)
        self.chk_clip.frame.pack(side="left", padx=(0, 8))

        self.open_var = tk.BooleanVar(value=True)
        self.chk_open = MotionCheck(b_sub2, "Автооткрытие файла", self.open_var, "Открывает готовый файл сразу после снимка.", hover_cb=self.show_hover_description)
        self.chk_open.frame.pack(side="left")

        self.status_var = tk.StringVar(value="Готов к снимку")
        self.lbl_status = tk.Label(b_sub2, textvariable=self.status_var, bg=THEME["bg_root"], fg=THEME["text_dim"], font=("Segoe UI", 8))
        self.lbl_status.pack(side="right")

    # =========================================================================
    #                         2. VIDEO MODE UI
    # =========================================================================
    def build_video_mode_ui(self, parent):
        v_top = tk.Frame(parent, bg=THEME["bg_root"])
        v_top.pack(fill="x", padx=8, pady=(1, 2))

        tk.Label(v_top, text="Видео-стиль:", font=("Segoe UI", 8), bg=THEME["bg_root"], fg=THEME["text_dim"]).pack(side="left")

        v_presets = [
            "Стандартный Шакал",
            "ЭКСТРИМ ВИДЕО: Инфаркт",
            "ЭКСТРИМ ВИДЕО: Взрыв Перепонок",
            "ЭКСТРИМ ВИДЕО: Рекламный Ад и Вирусы",
            "ЭКСТРИМ ВИДЕО: Агония Матрицы",
            "HyperCam 2007",
            "Выгорание Матрицы OLED",
            "VHS Хоррор 1994"
        ]
        self.v_preset_var = tk.StringVar(value="Стандартный Шакал")
        self.menu_v_presets = MotionDropdown(v_top, self.v_preset_var, v_presets, callback=self.on_video_preset_picked, hover_cb=self.show_hover_description, hover_title="Видео-стили", hover_desc="Готовые конфигурации для записи видео экрана.")
        self.menu_v_presets.pack(side="left", padx=(3, 8))

        tk.Label(v_top, text="Статус:", font=("Segoe UI", 8), bg=THEME["bg_root"], fg=THEME["text_dim"]).pack(side="left")
        self.v_live_badge = tk.Label(v_top, text="ОЖИДАНИЕ ЗАПИСИ", font=("Consolas", 8, "bold"), bg=THEME["bg_card"], fg=THEME["accent_blue"], padx=6, pady=1)
        self.v_live_badge.pack(side="left", padx=3)

        # Video Resolution Slider on top row
        v_res_f = tk.Frame(v_top, bg=THEME["bg_root"])
        v_res_f.pack(side="right", padx=(8, 0))

        self.lbl_v_res = tk.Label(v_res_f, text="", font=("Segoe UI", 8, "bold"), bg=THEME["bg_root"], fg=THEME["accent_rose"])
        self.lbl_v_res.pack(side="left", padx=(0, 4))

        self.v_res_var = tk.IntVar(value=480)
        self.scale_v_res = tk.Scale(v_res_f, from_=72, to=NATIVE_H, orient="horizontal", variable=self.v_res_var, showvalue=False, bg=THEME["bg_root"], fg=THEME["accent_rose"], highlightthickness=0, troughcolor=THEME["trough"], activebackground=THEME["accent_rose"], command=self.update_v_res_label, sliderlength=12, width=8, length=120)
        self.scale_v_res.pack(side="left")
        self.update_v_res_label()

        # 3 Columns for Video
        v_grid = tk.Frame(parent, bg=THEME["bg_root"])
        v_grid.pack(fill="both", expand=True, padx=8, pady=1)
        v_grid.columnconfigure(0, weight=1)
        v_grid.columnconfigure(1, weight=1)
        v_grid.columnconfigure(2, weight=1)

        # Col 1: Видеопоток и выгорание
        vc1 = tk.Frame(v_grid, bg=THEME["bg_card"], highlightbackground=THEME["border_card"], highlightthickness=1)
        vc1.grid(row=0, column=0, sticky="nsew", padx=(0, 2), pady=1)

        tk.Label(vc1, text="● Видеопоток и выгорание", font=("Segoe UI", 8, "bold"), bg=THEME["bg_card"], fg=THEME["accent_rose"]).pack(anchor="w", padx=6, pady=(3, 1))

        self.v_fps_var = tk.IntVar(value=30)
        self.ctrl_v_fps = MotionSlider(vc1, "Частота кадров FPS", self.v_fps_var, 1, 240, "Частота кадров от 1 FPS до 240 FPS.", hover_cb=self.show_hover_description)

        self.v_q_var = tk.IntVar(value=30)
        self.ctrl_v_q = MotionSlider(vc1, "Сжатие видеопотока", self.v_q_var, 1, 100, "Сила распада каждого кадра видео на артефакты компрессии.", hover_cb=self.show_hover_description)

        self.v_burn_var = tk.IntVar(value=45)
        self.ctrl_v_burn = MotionSlider(vc1, "Выгорание экрана", self.v_burn_var, 0, 95, "Эффект выгоревшей матрицы: предыдущие кадры тянутся шлейфом.", hover_cb=self.show_hover_description)

        self.v_fry_var = tk.DoubleVar(value=1.5)
        self.ctrl_v_fry = MotionSlider(vc1, "Deep-Fry видео", self.v_fry_var, 1.0, 5.0, "Кислотное выжигание цветов и контраста прямо в видео.", is_float=True, res=0.1, hover_cb=self.show_hover_description)

        self.v_stutter_var = tk.IntVar(value=20)
        self.ctrl_v_stutter = MotionSlider(vc1, "Фризы и заклинивание кадра", self.v_stutter_var, 0, 90, "Шанс внезапного заклинивания видео на одном кадре.", hover_cb=self.show_hover_description)

        self.v_rgb_var = tk.IntVar(value=8)
        self.ctrl_v_rgb = MotionSlider(vc1, "Плавающий сдвиг RGB", self.v_rgb_var, 0, 80, "Динамическое раздвоение каналов в каждом кадре.", hover_cb=self.show_hover_description)

        self.v_mosh_var = tk.IntVar(value=20)
        self.ctrl_v_mosh = MotionSlider(vc1, "Датамошинг в движении", self.v_mosh_var, 0, 100, "Смазывание и распад макроблоков при записи видео.", hover_cb=self.show_hover_description)

        self.v_tear_var = tk.IntVar(value=30)
        self.ctrl_v_tear = MotionSlider(vc1, "Горизонтальные разрывы VHS", self.v_tear_var, 0, 100, "Полосы помех и срыв синхронизации видеокассеты.", hover_cb=self.show_hover_description)

        self.v_crt_var = tk.IntVar(value=0)
        self.ctrl_v_crt = MotionSlider(vc1, "CRT полосы в видео", self.v_crt_var, 0, 100, "Строчные полосы кинескопа поверх видеозаписи.", hover_cb=self.show_hover_description)

        self.v_invert_var = tk.BooleanVar(value=False)
        self.chk_v_inv = MotionCheck(vc1, "Инверсия цветов в видео", self.v_invert_var, "Режим психоделического негатива в видео.", hover_cb=self.show_hover_description)

        # Col 2: Живые рекламы и хаос
        vc2 = tk.Frame(v_grid, bg=THEME["bg_card"], highlightbackground=THEME["border_card"], highlightthickness=1)
        vc2.grid(row=0, column=1, sticky="nsew", padx=2, pady=1)

        tk.Label(vc2, text="● Живые рекламы и хаос", font=("Segoe UI", 8, "bold"), bg=THEME["bg_card"], fg=THEME["accent_amber"]).pack(anchor="w", padx=6, pady=(3, 1))

        self.ctrl_v_ghost = MotionSlider(vc2, "Залагивание окон и кадров", self.v_ghost_var, 0, 100, "Залипание старых окон и кадровый троттлинг: старые окна не закрываются на стриме.", hover_cb=self.show_hover_description)
        self.ctrl_v_gpu = MotionSlider(vc2, "Артефакты памяти GPU", self.v_gpu_art_var, 0, 100, "Шахматные цветные артефакты умирающей видеокарты для проверок.", hover_cb=self.show_hover_description)

        self.v_ad_rate_var = tk.IntVar(value=45)
        self.ctrl_v_ad_rate = MotionSlider(vc2, "Скорость появления реклам", self.v_ad_rate_var, 0, 100, "Как часто новые рекламные баннеры выскакивают на экране.", hover_cb=self.show_hover_description)

        self.v_ad_max_var = tk.IntVar(value=40)
        self.ctrl_v_ad_max = MotionSlider(vc2, "Максимум реклам на экране", self.v_ad_max_var, 0, 250, "Предел количества рекламных окон, висящих поверх видео.", hover_cb=self.show_hover_description)

        self.v_ad_shake_var = tk.IntVar(value=10)
        self.ctrl_v_ad_shake = MotionSlider(vc2, "Тряска и дрожание реклам", self.v_ad_shake_var, 0, 60, "Заставляет рекламы вибрировать и ползать по экрану.", hover_cb=self.show_hover_description)

        self.v_ad_accum_var = tk.BooleanVar(value=True)
        self.chk_v_accum = MotionCheck(vc2, "Накопление реклам", self.v_ad_accum_var, "Рекламы остаются на видео до самого конца, закрывая экран.", hover_cb=self.show_hover_description)

        self.v_ad_sound_var = tk.BooleanVar(value=True)
        self.chk_v_adsnd = MotionCheck(vc2, "Звук при появлении рекламы", self.v_ad_sound_var, "Системный звук ошибки или USB при каждом баннере.", hover_cb=self.show_hover_description)

        self.v_rand_av_var = tk.BooleanVar(value=True)
        self.chk_v_av = MotionCheck(vc2, "Внезапные атаки Антивирусов", self.v_rand_av_var, "На видео сами всплывают окна Dr.Web и Kaspersky.", hover_cb=self.show_hover_description)

        self.v_rand_scr_var = tk.BooleanVar(value=False)
        self.chk_v_scr = MotionCheck(vc2, "25 кадр скримера", self.v_rand_scr_var, "Внезапный всплеск лица скримера на долю секунды.", hover_cb=self.show_hover_description)

        self.v_scr_extreme_var = tk.BooleanVar(value=False)
        self.chk_v_scr_ext = MotionCheck(vc2, "ЭКСТРИМ Скример-Шторм", self.v_scr_extreme_var, "Частые непрерывные скримеры на весь экран с криками.", is_extreme=True, hover_cb=self.show_hover_description)

        self.v_end_bsod_var = tk.BooleanVar(value=True)
        self.chk_v_bsod = MotionCheck(vc2, "Финал видео с синим экраном BSOD", self.v_end_bsod_var, "Добавляет в конец видео краш в синий экран смерти Windows.", hover_cb=self.show_hover_description)

        vwm_f = tk.Frame(vc2, bg=THEME["bg_card"])
        vwm_f.pack(fill="x", padx=4, pady=2)
        tk.Label(vwm_f, text="Водяной знак:", font=("Segoe UI", 8), bg=THEME["bg_card"], fg=THEME["text_dim"]).pack(side="left")
        wm_names = {
            "hypercam": "Unregistered HyperCam 2",
            "bandicam": "www.Bandicam.com",
            "fraps": "FRAPS 1-7 FPS",
            "cctv": "Камера CCTV REC",
            "none": "Без знака"
        }
        self.v_wm_var = tk.StringVar(value="hypercam")
        self.menu_v_wm = MotionDropdown(vwm_f, self.v_wm_var, ["hypercam", "bandicam", "fraps", "cctv", "none"], display_names=wm_names, hover_cb=self.show_hover_description, hover_title="Водяной знак", hover_desc="Плашка ностальгической программы записи видео нулевых.")
        self.menu_v_wm.pack(side="right", fill="x", expand=True, padx=(6, 0))

        # Col 3: Шакальный звук и управление
        vc3 = tk.Frame(v_grid, bg=THEME["bg_card"], highlightbackground=THEME["border_card"], highlightthickness=1)
        vc3.grid(row=0, column=2, sticky="nsew", padx=(2, 0), pady=1)

        tk.Label(vc3, text="● Шакальный звук и управление", font=("Segoe UI", 8, "bold"), bg=THEME["bg_card"], fg=THEME["accent_blue"]).pack(anchor="w", padx=6, pady=(3, 1))

        self.v_audio_enable_var = tk.BooleanVar(value=True)
        self.chk_v_audio = MotionCheck(vc3, "Включить аудиодорожку в видео", self.v_audio_enable_var, "Запись звука и сведение шакальных эффектов в готовый ролик.", hover_cb=self.show_hover_description)

        self.v_bass_var = tk.IntVar(value=40)
        self.ctrl_v_bass = MotionSlider(vc3, "Басс-буст и перегруз", self.v_bass_var, 0, 100, "Усиление суб-баса и нелинейная сатурация до адского хрипа.", hover_cb=self.show_hover_description)

        self.v_clip_var = tk.IntVar(value=35)
        self.ctrl_v_clip = MotionSlider(vc3, "Жёсткий клиппинг звука", self.v_clip_var, 0, 100, "Срез пиков амплитуды для звука убитых динамиков кнопочного телефона.", hover_cb=self.show_hover_description)

        self.v_drop_var = tk.IntVar(value=25)
        self.ctrl_v_drop = MotionSlider(vc3, "Резкие пропадания звука", self.v_drop_var, 0, 100, "Звук внезапно заикается и пропадает на доли секунды.", hover_cb=self.show_hover_description)

        self.v_bit_var = tk.IntVar(value=30)
        self.ctrl_v_bit = MotionSlider(vc3, "Биткрашер звука", self.v_bit_var, 0, 100, "Понижение разрядности и частоты дискретизации до древней рации.", hover_cb=self.show_hover_description)

        self.v_hum_var = tk.IntVar(value=15)
        self.ctrl_v_hum = MotionSlider(vc3, "Шум микрофона", self.v_hum_var, 0, 100, "Гул 50 Гц, шипение и фоновый статический треск.", hover_cb=self.show_hover_description)

        self.v_screamer_vol_var = tk.IntVar(value=150)
        self.ctrl_v_scr_vol = MotionSlider(vc3, "Громкость криков скримеров", self.v_screamer_vol_var, 0, 300, "Громкость внезапных истошных воплей во время видео.", hover_cb=self.show_hover_description)

        vhk_f = tk.Frame(vc3, bg=THEME["bg_card"])
        vhk_f.pack(fill="x", padx=4, pady=1)
        tk.Label(vhk_f, text="Бинд:", font=("Segoe UI", 8), bg=THEME["bg_card"], fg=THEME["text_dim"]).pack(side="left")
        self.v_bind_var = tk.StringVar(value="F10")
        self.menu_v_bind = MotionDropdown(vhk_f, self.v_bind_var, ["F8", "F9", "F10", "F11", "F12"], hover_cb=self.show_hover_description, hover_title="Бинд видео", hover_desc="Горячая клавиша старта и остановки записи видео.")
        self.menu_v_bind.pack(side="right", fill="x", expand=True, padx=(6, 0))

        self.v_limit_sec_var = tk.IntVar(value=15)
        self.ctrl_v_limit = MotionSlider(vc3, "Лимит длительности записи", self.v_limit_sec_var, 3, 120, "Максимальная длина видеоролика в секундах.", hover_cb=self.show_hover_description)

        vsave_box = tk.Frame(vc3, bg=THEME["bg_card_inner"], highlightbackground=THEME["border_card"], highlightthickness=1)
        vsave_box.pack(fill="x", padx=4, pady=2)
        vsb_top = tk.Frame(vsave_box, bg=THEME["bg_card_inner"])
        vsb_top.pack(fill="x", padx=4, pady=1)
        self.lbl_v_save_dir = tk.Label(vsb_top, text="Папка: videos", font=("Segoe UI", 8), bg=THEME["bg_card_inner"], fg=THEME["accent_rose"])
        self.lbl_v_save_dir.pack(side="left")

        vsb_btn = tk.Frame(vsave_box, bg=THEME["bg_card_inner"])
        vsb_btn.pack(fill="x", padx=4, pady=(0, 2))
        tk.Button(vsb_btn, text="Открыть папку", font=("Segoe UI", 8), bg=THEME["btn_bg"], fg=THEME["text_main"], bd=0, padx=4, pady=1, cursor="hand2", command=lambda: os.startfile(self.video_save_dir)).pack(side="left", fill="x", expand=True, padx=(0, 2))
        tk.Button(vsb_btn, text="Сменить", font=("Segoe UI", 8), bg=THEME["btn_bg"], fg=THEME["text_main"], bd=0, padx=4, pady=1, cursor="hand2", command=self.pick_video_folder).pack(side="right", fill="x", expand=True)

        # Video Bottom Bar
        v_bot = tk.Frame(parent, bg=THEME["bg_root"])
        v_bot.pack(fill="x", padx=8, pady=(1, 4))

        self.btn_v_record = tk.Button(
            v_bot, text="НАЧАТЬ ЗАПИСЬ ВИДЕО", font=("Segoe UI", 9, "bold"),
            bg=THEME["accent_rose"], fg="#ffffff", activebackground="#be123c", activeforeground="#ffffff",
            bd=0, pady=5, cursor="hand2", command=self.toggle_video_recording
        )
        self.btn_v_record.pack(fill="x", pady=(0, 2))

        vb_sub = tk.Frame(v_bot, bg=THEME["bg_root"])
        vb_sub.pack(fill="x")

        self.v_open_after_var = tk.BooleanVar(value=True)
        self.chk_v_open = MotionCheck(vb_sub, "Автооткрытие готового видео", self.v_open_after_var, "Запуск ролика в плеере сразу после сохранения.", hover_cb=self.show_hover_description)
        self.chk_v_open.frame.pack(side="left")

        self.v_status_var = tk.StringVar(value="Готов к видеозаписи")
        tk.Label(vb_sub, textvariable=self.v_status_var, bg=THEME["bg_root"], fg=THEME["text_dim"], font=("Segoe UI", 8)).pack(side="right")

    # =========================================================================
    #                         3. DISCORD PRANK MODE UI
    # =========================================================================
    def build_discord_mode_ui(self, parent):
        d_top = tk.Frame(parent, bg=THEME["bg_card"], highlightbackground=THEME["border_card"], highlightthickness=1)
        d_top.pack(fill="x", padx=8, pady=(2, 3))

        tk.Label(d_top, text="🟣 ТРАНСЛЯЦИЯ ДЛЯ DISCORD", font=("Segoe UI", 9, "bold"), bg=THEME["bg_card"], fg=THEME["accent_amber"]).pack(side="left", padx=8, pady=4)
        tk.Label(d_top, text="● НА ЭКРАНЕ ВСЕ НАСТРОЙКИ ИЗ ВКЛАДКИ ВИДЕО", font=("Consolas", 8, "bold"), bg=THEME["bg_card_inner"], fg=THEME["accent_blue"], padx=6, pady=2).pack(side="left", padx=3)

        btn_go_vid = tk.Button(d_top, text="⚙️ Настройки видео", font=("Segoe UI", 8, "bold"), bg=THEME["btn_bg"], fg=THEME["text_dim"], activebackground=THEME["border_highlight"], activeforeground=THEME["text_main"], bd=0, padx=8, pady=2, cursor="hand2", command=lambda: self.switch_mode("video"))
        btn_go_vid.pack(side="right", padx=6)

        # Discord Layout: Main Live Screen Display on Left, Controls on Right
        d_body = tk.Frame(parent, bg=THEME["bg_root"])
        d_body.pack(fill="both", expand=True, padx=8, pady=1)
        d_body.columnconfigure(0, weight=3)
        d_body.columnconfigure(1, weight=1)

        # Left Column: The Live Screen Preview
        screen_card = tk.Frame(d_body, bg=THEME["bg_card"], highlightbackground=THEME["border_card"], highlightthickness=1)
        screen_card.grid(row=0, column=0, sticky="nsew", padx=(0, 2), pady=1)

        head_f = tk.Frame(screen_card, bg=THEME["bg_card"])
        head_f.pack(fill="x", padx=6, pady=(4, 2))

        monitors = get_system_monitors()
        self.has_second_monitor = len(monitors) > 1

        # Button 1: Transparent Click-Through Overlay on Screen 1
        self.btn_overlay = tk.Button(
            head_f, text="📺 ОВЕРЛЕЙ НА ЭКРАН 1: СКВОЗНОЙ", font=("Segoe UI", 8, "bold"),
            bg=THEME["accent_amber"], fg="#000000", activebackground="#d97706", activeforeground="#ffffff",
            bd=0, padx=8, pady=2, cursor="hand2", command=self.toggle_overlay_screen1
        )
        self.btn_overlay.pack(side="left", padx=(0, 4))

        # Quick cheat check preset trigger right on Discord tab
        btn_quick_cheat = tk.Button(
            head_f, text="🛡️ ПРЕСЕТ: ПРОВЕРКА НА ЧИТЫ", font=("Segoe UI", 8, "bold"),
            bg=THEME["btn_bg"], fg=THEME["accent_amber"], activebackground=THEME["accent_amber"], activeforeground="#000000",
            bd=0, padx=8, pady=2, cursor="hand2", highlightbackground=THEME["accent_amber"], highlightthickness=1,
            command=self.apply_cheat_check_preset
        )
        btn_quick_cheat.pack(side="left", padx=2)

        # Button 2: Stream Window for Discord Applications Tab
        self.btn_pop_stream = tk.Button(
            head_f, text="🪟 ОКНО ДЛЯ СТРИМА DISCORD", font=("Segoe UI", 8, "bold"),
            bg=THEME["btn_bg"], fg=THEME["accent_blue"], activebackground=THEME["accent_blue"], activeforeground="#000000",
            bd=0, padx=8, pady=2, cursor="hand2", command=self.toggle_discord_stream_window
        )
        self.btn_pop_stream.pack(side="left", padx=2)

        if self.has_second_monitor:
            self.btn_screen2 = tk.Button(
                head_f, text="🖥️ ВЫВЕСТИ НА ЭКРАН 2", font=("Segoe UI", 8, "bold"),
                bg=THEME["btn_bg"], fg=THEME["text_main"], activebackground=THEME["border_highlight"],
                bd=0, padx=8, pady=2, cursor="hand2", command=self.toggle_screen_2_fullscreen
            )
            self.btn_screen2.pack(side="left", padx=2)

        btn_clr_ads = tk.Button(
            head_f, text="🧹 Очистить", font=("Segoe UI", 8),
            bg=THEME["btn_bg"], fg=THEME["text_dim"], activebackground=THEME["border_highlight"], activeforeground=THEME["text_main"],
            bd=0, padx=6, pady=2, cursor="hand2", command=self.clear_all_prank_effects
        )
        btn_clr_ads.pack(side="right", padx=3)

        # The Actual Live Canvas Label
        self.d_live_canvas = tk.Label(screen_card, bg="#000000", bd=0)
        self.d_live_canvas.pack(fill="both", expand=True, padx=6, pady=4)

        # Right Column: Instant Prank Triggers
        triggers_card = tk.Frame(d_body, bg=THEME["bg_card"], highlightbackground=THEME["border_card"], highlightthickness=1)
        triggers_card.grid(row=0, column=1, sticky="nsew", padx=(2, 0), pady=1)

        # Section: Cheat Check & Real Windows Bugs
        tk.Label(triggers_card, text="🛡️ Проверка на читы: баги системы", font=("Segoe UI", 8, "bold"), bg=THEME["bg_card"], fg=THEME["accent_amber"]).pack(anchor="w", padx=6, pady=(3, 1))

        tk.Button(
            triggers_card, text="⚡ СЛЕТ ВИДЕОДРАЙВЕРА TDR", font=("Segoe UI", 8, "bold"),
            bg=THEME["btn_bg"], fg=THEME["accent_amber"], activebackground=THEME["accent_amber"], activeforeground="#000000",
            bd=0, pady=4, cursor="hand2", highlightbackground=THEME["accent_amber"], highlightthickness=1, command=self.trigger_tdr_crash
        ).pack(fill="x", padx=6, pady=2)

        tk.Button(
            triggers_card, text="⚠️ СБОЙ ПАМЯТИ EXPLORER", font=("Segoe UI", 8, "bold"),
            bg=THEME["btn_bg"], fg=THEME["accent_blue"], activebackground=THEME["accent_blue"], activeforeground="#000000",
            bd=0, pady=4, cursor="hand2", highlightbackground=THEME["accent_blue"], highlightthickness=1, command=self.trigger_memory_error
        ).pack(fill="x", padx=6, pady=2)

        tk.Button(
            triggers_card, text="🧊 ЗАВИСАНИЕ ЗВУКА TRRR", font=("Segoe UI", 8, "bold"),
            bg=THEME["btn_bg"], fg=THEME["accent_rose"], activebackground=THEME["accent_rose"], activeforeground="#ffffff",
            bd=0, pady=4, cursor="hand2", highlightbackground=THEME["accent_rose"], highlightthickness=1, command=lambda: ShakalAudioEngine.play("dpc_freeze")
        ).pack(fill="x", padx=6, pady=2)

        tk.Button(
            triggers_card, text="🪟 ЗАЛИПАНИЕ СТАРОГО ОКНА", font=("Segoe UI", 8, "bold"),
            bg=THEME["btn_bg"], fg=THEME["text_main"], activebackground=THEME["border_highlight"], activeforeground=THEME["text_main"],
            bd=0, pady=4, cursor="hand2", command=self.trigger_stuck_ghost_window
        ).pack(fill="x", padx=6, pady=2)

        # Section: Extreme Triggers
        tk.Label(triggers_card, text="● Экстремальные триггеры", font=("Segoe UI", 8, "bold"), bg=THEME["bg_card"], fg=THEME["accent_rose"]).pack(anchor="w", padx=6, pady=(5, 1))

        tk.Button(
            triggers_card, text="😱 БРОСИТЬ СКРИМЕР И КРИК", font=("Segoe UI", 8, "bold"),
            bg=THEME["accent_rose"], fg="#ffffff", activebackground="#be123c", activeforeground="#ffffff",
            bd=0, pady=4, cursor="hand2", command=self.trigger_prank_screamer
        ).pack(fill="x", padx=6, pady=2)

        tk.Button(
            triggers_card, text="💀 МГНОВЕННЫЙ КРАШ В BSOD", font=("Segoe UI", 8, "bold"),
            bg="#2563eb", fg="#ffffff", activebackground="#1d4ed8", activeforeground="#ffffff",
            bd=0, pady=4, cursor="hand2", command=self.trigger_prank_bsod
        ).pack(fill="x", padx=6, pady=2)

        tk.Button(
            triggers_card, text="☣️ АТАКА 50 РЕКЛАМНЫХ БАННЕРОВ", font=("Segoe UI", 8, "bold"),
            bg=THEME["accent_amber"], fg="#000000", activebackground="#d97706", activeforeground="#ffffff",
            bd=0, pady=4, cursor="hand2", command=self.trigger_prank_ads
        ).pack(fill="x", padx=6, pady=2)

        tk.Button(
            triggers_card, text="📢 ВЗРЫВ ПЕРЕПОНОК EAR-RAPE", font=("Segoe UI", 8, "bold"),
            bg=THEME["btn_bg"], fg=THEME["accent_rose"], activebackground=THEME["accent_rose"], activeforeground="#ffffff",
            bd=0, pady=4, cursor="hand2", highlightbackground=THEME["accent_rose"], highlightthickness=1, command=lambda: ShakalAudioEngine.play("screamer_ear_rape")
        ).pack(fill="x", padx=6, pady=2)

        info_f = tk.Frame(triggers_card, bg=THEME["bg_card_inner"], highlightbackground=THEME["border_card"], highlightthickness=1)
        info_f.pack(fill="x", padx=6, pady=(4, 2))
        tk.Label(info_f, text="Стрим в Discord без драйверов:", font=("Segoe UI", 8, "bold"), bg=THEME["bg_card_inner"], fg=THEME["text_main"]).pack(anchor="w", padx=6, pady=(3, 1))
        info_txt = (
            "1. Стрим Весь экран (Экран 1):\n"
            "   Включите ОВЕРЛЕЙ НА ЭКРАН 1.\n"
            "   Сквозной слой рисует баги поверх экрана,\n"
            "   а сама студия скрыта от стрима!\n\n"
            "2. Стрим по окну приложения:\n"
            "   Нажмите ОКНО ДЛЯ СТРИМА DISCORD.\n"
            "   В Discord выберите Приложения -> Рабочий стол Windows."
        )
        tk.Label(info_f, text=info_txt, font=("Segoe UI", 8), bg=THEME["bg_card_inner"], fg=THEME["text_dim"], justify="left").pack(anchor="w", padx=6, pady=(0, 4))

    def apply_cheat_check_preset(self):
        target = "🛡️ Чит-Проверка: Сбой Windows и Видеокарты"
        if target not in self.custom_presets and "Проверка на читы" in self.custom_presets:
            target = "Проверка на читы"

        cfg = self.custom_presets.get(target, {
            "res": NATIVE_H, "q": 95, "pix": 1, "fry": 1.0, "sharp": 1, "rgb": 0, "datamosh": 5,
            "dialup": 0, "fisheye": 0, "xp_drag": 0, "ads": 0, "ad_alpha": 0, "art": 0, "noise": 2,
            "matrix": False, "dead": False, "cursor": True, "win_act": False, "anti": False,
            "bsod": False, "bsod_glitch": False, "scr": False, "scr_extreme": False, "swirl": 0,
            "invert": False, "solarize": False, "crt": 0, "jitter": 0, "vignette": 0, "vhs_tracking": 0,
            "bitcrush": 0, "sound": "none", "ghost_windows": 75, "gpu_artifacts": 35,
            "tdr_crash": True, "audio_stutter": True, "mem_error": True, "mouse_stutter": True
        })

        self.apply_preset_dict(cfg)
        self.selected_preset_var.set(target)
        if hasattr(self, "menu_presets"):
            self.menu_presets.lbl.config(text=target)

        # Immediate desktop snapshot for ghost window trailing
        try:
            raw = ImageGrab.grab().convert("RGB")
            self._ghost_history = [raw, raw]
        except Exception:
            pass

        # Automatically start the overlay if not yet active so prank is LIVE!
        if not self.is_overlay_active:
            self.toggle_overlay_screen1()

        ShakalAudioEngine.play("usb_disconnect")
        self.status_var.set("Пресет Проверка на читы включен и работает на экране!")

    def toggle_overlay_screen1(self):
        if self.overlay_window is None or not self.overlay_window.winfo_exists():
            # 1. Create transparent click-through background window
            self.overlay_window = tk.Toplevel(self.root)
            self.overlay_window.title("Shakal Overlay")
            self.overlay_window.geometry(f"{NATIVE_W}x{NATIVE_H}+0+0")
            self.overlay_window.overrideredirect(True)
            self.overlay_window.attributes("-topmost", True)
            self.overlay_window.wm_attributes("-transparentcolor", "#010203")
            self.overlay_window.configure(bg="#010203")

            try:
                hwnd = self.overlay_window.winfo_id()
                GWL_EXSTYLE = -20
                WS_EX_TRANSPARENT = 0x00000020
                WS_EX_LAYERED = 0x00080000
                style = ctypes.windll.user32.GetWindowLongW(hwnd, GWL_EXSTYLE)
                ctypes.windll.user32.SetWindowLongW(hwnd, GWL_EXSTYLE, style | WS_EX_TRANSPARENT | WS_EX_LAYERED)
            except Exception:
                pass

            self.overlay_canvas = tk.Label(self.overlay_window, bg="#010203", bd=0)
            self.overlay_canvas.pack(fill="both", expand=True)

            # 2. Dedicated Clickable Floating Exit Bar (top center)
            self.overlay_ctrl_bar = tk.Toplevel(self.root)
            self.overlay_ctrl_bar.title("Shakal Exit Bar")
            bar_w, bar_h = 300, 36
            bar_x = (NATIVE_W - bar_w) // 2
            bar_y = 10
            self.overlay_ctrl_bar.geometry(f"{bar_w}x{bar_h}+{bar_x}+{bar_y}")
            self.overlay_ctrl_bar.overrideredirect(True)
            self.overlay_ctrl_bar.attributes("-topmost", True)
            self.overlay_ctrl_bar.configure(bg="#be123c")

            # Exclude Floating Exit Bar from screen capture so viewers cannot see it!
            try:
                hwnd_bar = self.overlay_ctrl_bar.winfo_id()
                ctypes.windll.user32.SetWindowDisplayAffinity(hwnd_bar, 0x11)
            except Exception:
                pass

            btn_exit = tk.Button(
                self.overlay_ctrl_bar, text="🛑 ВЫКЛЮЧИТЬ ОВЕРЛЕЙ [Esc]",
                font=("Segoe UI", 9, "bold"), bg="#be123c", fg="#ffffff",
                activebackground="#9f1239", activeforeground="#ffffff",
                bd=0, cursor="hand2", command=self.stop_all_prank_streams
            )
            btn_exit.pack(fill="both", expand=True, padx=2, pady=2)

            # 3. Keep Main Studio Window on top so user can control it at any time
            self.root.attributes("-topmost", True)
            self.root.lift()

            self.btn_overlay.config(text="🛑 ОСТАНОВИТЬ ОВЕРЛЕЙ", bg=THEME["accent_rose"], fg="#ffffff")
            self.is_overlay_active = True
        else:
            self.stop_all_prank_streams()

    def stop_overlay(self):
        if hasattr(self, "overlay_ctrl_bar") and self.overlay_ctrl_bar:
            try:
                self.overlay_ctrl_bar.destroy()
            except Exception:
                pass
            self.overlay_ctrl_bar = None

        if self.overlay_window:
            try:
                self.overlay_window.destroy()
            except Exception:
                pass
            self.overlay_window = None
            self.overlay_canvas = None

        self.is_overlay_active = False
        if hasattr(self, "btn_overlay"):
            self.btn_overlay.config(text="📺 ОВЕРЛЕЙ НА ЭКРАН 1: СКВОЗНОЙ", bg=THEME["accent_amber"], fg="#000000")

    def toggle_discord_stream_window(self):
        if self.discord_window is None or not self.discord_window.winfo_exists():
            self.discord_window = tk.Toplevel(self.root)
            self.discord_window.title("Рабочий стол Windows")
            self.discord_window.geometry("1020x576")
            self.discord_window.configure(bg="#000000")

            self.d_pop_canvas = tk.Label(self.discord_window, bg="#000000")
            self.d_pop_canvas.pack(fill="both", expand=True)

            self.btn_pop_stream.config(text="Закрыть окно стрима", bg=THEME["accent_rose"], fg="#ffffff")
            self.discord_window.protocol("WM_DELETE_WINDOW", self._on_popped_window_closed)
            self.discord_window.bind("<Escape>", lambda e: self._on_popped_window_closed())
        else:
            self._on_popped_window_closed()

    def _on_popped_window_closed(self):
        if self.discord_window:
            try:
                self.discord_window.destroy()
            except Exception:
                pass
            self.discord_window = None
        if hasattr(self, "btn_pop_stream"):
            self.btn_pop_stream.config(text="🪟 ОКНО ДЛЯ СТРИМА DISCORD", bg=THEME["btn_bg"], fg=THEME["accent_blue"])

    def stop_all_prank_streams(self):
        self.stop_overlay()
        self._on_popped_window_closed()

    def toggle_screen_2_fullscreen(self):
        monitors = get_system_monitors()
        if len(monitors) > 1:
            m2 = monitors[1]
            if self.discord_window is None or not self.discord_window.winfo_exists():
                self.discord_window = tk.Toplevel(self.root)
                self.discord_window.title("Рабочий стол Windows")
                self.discord_window.geometry(f"{m2['w']}x{m2['h']}+{m2['x']}+{m2['y']}")
                self.discord_window.overrideredirect(True)
                self.discord_window.configure(bg="#000000")

                self.d_pop_canvas = tk.Label(self.discord_window, bg="#000000")
                self.d_pop_canvas.pack(fill="both", expand=True)

                self.btn_pop_stream.config(text="Закрыть Экран 2", bg=THEME["accent_rose"], fg="#ffffff")
                self.discord_window.bind("<Escape>", lambda e: self._on_popped_window_closed())
            else:
                self._on_popped_window_closed()
        else:
            self.toggle_discord_stream_window()

    def trigger_tdr_crash(self):
        self.tdr_flash_active = True
        ShakalAudioEngine.play("dpc_freeze")
        def _end_flash():
            self.tdr_flash_active = False
            self.tdr_toast_timer = 120
        self.root.after(700, _end_flash)

    def trigger_memory_error(self):
        self.mem_error_active = not self.mem_error_active
        if self.mem_error_active:
            ShakalAudioEngine.play("win_error")

    def trigger_stuck_ghost_window(self):
        try:
            raw = ImageGrab.grab().convert("RGB")
            if not hasattr(self, "_ghost_history"):
                self._ghost_history = []
            self._ghost_history.append(raw)
            self.v_ghost_var.set(85)
            self.ghost_windows_var.set(85)
            ShakalAudioEngine.play("usb_disconnect")
        except Exception:
            pass

    def clear_all_prank_effects(self):
        self.live_active_ads = []
        self.live_prev_burn_img = None
        self.prank_screamer_flash = False
        self.prank_bsod_active = False
        self.tdr_flash_active = False
        self.tdr_toast_timer = 0
        self.mem_error_active = False
        self._ghost_history = []
        self.v_ghost_var.set(0)
        self.ghost_windows_var.set(0)
        self.v_gpu_art_var.set(0)
        self.gpu_art_var.set(0)
        self.status_var.set("Все эффекты и рекламы очищены")

    def clear_prank_ads(self):
        self.clear_all_prank_effects()

    # =========================================================================
    #                DISCORD LIVE RENDER WORKER (USES VIDEO SETTINGS!)
    # =========================================================================
    def _draw_overlay_glitches(self, ov_img, raw):
        draw = ImageDraw.Draw(ov_img)
        # 1. Ghost windows trail on overlay
        ghost_v = self.v_ghost_var.get() or self.ghost_windows_var.get()
        if ghost_v > 0 and self._ghost_history:
            old_snap = self._ghost_history[0]
            gw = int(NATIVE_W * 0.45)
            gh = int(NATIVE_H * 0.4)
            gx = (NATIVE_W - gw) // 2
            gy = (NATIVE_H - gh) // 2
            g_cut = old_snap.crop((gx, gy, gx + gw, gy + gh))
            steps = min(5, int((ghost_v / 100.0) * 5))
            for idx in range(steps, 0, -1):
                tx = max(0, min(NATIVE_W - gw, gx + idx * 24))
                ty = max(0, min(NATIVE_H - gh, gy + idx * 18))
                ov_img.paste(g_cut, (tx, ty))

        # 2. GPU VRAM Artifacts on overlay
        gpu_v = self.v_gpu_art_var.get() or self.gpu_art_var.get()
        if gpu_v > 0:
            count = int((gpu_v / 100.0) * 22)
            for _ in range(count):
                bx = random.randint(0, max(1, NATIVE_W - 64))
                by = random.randint(0, max(1, NATIVE_H - 64))
                for bi in range(4):
                    for bj in range(4):
                        col = (255, 0, 255) if (bi + bj) % 2 == 0 else (0, 255, 255)
                        draw.rectangle([bx + bi*8, by + bj*8, bx + (bi+1)*8, by + (bj+1)*8], fill=col)

        # 3. TDR toast on overlay
        if self.tdr_toast_timer > 0:
            tw, th = 340, 80
            tx = NATIVE_W - tw - 16
            ty = NATIVE_H - th - 24
            draw.rectangle([tx, ty, tx + tw, ty + th], fill=(31, 31, 31), outline=(65, 65, 65), width=1)
            draw.rectangle([tx + 12, ty + 14, tx + 36, ty + 34], fill=(0, 120, 215))
            draw.text((tx + 46, ty + 12), "Параметры экрана", fill=(255, 255, 255))
            draw.text((tx + 46, ty + 30), "Видеодрайвер NVIDIA Windows Kernel Mode\nDriver перестал отвечать и был успешно\nвосстановлен.", fill=(195, 195, 195))

        # 4. Memory error on overlay
        if self.mem_error_active:
            mw, mh = 380, 130
            mx = (NATIVE_W - mw) // 2
            my = (NATIVE_H - mh) // 2
            draw.rectangle([mx, my, mx + mw, my + mh], fill=(240, 240, 240), outline=(120, 120, 120), width=1)
            draw.rectangle([mx, my, mx + mw, my + 24], fill=(255, 255, 255))
            draw.text((mx + 8, my + 5), "explorer.exe - Ошибка приложения", fill=(0, 0, 0))
            draw.ellipse([mx + 14, my + 40, mx + 42, my + 68], fill=(210, 30, 30))
            draw.text((mx + 22, my + 44), "X", fill=(255, 255, 255))
            draw.text((mx + 52, my + 38), "Инструкция по адресу 0x00007FF63B48\nобратилась к памяти по адресу 0x00000000.\nПамять не может быть \"read\".", fill=(0, 0, 0))
            draw.rectangle([mx + mw - 85, my + mh - 30, mx + mw - 14, my + mh - 10], fill=(225, 225, 225), outline=(160, 160, 160))
            draw.text((mx + mw - 58, my + mh - 26), "ОК", fill=(0, 0, 0))

    def _discord_live_worker(self):
        while self.running:
            t0 = time.time()
            need_work = (
                self.current_mode == "discord" or
                (self.discord_window and self.discord_window.winfo_exists()) or
                (self.is_overlay_active and self.overlay_window and self.overlay_window.winfo_exists())
            )
            if need_work:
                try:
                    raw = ImageGrab.grab().convert("RGB")
                    processed = self._process_video_effects_live(raw)

                    # Update embedded preview on Discord tab
                    cw = max(80, self.d_live_canvas.winfo_width())
                    ch = max(60, self.d_live_canvas.winfo_height())
                    if cw > 80 and ch > 60:
                        disp = processed.resize((cw, ch), Image.Resampling.BILINEAR)
                        photo = ImageTk.PhotoImage(disp)

                        def _up_main(p=photo):
                            if self.running and self.current_mode == "discord":
                                self.d_live_canvas.configure(image=p)
                                self.d_live_canvas.image = p
                        self.root.after(0, _up_main)

                    # Update popped out window if active
                    if self.discord_window and self.discord_window.winfo_exists():
                        pw = max(80, self.discord_window.winfo_width())
                        ph = max(60, self.discord_window.winfo_height())
                        disp_pop = processed.resize((pw, ph), Image.Resampling.BILINEAR)
                        pop_photo = ImageTk.PhotoImage(disp_pop)

                        def _up_pop(p=pop_photo):
                            if self.discord_window and self.discord_window.winfo_exists():
                                self.d_pop_canvas.configure(image=p)
                                self.d_pop_canvas.image = p
                        self.root.after(0, _up_pop)

                    # Update transparent overlay on Screen 1 if active
                    if self.is_overlay_active and self.overlay_window and self.overlay_window.winfo_exists():
                        if self.tdr_flash_active:
                            ov_img = Image.new("RGB", (NATIVE_W, NATIVE_H), (0, 0, 0))
                        else:
                            ov_img = Image.new("RGB", (NATIVE_W, NATIVE_H), (1, 2, 3))
                            self._draw_overlay_glitches(ov_img, raw)
                        ov_photo = ImageTk.PhotoImage(ov_img)

                        def _up_ov(p=ov_photo):
                            if self.is_overlay_active and self.overlay_window and self.overlay_window.winfo_exists():
                                self.overlay_canvas.configure(image=p)
                                self.overlay_canvas.image = p
                        self.root.after(0, _up_ov)

                except Exception:
                    pass

            target_fps = min(60, max(5, self.v_fps_var.get()))
            sleep_t = max(0.016, (1.0 / target_fps) - (time.time() - t0))
            time.sleep(sleep_t)

    def _process_video_effects_live(self, raw):
        out_w, out_h = 960, 540
        img = raw.resize((out_w, out_h), Image.Resampling.BILINEAR)

        # TDR Blackout Flash
        if self.tdr_flash_active:
            return Image.new("RGB", (out_w, out_h), (0, 0, 0))

        # Ghost Windows / Frame Stutter (Залагивание кадров и залипание окон)
        ghost_v = self.v_ghost_var.get()
        if ghost_v > 0:
            if not hasattr(self, "_ghost_history"):
                self._ghost_history = []
            if len(self._ghost_history) == 0 or random.random() < 0.14:
                self._ghost_history.append(raw.copy())
                if len(self._ghost_history) > 6:
                    self._ghost_history.pop(0)
            if self._ghost_history:
                old_snap = self._ghost_history[0].resize((out_w, out_h), Image.Resampling.BILINEAR)
                if ghost_v > 35:
                    gw = int(out_w * 0.44)
                    gh = int(out_h * 0.4)
                    gx = (out_w - gw) // 2
                    gy = (out_h - gh) // 2
                    g_cut = old_snap.crop((gx, gy, gx + gw, gy + gh))
                    trail_count = min(5, int((ghost_v / 100.0) * 5))
                    for idx in range(trail_count, 0, -1):
                        tx = max(0, min(out_w - gw, gx + idx * 22))
                        ty = max(0, min(out_h - gh, gy + idx * 16))
                        img.paste(g_cut, (tx, ty))
                else:
                    alpha = min(0.85, (ghost_v / 100.0) * 0.8)
                    img = Image.blend(img, old_snap, alpha)

        # GPU VRAM Artifacts (Шахматка)
        gpu_v = self.v_gpu_art_var.get()
        if gpu_v > 0:
            draw = ImageDraw.Draw(img)
            count = int((gpu_v / 100.0) * 20)
            for _ in range(count):
                bx = random.randint(0, max(1, out_w - 64))
                by = random.randint(0, max(1, out_h - 64))
                for bi in range(4):
                    for bj in range(4):
                        col = (255, 0, 255) if (bi + bj) % 2 == 0 else (0, 255, 255)
                        draw.rectangle([bx + bi*8, by + bj*8, bx + (bi+1)*8, by + (bj+1)*8], fill=col)
            if random.random() < (gpu_v / 100.0):
                for _ in range(int((gpu_v / 100.0) * 6)):
                    ly = random.randint(0, out_h - 2)
                    lx = random.randint(0, out_w // 2)
                    draw.line([(lx, ly), (lx + random.randint(60, 260), ly)], fill=random.choice([(255, 0, 0), (0, 255, 0), (0, 255, 255)]), width=random.randint(1, 2))

        # TDR Toast
        if self.tdr_toast_timer > 0:
            draw = ImageDraw.Draw(img)
            tw, th = 320, 75
            tx = out_w - tw - 12
            ty = out_h - th - 16
            draw.rectangle([tx, ty, tx + tw, ty + th], fill=(31, 31, 31), outline=(65, 65, 65), width=1)
            draw.rectangle([tx + 10, ty + 12, tx + 32, ty + 30], fill=(0, 120, 215))
            draw.text((tx + 40, ty + 10), "Параметры экрана", fill=(255, 255, 255))
            draw.text((tx + 40, ty + 28), "Видеодрайвер NVIDIA Windows Kernel Mode\nDriver перестал отвечать и был успешно\nвосстановлен.", fill=(195, 195, 195))
            self.tdr_toast_timer -= 1

        # Memory Error
        if self.mem_error_active:
            draw = ImageDraw.Draw(img)
            mw, mh = 360, 130
            mx = (out_w - mw) // 2
            my = (out_h - mh) // 2
            draw.rectangle([mx, my, mx + mw, my + mh], fill=(240, 240, 240), outline=(120, 120, 120), width=1)
            draw.rectangle([mx, my, mx + mw, my + 24], fill=(255, 255, 255))
            draw.text((mx + 8, my + 5), "explorer.exe - Ошибка приложения", fill=(0, 0, 0))
            draw.ellipse([mx + 14, my + 40, mx + 42, my + 68], fill=(210, 30, 30))
            draw.text((mx + 22, my + 44), "X", fill=(255, 255, 255))
            draw.text((mx + 52, my + 38), "Инструкция по адресу 0x00007FF63B48\nобратилась к памяти по адресу 0x00000000.\nПамять не может быть \"read\".", fill=(0, 0, 0))
            draw.rectangle([mx + mw - 85, my + mh - 30, mx + mw - 14, my + mh - 10], fill=(225, 225, 225), outline=(160, 160, 160))
            draw.text((mx + mw - 58, my + mh - 26), "ОК", fill=(0, 0, 0))

        # 1. Pop-up Ads
        spawn_rate = self.v_ad_rate_var.get()
        max_ads = self.v_ad_max_var.get()
        if spawn_rate > 0 and len(self.live_active_ads) < max_ads:
            if random.randint(1, 100) <= spawn_rate:
                ad_im = random.choice(self.cached_ads).copy() if self.cached_ads else self.make_fallback_ad()
                scale = random.uniform(0.16, 0.42)
                dim = max(40, int(min(out_w, out_h) * scale))
                ad_im.thumbnail((dim, dim))
                rx = random.randint(0, max(1, out_w - ad_im.width))
                ry = random.randint(0, max(1, out_h - ad_im.height))
                self.live_active_ads.append({"img": ad_im, "x": rx, "y": ry, "ttl": random.randint(20, 60)})
                if self.v_ad_sound_var.get() and len(self.live_active_ads) % 3 == 1:
                    ShakalAudioEngine.play(random.choice(["usb_disconnect", "win_error", "icq"]))

        if not self.v_ad_accum_var.get():
            for item in self.live_active_ads:
                item["ttl"] -= 1
            self.live_active_ads = [a for a in self.live_active_ads if a["ttl"] > 0]

        shake = self.v_ad_shake_var.get()
        for item in self.live_active_ads:
            ad_im = item["img"]
            jx = item["x"] + (random.randint(-shake, shake) if shake > 0 else 0)
            jy = item["y"] + (random.randint(-shake, shake) if shake > 0 else 0)
            jx = max(0, min(out_w - ad_im.width, jx))
            jy = max(0, min(out_h - ad_im.height, jy))
            img.paste(ad_im.convert("RGB"), (jx, jy), ad_im)

        # 2. Antivirus Popups
        if self.v_rand_av_var.get():
            if self.live_active_av_timer > 0:
                img = self.draw_antivirus(img)
                self.live_active_av_timer -= 1
            elif random.random() < 0.08:
                self.live_active_av_timer = random.randint(8, 20)
                if self.v_ad_sound_var.get():
                    ShakalAudioEngine.play("win_error")

        # 3. Screamer
        is_screamer_frame = False
        if self.prank_screamer_flash:
            is_screamer_frame = True
        elif self.v_scr_extreme_var.get() and random.random() < 0.22:
            is_screamer_frame = True
        elif self.v_rand_scr_var.get() and random.random() < 0.06:
            is_screamer_frame = True

        if is_screamer_frame and self.cached_screamers:
            sc = random.choice(self.cached_screamers).copy()
            scale_f = 1.0 if (self.v_scr_extreme_var.get() or self.prank_screamer_flash) else 0.7
            sc.thumbnail((int(out_w * scale_f), int(out_h * scale_f)))
            if self.v_scr_extreme_var.get() or self.prank_screamer_flash:
                sc = ImageEnhance.Color(sc).enhance(3.5)
            img.paste(sc.convert("RGB"), ((out_w - sc.width) // 2, (out_h - sc.height) // 2), sc)

        # 4. BSOD check
        if self.prank_bsod_active:
            img = self.draw_modern_bsod(img)

        # 5. Datamosh & Tearing
        mosh = self.v_mosh_var.get()
        if mosh > 0:
            for _ in range(int((mosh / 100.0) * 18)):
                bw, bh = random.randint(24, 80), random.randint(16, 48)
                bx, by = random.randint(0, out_w - bw), random.randint(0, out_h - bh)
                blk = img.crop((bx, by, bx + bw, by + bh))
                img.paste(blk, (max(0, min(out_w - bw, bx + random.randint(-30, 30))), max(0, min(out_h - bh, by + random.randint(-20, 25)))))

        tear = self.v_tear_var.get()
        if tear > 0:
            for _ in range(int((tear / 100.0) * 15)):
                sy = random.randint(0, out_h - 12)
                sh = random.randint(3, 12)
                strip = img.crop((0, sy, out_w, sy + sh))
                img.paste(ImageChops.offset(strip, random.randint(-60, 60), 0), (0, sy))

        # 6. CRT & Invert
        crt_v = self.v_crt_var.get()
        if crt_v > 0:
            img = self.draw_crt_scanlines(img, crt_v)

        if self.v_invert_var.get():
            img = ImageOps.invert(img)

        # 7. RGB Shift & Deep-Fry
        rgb_v = self.v_rgb_var.get()
        if rgb_v > 0:
            r, g, b = img.split()
            shift = random.randint(-rgb_v, rgb_v)
            img = Image.merge("RGB", (ImageChops.offset(r, shift, 0), g, ImageChops.offset(b, -shift, 0)))

        fry_v = self.v_fry_var.get()
        if fry_v > 1.0:
            img = ImageEnhance.Color(img).enhance(fry_v * 1.25)
            img = ImageEnhance.Contrast(img).enhance(fry_v)

        # 8. Burn-In Ghosting
        burn_pct = self.v_burn_var.get()
        if burn_pct > 0 and self.live_prev_burn_img is not None:
            alpha = min(0.92, (burn_pct / 100.0) * 0.88)
            img = Image.blend(img, self.live_prev_burn_img, alpha)
        self.live_prev_burn_img = img.copy()

        # 9. Resolution Crush (P-Quality contrast)
        p_val = max(72, min(NATIVE_H, self.v_res_var.get()))
        if p_val < NATIVE_H:
            aspect = out_w / float(out_h)
            cw = max(24, int(p_val * aspect))
            ch = p_val
            img = img.resize((cw, ch), Image.Resampling.BILINEAR).resize((out_w, out_h), Image.Resampling.NEAREST)

        img = self.apply_video_watermark(img)

        # JPEG Compression
        vq = max(1, min(100, self.v_q_var.get()))
        if vq < 90:
            buf = io.BytesIO()
            img.save(buf, format="JPEG", quality=vq)
            buf.seek(0)
            img = Image.open(buf).convert("RGB")

        return img

    # =========================================================================
    #                         PRANK HOT-TRIGGERS
    # =========================================================================
    def trigger_prank_screamer(self):
        ShakalAudioEngine.play("screamer_ear_rape")
        self.prank_screamer_flash = True
        self.screamer_img_var.set(True)
        self.scr_extreme_var.set(True)
        self.chk_scr.sync()
        self.chk_scr_ext.sync()
        self.status_var.set("Скример брошен на экран с криком")

        def _revert():
            self.prank_screamer_flash = False
            self.screamer_img_var.set(False)
            self.scr_extreme_var.set(False)
            self.chk_scr.sync()
            self.chk_scr_ext.sync()
        self.root.after(2000, _revert)

    def trigger_prank_bsod(self):
        ShakalAudioEngine.play("win_error")
        self.prank_bsod_active = True
        self.bsod_var.set(True)
        self.bsod_glitch_var.set(True)
        self.chk_bsod.sync()
        self.chk_bsod_glitch.sync()
        self.status_var.set("Синий экран смерти активирован")

        def _revert():
            self.prank_bsod_active = False
            self.bsod_var.set(False)
            self.bsod_glitch_var.set(False)
            self.chk_bsod.sync()
            self.chk_bsod_glitch.sync()
        self.root.after(4000, _revert)

    def trigger_prank_ads(self):
        ShakalAudioEngine.play("win_error")
        self.ads_var.set(100)
        self.ctrl_ads.update_entry()
        self.ctrl_ads.scale.set(100)

        if self.cached_ads:
            for _ in range(35):
                ad_im = random.choice(self.cached_ads).copy()
                ad_im.thumbnail((120, 120))
                self.live_active_ads.append({"img": ad_im, "x": random.randint(0, 800), "y": random.randint(0, 420), "ttl": 80})

        self.status_var.set("Атака рекламных баннеров активирована")

        def _revert():
            self.ads_var.set(10)
            self.ctrl_ads.update_entry()
            self.ctrl_ads.scale.set(10)
        self.root.after(5000, _revert)

    def test_extreme_sound(self):
        choice = random.choice(["screamer_ear_rape", "bass_drop", "screamer"])
        ShakalAudioEngine.play(choice)
        self.status_var.set(f"Проверка звука: {choice}")

    def randomize_everything(self):
        self.global_res_var.set(random.randint(20, 95))
        self.q_var.set(random.randint(5, 70))
        self.pix_var.set(random.randint(1, 15))
        self.fry_var.set(round(random.uniform(1.2, 5.0), 1))
        self.sharp_var.set(random.randint(1, 15))
        self.rgb_var.set(random.randint(0, 50))
        self.datamosh_var.set(random.randint(0, 80))
        self.swirl_var.set(random.randint(0, 70))
        self.bitcrush_var.set(random.randint(0, 60))
        self.crt_var.set(random.randint(0, 70))
        self.jitter_var.set(random.randint(0, 50))
        self.vignette_var.set(random.randint(0, 60))
        self.vhs_tracking_var.set(random.randint(0, 60))
        self.invert_var.set(random.random() < 0.25)
        self.solarize_var.set(random.random() < 0.25)
        self.art_var.set(random.randint(0, 30000))
        self.ads_var.set(random.randint(0, 50))
        self.noise_var.set(random.randint(0, 40))
        self.matrix_lines_var.set(random.random() < 0.4)
        self.dead_pixels_var.set(random.random() < 0.4)
        self.cursor_trail_var.set(random.random() < 0.3)
        self.win_activate_var.set(random.random() < 0.3)
        self.antivirus_alert_var.set(random.random() < 0.35)
        self.bsod_var.set(random.random() < 0.2)
        self.screamer_img_var.set(random.random() < 0.25)
        self.sound_choice_var.set(random.choice(["camera", "win_error", "usb_disconnect", "screamer", "screamer_ear_rape", "bass_drop"]))

        if hasattr(self, "scale_master_res"):
            self.scale_master_res.set(res_v)
        if hasattr(self, "scale_v_res"):
            self.scale_v_res.set(res_v)
        self.update_master_res_label()
        self.update_v_res_label()

        if hasattr(self, "v_fps_var"):
            self.v_mosh_var.set(d.get("datamosh", 0))
            self.v_rgb_var.set(d.get("rgb", 0))
            self.v_fry_var.set(d.get("fry", 1.0))
            self.v_crt_var.set(d.get("crt", 0))
            self.v_invert_var.set(d.get("invert", False))

        for s in [self.ctrl_q, self.ctrl_pix, self.ctrl_fry, self.ctrl_sharp, self.ctrl_rgb,
                  self.ctrl_datamosh, self.ctrl_swirl, self.ctrl_bitcrush, self.ctrl_crt,
                  self.ctrl_jitter, self.ctrl_vignette, self.ctrl_vhs,
                  self.ctrl_art, self.ctrl_ads, self.ctrl_ad_alpha, self.ctrl_noise, self.ctrl_delay]:
            s.update_entry()
            s.scale.set(s.var.get())
        for c in [self.chk_invert, self.chk_solarize, self.chk_matrix, self.chk_dead, self.chk_cursor, self.chk_activate,
                  self.chk_anti, self.chk_bsod, self.chk_bsod_glitch, self.chk_scr, self.chk_scr_ext]:
            c.sync()
        self.menu_sound.lbl.config(text=self.menu_sound.get_text())
        self.status_var.set("Рандомизация активирована")

    # =========================================================================
    #                         VIDEO RECORDING ENGINE
    # =========================================================================
    def update_v_res_label(self, *args):
        pct = max(3, min(100, self.v_res_var.get()))
        tw = max(32, int(NATIVE_W * (pct / 100.0)))
        th = max(24, int(NATIVE_H * (pct / 100.0)))
        self.lbl_v_res.config(text=f"Качество видео: {tw}x{th} при {pct}%")

    def pick_video_folder(self):
        chosen = filedialog.askdirectory(initialdir=self.video_save_dir)
        if chosen:
            self.video_save_dir = os.path.abspath(chosen)
            self.lbl_v_save_dir.config(text=f"Папка: {os.path.basename(self.video_save_dir) or self.video_save_dir}")

    def on_video_preset_picked(self, name):
        if name == "Стандартный Шакал":
            self.v_res_var.set(45)
            self.v_fps_var.set(15)
            self.v_q_var.set(30)
            self.v_burn_var.set(30)
            self.v_fry_var.set(1.3)
            self.v_stutter_var.set(15)
            self.v_ad_rate_var.set(30)
            self.v_ad_max_var.set(25)
            self.v_bass_var.set(35)
            self.v_clip_var.set(25)
            self.v_drop_var.set(15)
            self.v_rand_scr_var.set(False)
            self.v_scr_extreme_var.set(False)
        elif name == "ЭКСТРИМ ВИДЕО: Инфаркт":
            self.v_res_var.set(65)
            self.v_fps_var.set(240)
            self.v_q_var.set(20)
            self.v_burn_var.set(40)
            self.v_fry_var.set(3.4)
            self.v_stutter_var.set(40)
            self.v_ad_rate_var.set(80)
            self.v_ad_max_var.set(80)
            self.v_rand_scr_var.set(True)
            self.v_scr_extreme_var.set(True)
            self.v_screamer_vol_var.set(280)
            self.v_bass_var.set(90)
            self.v_clip_var.set(85)
            self.v_drop_var.set(50)
            self.v_bit_var.set(60)
            self.v_end_bsod_var.set(True)
        elif name == "ЭКСТРИМ ВИДЕО: Взрыв Перепонок":
            self.v_res_var.set(50)
            self.v_fps_var.set(60)
            self.v_q_var.set(15)
            self.v_burn_var.set(70)
            self.v_fry_var.set(4.0)
            self.v_bass_var.set(100)
            self.v_clip_var.set(100)
            self.v_drop_var.set(45)
            self.v_bit_var.set(80)
            self.v_hum_var.set(60)
            self.v_mosh_var.set(60)
            self.v_tear_var.set(75)
        elif name == "ЭКСТРИМ ВИДЕО: Рекламный Ад и Вирусы":
            self.v_res_var.set(45)
            self.v_fps_var.set(30)
            self.v_q_var.set(25)
            self.v_burn_var.set(40)
            self.v_fry_var.set(1.5)
            self.v_stutter_var.set(30)
            self.v_ad_rate_var.set(95)
            self.v_ad_max_var.set(180)
            self.v_ad_accum_var.set(True)
            self.v_rand_av_var.set(True)
        elif name == "ЭКСТРИМ ВИДЕО: Агония Матрицы":
            self.v_res_var.set(35)
            self.v_fps_var.set(120)
            self.v_q_var.set(10)
            self.v_burn_var.set(85)
            self.v_fry_var.set(3.5)
            self.v_mosh_var.set(85)
            self.v_tear_var.set(90)
            self.v_end_bsod_var.set(True)
            self.v_bass_var.set(70)
        elif name == "HyperCam 2007":
            self.v_res_var.set(30)
            self.v_fps_var.set(4)
            self.v_q_var.set(15)
            self.v_burn_var.set(15)
            self.v_fry_var.set(1.2)
            self.v_wm_var.set("hypercam")
            self.menu_v_wm.lbl.config(text="Unregistered HyperCam 2")
            self.v_bit_var.set(60)
            self.v_hum_var.set(50)
        elif name == "Выгорание Матрицы OLED":
            self.v_res_var.set(40)
            self.v_fps_var.set(30)
            self.v_q_var.set(20)
            self.v_burn_var.set(90)
            self.v_fry_var.set(2.4)
            self.v_rgb_var.set(20)
        elif name == "VHS Хоррор 1994":
            self.v_res_var.set(45)
            self.v_fps_var.set(24)
            self.v_q_var.set(25)
            self.v_burn_var.set(50)
            self.v_fry_var.set(1.6)
            self.v_crt_var.set(65)
            self.v_tear_var.set(55)
            self.v_wm_var.set("cctv")
            self.menu_v_wm.lbl.config(text="Камера CCTV REC")

        self.update_v_res_label()
        for s in [self.ctrl_v_fps, self.ctrl_v_q, self.ctrl_v_burn, self.ctrl_v_fry,
                  self.ctrl_v_stutter, self.ctrl_v_rgb, self.ctrl_v_mosh, self.ctrl_v_tear,
                  self.ctrl_v_crt, self.ctrl_v_ad_rate, self.ctrl_v_ad_max, self.ctrl_v_ad_shake,
                  self.ctrl_v_bass, self.ctrl_v_clip, self.ctrl_v_drop, self.ctrl_v_bit, self.ctrl_v_hum, self.ctrl_v_scr_vol]:
            s.update_entry()
            s.scale.set(s.var.get())
        for c in [self.chk_v_inv, self.chk_v_accum, self.chk_v_adsnd, self.chk_v_av, self.chk_v_scr, self.chk_v_scr_ext, self.chk_v_bsod]:
            c.sync()

    def make_fallback_ad(self):
        ad = Image.new("RGBA", (240, 120), (25, 0, 40, 245))
        d = ImageDraw.Draw(ad)
        d.rectangle([0, 0, 239, 119], outline=(0, 255, 200), width=3)
        d.rectangle([3, 3, 236, 26], fill=(220, 0, 80))
        f_b = get_sys_font(["segoeuib.ttf", "arialbd.ttf"], 11)
        txt = random.choice(["ВЫ ВЫИГРАЛИ ДЕНЬГИ", "СКАЧАТЬ ОЗУ БЕСПЛАТНО", "ВАШ ПК ЗАРАЖЕН", "ОБНОВИТЕ ПЛЕЕР"])
        d.text((8, 6), txt, fill=(255, 255, 255), font=f_b)
        d.rectangle([40, 65, 200, 102], fill=(0, 230, 110), outline=(255, 255, 255), width=2)
        d.text((70, 75), "ЖМИ СЮДА", fill=(0, 0, 0), font=f_b)
        return ad

    def apply_video_watermark(self, img):
        wm = self.v_wm_var.get()
        if wm == "none":
            return img
        draw = ImageDraw.Draw(img)
        w, h = img.size
        if wm == "hypercam":
            f_hc = get_sys_font(["arialbd.ttf", "tahomabd.ttf"], 14)
            draw.rectangle([4, 4, 215, 28], fill=(255, 255, 255), outline=(0, 0, 0), width=1)
            draw.text((10, 7), "Unregistered HyperCam 2", fill=(0, 0, 0), font=f_hc)
        elif wm == "bandicam":
            f_bc = get_sys_font(["arialbd.ttf", "segoeuib.ttf"], 18)
            tx = (w - 190) // 2
            draw.text((tx + 2, 12), "www.Bandicam.com", fill=(0, 0, 0), font=f_bc)
            draw.text((tx, 10), "www.Bandicam.com", fill=(255, 255, 255), font=f_bc)
        elif wm == "fraps":
            f_fr = get_sys_font(["consola.ttf", "impact.ttf", "arialbd.ttf"], 26)
            fps_num = random.randint(1, 7)
            draw.rectangle([8, 8, 56, 42], fill=(0, 0, 0))
            draw.text((14, 8), str(fps_num), fill=(255, 240, 0), font=f_fr)
        elif wm == "cctv":
            f_osd = get_sys_font(["consola.ttf", "courbd.ttf"], 15)
            now_s = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            draw.text((20, 16), f"[CAM 02 - ЗАПИСЬ]  {now_s}", fill=(0, 255, 70), font=f_osd)
            if int(time.time() * 2) % 2 == 0:
                draw.ellipse([w - 120, 18, w - 106, 32], fill=(255, 0, 0))
            draw.text((w - 100, 16), "REC", fill=(255, 30, 30), font=f_osd)
        return img

    def toggle_video_recording(self):
        if not HAS_CV2:
            self.v_status_var.set("Ошибка: opencv-python не найден")
            return
        if not self.is_recording_video:
            self.is_recording_video = True
            self.btn_v_record.config(text="ОСТАНОВИТЬ И СОХРАНИТЬ ВИДЕО", bg=THEME["accent_rose"], fg="#ffffff")
            self.v_live_badge.config(text="ИДЕТ ЗАПИСЬ", fg=THEME["accent_rose"])
            threading.Thread(target=self._video_record_worker, daemon=True).start()
        else:
            self.is_recording_video = False
            self.v_status_var.set("Финализация и кодирование звука...")

    def _video_record_worker(self):
        try:
            fps = max(1, min(240, self.v_fps_var.get()))
            max_sec = max(3, min(120, self.v_limit_sec_var.get()))
            out_w, out_h = 960, 540

            os.makedirs(self.video_save_dir, exist_ok=True)
            t_stamp = datetime.now().strftime('%Y%m%d_%H%M%S')
            raw_video_path = os.path.join(self.video_save_dir, f"temp_v_{t_stamp}.mp4")
            final_save_path = os.path.join(self.video_save_dir, f"shakal_video_{t_stamp}.mp4")

            fourcc = cv2.VideoWriter_fourcc(*"mp4v")
            writer = cv2.VideoWriter(raw_video_path, fourcc, float(fps), (out_w, out_h))

            record_audio = self.v_audio_enable_var.get() and HAS_SOUNDDEVICE
            audio_chunks = []
            audio_stream = None
            screamer_timestamps = []

            if record_audio:
                try:
                    def _audio_callback(indata, frames, time_info, status):
                        if self.is_recording_video:
                            audio_chunks.append(indata.copy())
                    audio_stream = sd.InputStream(samplerate=ShakalAudioEngine.SAMPLE_RATE, channels=1, callback=_audio_callback)
                    audio_stream.start()
                except Exception:
                    audio_stream = None

            active_ads = []
            active_av_timer = 0
            prev_burn_img = None
            frozen_frame = None
            freeze_counter = 0

            start_t = time.time()
            frame_idx = 0

            while self.is_recording_video and (time.time() - start_t) < max_sec:
                loop_t = time.time()

                stutter_chance = self.v_stutter_var.get() / 100.0
                if freeze_counter > 0 and frozen_frame is not None:
                    freeze_counter -= 1
                    frame_bgr = frozen_frame
                else:
                    raw = ImageGrab.grab().convert("RGB")
                    img = raw.resize((out_w, out_h), Image.Resampling.BILINEAR)

                    # Pop-up Ads
                    spawn_rate = self.v_ad_rate_var.get()
                    max_ads = self.v_ad_max_var.get()
                    if spawn_rate > 0 and len(active_ads) < max_ads:
                        if random.randint(1, 100) <= spawn_rate:
                            ad_im = random.choice(self.cached_ads).copy() if self.cached_ads else self.make_fallback_ad()
                            scale = random.uniform(0.16, 0.42)
                            dim = max(40, int(min(out_w, out_h) * scale))
                            ad_im.thumbnail((dim, dim))
                            rx = random.randint(0, max(1, out_w - ad_im.width))
                            ry = random.randint(0, max(1, out_h - ad_im.height))
                            active_ads.append({"img": ad_im, "x": rx, "y": ry, "ttl": random.randint(15, 45)})
                            if self.v_ad_sound_var.get() and len(active_ads) % 3 == 1:
                                ShakalAudioEngine.play(random.choice(["usb_disconnect", "win_error", "icq"]))

                    if not self.v_ad_accum_var.get():
                        for item in active_ads:
                            item["ttl"] -= 1
                        active_ads = [a for a in active_ads if a["ttl"] > 0]

                    shake = self.v_ad_shake_var.get()
                    for item in active_ads:
                        ad_im = item["img"]
                        jx = item["x"] + (random.randint(-shake, shake) if shake > 0 else 0)
                        jy = item["y"] + (random.randint(-shake, shake) if shake > 0 else 0)
                        jx = max(0, min(out_w - ad_im.width, jx))
                        jy = max(0, min(out_h - ad_im.height, jy))
                        img.paste(ad_im.convert("RGB"), (jx, jy), ad_im)

                    # Antivirus Popups
                    if self.v_rand_av_var.get():
                        if active_av_timer > 0:
                            img = self.draw_antivirus(img)
                            active_av_timer -= 1
                        elif random.random() < 0.08:
                            active_av_timer = random.randint(8, 20)
                            if self.v_ad_sound_var.get():
                                ShakalAudioEngine.play("win_error")

                    # Screamer
                    is_screamer_frame = False
                    if self.v_scr_extreme_var.get() and random.random() < 0.22:
                        is_screamer_frame = True
                    elif self.v_rand_scr_var.get() and random.random() < 0.06:
                        is_screamer_frame = True

                    if is_screamer_frame and self.cached_screamers:
                        sc = random.choice(self.cached_screamers).copy()
                        scale_f = 1.0 if self.v_scr_extreme_var.get() else 0.7
                        sc.thumbnail((int(out_w * scale_f), int(out_h * scale_f)))
                        if self.v_scr_extreme_var.get():
                            sc = ImageEnhance.Color(sc).enhance(3.5)
                        img.paste(sc.convert("RGB"), ((out_w - sc.width) // 2, (out_h - sc.height) // 2), sc)
                        screamer_timestamps.append(time.time() - start_t)
                        if self.v_ad_sound_var.get() and random.random() < 0.35:
                            ShakalAudioEngine.play("screamer_ear_rape" if self.v_scr_extreme_var.get() else "screamer")

                    # Datamosh & Tearing
                    mosh = self.v_mosh_var.get()
                    if mosh > 0:
                        for _ in range(int((mosh / 100.0) * 18)):
                            bw, bh = random.randint(24, 80), random.randint(16, 48)
                            bx, by = random.randint(0, out_w - bw), random.randint(0, out_h - bh)
                            blk = img.crop((bx, by, bx + bw, by + bh))
                            img.paste(blk, (max(0, min(out_w - bw, bx + random.randint(-30, 30))), max(0, min(out_h - bh, by + random.randint(-20, 25)))))

                    tear = self.v_tear_var.get()
                    if tear > 0:
                        for _ in range(int((tear / 100.0) * 15)):
                            sy = random.randint(0, out_h - 12)
                            sh = random.randint(3, 12)
                            strip = img.crop((0, sy, out_w, sy + sh))
                            img.paste(ImageChops.offset(strip, random.randint(-60, 60), 0), (0, sy))

                    # CRT Scanlines & Invert
                    crt_v = self.v_crt_var.get()
                    if crt_v > 0:
                        img = self.draw_crt_scanlines(img, crt_v)

                    if self.v_invert_var.get():
                        img = ImageOps.invert(img)

                    # RGB Shift & Deep-Fry
                    rgb_v = self.v_rgb_var.get()
                    if rgb_v > 0:
                        r, g, b = img.split()
                        shift = random.randint(-rgb_v, rgb_v)
                        img = Image.merge("RGB", (ImageChops.offset(r, shift, 0), g, ImageChops.offset(b, -shift, 0)))

                    fry_v = self.v_fry_var.get()
                    if fry_v > 1.0:
                        img = ImageEnhance.Color(img).enhance(fry_v * 1.25)
                        img = ImageEnhance.Contrast(img).enhance(fry_v)

                    # Burn-In Ghosting
                    burn_pct = self.v_burn_var.get()
                    if burn_pct > 0 and prev_burn_img is not None:
                        alpha = min(0.92, (burn_pct / 100.0) * 0.88)
                        img = Image.blend(img, prev_burn_img, alpha)
                    prev_burn_img = img.copy()

                    # Resolution Crush
                    res_pct = max(3, min(100, self.v_res_var.get()))
                    if res_pct < 100:
                        cw = max(24, int(out_w * (res_pct / 100.0)))
                        ch = max(18, int(out_h * (res_pct / 100.0)))
                        img = img.resize((cw, ch), Image.Resampling.BILINEAR).resize((out_w, out_h), Image.Resampling.NEAREST)

                    img = self.apply_video_watermark(img)

                    # JPEG Compression
                    vq = max(1, min(100, self.v_q_var.get()))
                    if vq < 90:
                        buf = io.BytesIO()
                        img.save(buf, format="JPEG", quality=vq)
                        buf.seek(0)
                        img = Image.open(buf).convert("RGB")

                    frame_bgr = cv2.cvtColor(np.array(img), cv2.COLOR_RGB2BGR)

                    if stutter_chance > 0 and random.random() < (stutter_chance * 0.25):
                        frozen_frame = frame_bgr
                        freeze_counter = random.randint(2, max(3, fps // 2))

                writer.write(frame_bgr)
                frame_idx += 1
                elapsed = int(time.time() - start_t)
                self.root.after(0, lambda e=elapsed, f=frame_idx, a=len(active_ads): self.v_status_var.set(f"Запись: {e} сек | Кадров: {f} | FPS: {fps} | Реклам: {a}"))

                sleep_dt = max(0.001, (1.0 / fps) - (time.time() - loop_t))
                time.sleep(sleep_dt)

            if self.v_end_bsod_var.get():
                ShakalAudioEngine.play("win_error")
                bsod_img = self.draw_modern_bsod(Image.new("RGB", (out_w, out_h), (0, 0, 0)))
                bsod_bgr = cv2.cvtColor(np.array(bsod_img), cv2.COLOR_RGB2BGR)
                for _ in range(int(fps * 1.5)):
                    writer.write(bsod_bgr)

            writer.release()

            if audio_stream:
                try:
                    audio_stream.stop()
                    audio_stream.close()
                except Exception:
                    pass

            total_duration = time.time() - start_t
            audio_settings = {
                "bass_boost": self.v_bass_var.get(),
                "hard_clip": self.v_clip_var.get(),
                "dropouts": self.v_drop_var.get(),
                "bitcrush": self.v_bit_var.get(),
                "mic_hum": self.v_hum_var.get(),
                "screamer_vol": self.v_screamer_vol_var.get()
            }

            final_audio_pcm = None
            if audio_chunks:
                try:
                    raw_audio = np.concatenate(audio_chunks, axis=0)
                    final_audio_pcm = ShakalAudioEngine.process_shakal_audio(raw_audio, audio_settings, screamer_timestamps)
                except Exception:
                    final_audio_pcm = None

            if final_audio_pcm is None and self.v_audio_enable_var.get():
                sr = ShakalAudioEngine.SAMPLE_RATE
                num_samps = int(sr * total_duration)
                synth = np.zeros(num_samps, dtype=np.float32)
                final_audio_pcm = ShakalAudioEngine.process_shakal_audio(synth, audio_settings, screamer_timestamps)

            if final_audio_pcm is not None and FFMPEG_EXE and os.path.exists(raw_video_path):
                temp_wav = os.path.join(self.video_save_dir, f"temp_a_{t_stamp}.wav")
                wavfile.write(temp_wav, ShakalAudioEngine.SAMPLE_RATE, (final_audio_pcm * 32767).astype(np.int16))

                cmd = [
                    FFMPEG_EXE, "-y", "-i", raw_video_path, "-i", temp_wav,
                    "-c:v", "copy", "-c:a", "aac", "-b:a", "128k", "-shortest",
                    final_save_path
                ]
                subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

                try:
                    os.remove(raw_video_path)
                    os.remove(temp_wav)
                except Exception:
                    pass
            else:
                if os.path.exists(raw_video_path):
                    if os.path.exists(final_save_path):
                        os.remove(final_save_path)
                    os.rename(raw_video_path, final_save_path)

            self.is_recording_video = False

            def _finish_ui():
                self.btn_v_record.config(text="НАЧАТЬ ЗАПИСЬ ВИДЕО", bg=THEME["accent_rose"], fg="#ffffff")
                self.v_live_badge.config(text="СОХРАНЕНО", fg=THEME["accent_blue"])
                self.v_status_var.set(f"Видео сохранено: {os.path.basename(final_save_path)}")
                if self.v_open_after_var.get() and os.path.exists(final_save_path):
                    os.startfile(final_save_path)

            self.root.after(0, _finish_ui)
        except Exception as e:
            self.is_recording_video = False
            self.root.after(0, lambda err=e: self.v_status_var.set(f"Ошибка видео: {err}"))

    # =========================================================================
    #                         PRESETS & CONFIG
    # =========================================================================
    def load_custom_presets(self):
        if os.path.exists(PRESETS_FILE):
            try:
                with open(PRESETS_FILE, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception:
                return {}
        return {}

    def save_current_as_preset(self):
        name = self.entry_preset_name.get().strip()
        if not name:
            return
        state = {
            "res": self.global_res_var.get(),
            "q": self.q_var.get(),
            "pix": self.pix_var.get(),
            "fry": self.fry_var.get(),
            "sharp": self.sharp_var.get(),
            "rgb": self.rgb_var.get(),
            "datamosh": self.datamosh_var.get(),
            "dialup": self.dialup_var.get(),
            "fisheye": self.fisheye_var.get(),
            "xp_drag": self.xp_drag_var.get(),
            "ads": self.ads_var.get(),
            "ad_alpha": self.ad_alpha_var.get(),
            "art": self.art_var.get(),
            "noise": self.noise_var.get(),
            "matrix": self.matrix_lines_var.get(),
            "dead": self.dead_pixels_var.get(),
            "cursor": self.cursor_trail_var.get(),
            "win_act": self.win_activate_var.get(),
            "anti": self.antivirus_alert_var.get(),
            "av_type": self.av_type_var.get(),
            "bsod": self.bsod_var.get(),
            "bsod_glitch": self.bsod_glitch_var.get(),
            "scr": self.screamer_img_var.get(),
            "scr_extreme": self.scr_extreme_var.get(),
            "swirl": self.swirl_var.get(),
            "invert": self.invert_var.get(),
            "solarize": self.solarize_var.get(),
            "crt": self.crt_var.get(),
            "jitter": self.jitter_var.get(),
            "vignette": self.vignette_var.get(),
            "vhs_tracking": self.vhs_tracking_var.get(),
            "bitcrush": self.bitcrush_var.get(),
            "sound": self.sound_choice_var.get()
        }
        self.custom_presets[name] = state
        try:
            with open(PRESETS_FILE, "w", encoding="utf-8") as f:
                json.dump(self.custom_presets, f, ensure_ascii=False, indent=2)
        except Exception:
            pass

        if name not in self.preset_options:
            self.preset_options.append(name)
        self.menu_presets.options = self.preset_options
        self.menu_presets.display_names = {o: o for o in self.preset_options}
        self.selected_preset_var.set(name)
        self.menu_presets.lbl.config(text=name)
        self.entry_preset_name.delete(0, tk.END)
        self.status_var.set(f"Пресет {name} сохранен")

    def on_preset_picked(self, name):
        if name == "Сброс":
            self.apply_preset_dict({
                "res": NATIVE_H, "q": 85, "pix": 1, "fry": 1.0, "sharp": 1, "rgb": 0, "datamosh": 0,
                "dialup": 0, "fisheye": 0, "xp_drag": 0, "ads": 0, "ad_alpha": 90, "art": 0,
                "noise": 0, "matrix": False, "dead": False, "cursor": False, "win_act": False,
                "anti": False, "av_type": "random", "bsod": False, "bsod_glitch": False, "scr": False,
                "scr_extreme": False, "swirl": 0, "invert": False, "solarize": False, "crt": 0,
                "jitter": 0, "vignette": 0, "vhs_tracking": 0, "bitcrush": 0, "sound": "camera",
                "ghost_windows": 0, "gpu_artifacts": 0
            })
            self.stop_all_prank_streams()
            self.status_var.set("Настройки сброшены")
        elif name in ("🛡️ Чит-Проверка: Сбой Windows и Видеокарты", "Проверка на читы"):
            self.apply_cheat_check_preset()
        elif name in self.custom_presets:
            self.apply_preset_dict(self.custom_presets[name])
            self.status_var.set(f"Пресет {name} применен")

    def apply_preset_dict(self, d):
        res_v = d.get("res", NATIVE_H)
        if res_v <= 100:
            res_v = max(72, int((res_v / 100.0) * NATIVE_H))
        self.global_res_var.set(res_v)
        self.v_res_var.set(res_v)
        self.ghost_windows_var.set(d.get("ghost_windows", 0))
        self.v_ghost_var.set(d.get("ghost_windows", 0))
        self.gpu_art_var.set(d.get("gpu_artifacts", 0))
        self.v_gpu_art_var.set(d.get("gpu_artifacts", 0))
        self.q_var.set(d.get("q", 70))
        self.pix_var.set(d.get("pix", 1))
        self.fry_var.set(d.get("fry", 1.1))
        self.sharp_var.set(d.get("sharp", 1))
        self.rgb_var.set(d.get("rgb", 0))
        self.datamosh_var.set(d.get("datamosh", 0))
        self.dialup_var.set(d.get("dialup", 0))
        self.fisheye_var.set(d.get("fisheye", 0))
        self.xp_drag_var.set(d.get("xp_drag", 0))
        self.ads_var.set(d.get("ads", 10))
        self.ad_alpha_var.set(d.get("ad_alpha", 90))
        self.art_var.set(d.get("art", 0))
        self.noise_var.set(d.get("noise", 0))
        self.matrix_lines_var.set(d.get("matrix", False))
        self.dead_pixels_var.set(d.get("dead", False))
        self.cursor_trail_var.set(d.get("cursor", False))
        self.win_act = d.get("win_act", False)
        self.win_activate_var.set(self.win_act)
        self.antivirus_alert_var.set(d.get("anti", False))
        self.av_type_var.set(d.get("av_type", "random"))
        self.bsod_var.set(d.get("bsod", False))
        self.bsod_glitch_var.set(d.get("bsod_glitch", False))
        self.screamer_img_var.set(d.get("scr", False))
        self.scr_extreme_var.set(d.get("scr_extreme", False))
        self.swirl_var.set(d.get("swirl", 0))
        self.invert_var.set(d.get("invert", False))
        self.solarize_var.set(d.get("solarize", False))
        self.crt_var.set(d.get("crt", 0))
        self.jitter_var.set(d.get("jitter", 0))
        self.vignette_var.set(d.get("vignette", 0))
        self.vhs_tracking_var.set(d.get("vhs_tracking", 0))
        self.bitcrush_var.set(d.get("bitcrush", 0))
        self.sound_choice_var.set(d.get("sound", "usb_disconnect"))

        self.update_master_res_label()
        for s in [self.ctrl_q, self.ctrl_pix, self.ctrl_fry, self.ctrl_sharp, self.ctrl_rgb,
                  self.ctrl_datamosh, self.ctrl_swirl, self.ctrl_bitcrush, self.ctrl_crt,
                  self.ctrl_jitter, self.ctrl_vignette, self.ctrl_vhs,
                  self.ctrl_dialup, self.ctrl_fisheye, self.ctrl_xp_drag,
                  self.ctrl_ads, self.ctrl_ad_alpha, self.ctrl_art, self.ctrl_noise, self.ctrl_delay,
                  self.ctrl_ghost, self.ctrl_gpu_art, self.ctrl_v_ghost, self.ctrl_v_gpu]:
            s.update_entry()
            s.scale.set(s.var.get())
        for c in [self.chk_invert, self.chk_solarize, self.chk_matrix, self.chk_dead, self.chk_cursor, self.chk_activate,
                  self.chk_anti, self.chk_bsod, self.chk_bsod_glitch, self.chk_scr, self.chk_scr_ext]:
            c.sync()
        self.menu_sound.lbl.config(text=self.menu_sound.get_text())
        self.menu_av.lbl.config(text=self.menu_av.get_text())

    def update_master_res_label(self, *args):
        val = max(72, min(NATIVE_H, self.global_res_var.get()))
        aspect = NATIVE_W / float(NATIVE_H)
        tw = max(32, int(val * aspect))
        th = val
        self.lbl_master_res.config(text=f"Качество: {th}p — {tw}x{th}")

    def update_v_res_label(self, *args):
        val = max(72, min(NATIVE_H, self.v_res_var.get()))
        aspect = NATIVE_W / float(NATIVE_H)
        tw = max(32, int(val * aspect))
        th = val
        self.lbl_v_res.config(text=f"Качество: {th}p — {tw}x{th}")

    def pick_save_folder(self):
        chosen = filedialog.askdirectory(initialdir=self.save_dir)
        if chosen:
            self.save_dir = os.path.abspath(chosen)
            self.lbl_save_dir.config(text=f"Папка: {os.path.basename(self.save_dir) or self.save_dir}")

    def reload_media(self):
        valid = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}
        self.cached_ads = []
        for f in os.listdir(DIRS["ads"]):
            if os.path.splitext(f)[1].lower() in valid:
                try:
                    with Image.open(os.path.join(DIRS["ads"], f)) as im:
                        self.cached_ads.append(im.convert("RGBA"))
                except Exception:
                    pass

        self.cached_screamers = []
        for f in os.listdir(DIRS["screamers"]):
            if os.path.splitext(f)[1].lower() in valid:
                try:
                    with Image.open(os.path.join(DIRS["screamers"], f)) as im:
                        self.cached_screamers.append(im.convert("RGBA"))
                except Exception:
                    pass

    # =========================================================================
    #                         DISTORTION FILTERS & PIPELINE
    # =========================================================================
    def draw_crt_scanlines(self, img, strength):
        if strength <= 0:
            return img
        arr = np.array(img)
        alpha = (strength / 100.0) * 0.75
        arr[::2] = (arr[::2] * (1.0 - alpha)).astype(np.uint8)
        return Image.fromarray(arr)

    def draw_jitter(self, img, strength):
        if strength <= 0:
            return img
        shift = max(1, int((strength / 100.0) * 16))
        arr = np.array(img)
        arr[1::2] = np.roll(arr[1::2], shift, axis=1)
        return Image.fromarray(arr)

    def draw_vignette(self, img, strength):
        if strength <= 0:
            return img
        w, h = img.size
        arr = np.array(img, dtype=np.float32)
        Y, X = np.ogrid[:h, :w]
        cy, cx = h / 2.0, w / 2.0
        dist = np.sqrt(((X - cx) / cx)**2 + ((Y - cy) / cy)**2)
        vig = 1.0 - np.clip((dist - 0.35) * (strength / 100.0) * 1.3, 0, 0.88)
        arr = arr * vig[:, :, np.newaxis]
        return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))

    def draw_vhs_tracking(self, img, strength):
        if strength <= 0:
            return img
        w, h = img.size
        arr = np.array(img)
        band_h = max(4, int(h * 0.08 * (strength / 100.0)))
        y_start = max(0, h - band_h - random.randint(0, max(1, int(h * 0.04))))
        y_end = min(h, y_start + band_h)
        if y_end > y_start:
            noise = np.random.randint(0, 256, (y_end - y_start, w, 3), dtype=np.uint8)
            arr[y_start:y_end] = (arr[y_start:y_end] * 0.3 + noise * 0.7).astype(np.uint8)
            roll_amt = random.randint(-40, 40)
            arr[y_start:y_end] = np.roll(arr[y_start:y_end], roll_amt, axis=1)
        return Image.fromarray(arr)

    def draw_bitcrush(self, img, strength):
        if strength <= 0:
            return img
        bits = max(1, min(7, int(8 - (strength / 100.0) * 7)))
        return ImageOps.posterize(img, bits)

    def draw_swirl(self, img, strength):
        if strength <= 0:
            return img
        w, h = img.size
        sw, sh = max(64, int(w * 0.5)), max(64, int(h * 0.5))
        small = img.resize((sw, sh), Image.Resampling.BILINEAR)
        arr = np.array(small)
        cy, cx = sh / 2.0, sw / 2.0
        y, x = np.ogrid[:sh, :sw]
        dy = (y - cy) / cy
        dx = (x - cx) / cx
        r = np.sqrt(dx * dx + dy * dy)
        angle = np.arctan2(dy, dx)
        k = (strength / 100.0) * 3.6
        swirl_angle = angle + k * (1.0 - np.clip(r, 0, 1.0))
        nx = np.clip(cx + r * np.cos(swirl_angle) * cx, 0, sw - 1).astype(int)
        ny = np.clip(cy + r * np.sin(swirl_angle) * cy, 0, sh - 1).astype(int)
        swirled = arr[ny, nx]
        return Image.fromarray(swirled).resize((w, h), Image.Resampling.BILINEAR)

    def draw_antivirus(self, img):
        w, h = img.size
        draw = ImageDraw.Draw(img)
        kind = self.av_type_var.get()
        if kind == "random":
            kind = random.choice(["kaspersky", "drweb", "defender", "avast", "eset"])

        target_file = get_real_user_path()
        threat_name = random.choice([
            "Trojan-Ransom.Win64.WannaCry.mod", "Backdoor.DarkKoleso.v2", "Rootkit.BootSector.ZeroDay",
            "Exploit.MSIL.Miner.x", "Worm.Win32.Autorun.inf", "HackTool.Win64.KMS.Crack"
        ])

        f_title = get_sys_font(["segoeuib.ttf", "arialbd.ttf"], 12)
        f_body = get_sys_font(["consola.ttf", "tahoma.ttf"], 10)

        if kind == "kaspersky":
            bw, bh = min(w - 20, 520), 160
            bx, by = (w - bw) // 2, random.randint(30, max(31, h // 3))
            draw.rectangle([bx, by, bx + bw, by + bh], fill=(12, 42, 34), outline=(0, 210, 140), width=2)
            draw.rectangle([bx + 2, by + 2, bx + bw - 2, by + 28], fill=(0, 160, 105))
            draw.text((bx + 10, by + 6), "Kaspersky Internet Security — Угроза заблокирована", fill=(255, 255, 255), font=f_title)
            txt = f"Объект: {threat_name}\nПуть: {target_file}\nРезультат: Доступ запрещен. Файл помещен в карантин."
            draw.text((bx + 12, by + 40), txt, fill=(210, 255, 235), font=f_body)
        elif kind == "drweb":
            bw, bh = min(w - 20, 540), 170
            bx, by = (w - bw) // 2, random.randint(40, max(41, h // 3))
            draw.rectangle([bx, by, bx + bw, by + bh], fill=(18, 38, 18), outline=(60, 190, 60), width=2)
            draw.rectangle([bx + 2, by + 2, bx + bw - 2, by + 28], fill=(35, 130, 35))
            draw.text((bx + 10, by + 6), "Dr.Web Security Space — Внимание: обнаружен вирус!", fill=(255, 255, 255), font=f_title)
            txt = f"Действие: Обезвреживание вредоносного ПО\nВирус: {threat_name}\nФайл: {target_file}\nСтатус: Лечение невозможно, объект изолирован."
            draw.text((bx + 12, by + 40), txt, fill=(200, 255, 200), font=f_body)
        elif kind == "defender":
            bw, bh = min(w - 20, 480), 150
            bx, by = max(20, w - bw - 40), max(20, h - bh - 60)
            draw.rectangle([bx, by, bx + bw, by + bh], fill=(24, 28, 38), outline=(0, 120, 215), width=2)
            draw.text((bx + 14, by + 12), "Безопасность Windows", fill=(0, 160, 255), font=f_title)
            txt = f"Обнаружены угрозы: {threat_name}\nУровень опасности: Высокий\nЗатронутые элементы: {target_file}"
            draw.text((bx + 14, by + 45), txt, fill=(220, 225, 235), font=f_body)
        elif kind == "avast":
            bw, bh = min(w - 20, 460), 140
            bx, by = max(20, w - bw - 30), max(20, h - bh - 50)
            draw.rectangle([bx, by, bx + bw, by + bh], fill=(245, 120, 20), outline=(255, 255, 255), width=2)
            draw.text((bx + 12, by + 10), "Avast Free Antivirus", fill=(255, 255, 255), font=f_title)
            txt = f"Угроза успешно заблокирована!\nЗаражение: {threat_name}\nИсточник: {target_file}"
            draw.text((bx + 12, by + 42), txt, fill=(255, 255, 255), font=f_body)
        elif kind == "eset":
            bw, bh = min(w - 20, 500), 155
            bx, by = (w - bw) // 2, random.randint(30, max(31, h // 3))
            draw.rectangle([bx, by, bx + bw, by + bh], fill=(15, 30, 38), outline=(0, 180, 215), width=2)
            draw.rectangle([bx + 2, by + 2, bx + bw - 2, by + 26], fill=(0, 110, 140))
            draw.text((bx + 10, by + 5), "ESET NOD32 Internet Security", fill=(255, 255, 255), font=f_title)
            txt = f"Оповещение системы безопасности\nУгроза: {threat_name}\nОбъект: {target_file}\nИнформация: Соединение прервано."
            draw.text((bx + 12, by + 38), txt, fill=(210, 240, 255), font=f_body)

        return img

    def draw_modern_bsod(self, base_img):
        w, h = base_img.size
        bsod = Image.new("RGB", (w, h), (0, 120, 215))
        draw = ImageDraw.Draw(bsod)

        f_smile = get_sys_font(["segoeui.ttf", "arial.ttf"], int(h * 0.16))
        f_main = get_sys_font(["segoeui.ttf", "arial.ttf"], max(13, int(h * 0.026)))
        f_sub = get_sys_font(["segoeui.ttf", "arial.ttf"], max(10, int(h * 0.018)))

        x, y = int(w * 0.12), int(h * 0.12)
        draw.text((x, y), ":(", fill=(255, 255, 255), font=f_smile)
        y += int(h * 0.22)

        main_text = (
            "На вашем устройстве возникла проблема, и его необходимо перезагрузить.\n"
            "Мы лишь собираем некоторые сведения об ошибке, а затем будет\n"
            "автоматически выполнена перезагрузка."
        )
        draw.text((x, y), main_text, fill=(255, 255, 255), font=f_main)
        y += int(h * 0.16)

        draw.text((x, y), "100% завершено", fill=(255, 255, 255), font=f_main)
        y += int(h * 0.08)

        qr_size = int(h * 0.14)
        draw.rectangle([x, y, x + qr_size, y + qr_size], fill=(255, 255, 255))
        step = max(2, qr_size // 12)
        for qy in range(y + 4, y + qr_size - 4, step):
            for qx in range(x + 4, x + qr_size - 4, step):
                if random.random() > 0.45:
                    draw.rectangle([qx, qy, qx + step - 1, qy + step - 1], fill=(0, 120, 215))

        stop_codes = ["CRITICAL_PROCESS_DIED", "KERNEL_SECURITY_CHECK_FAILURE", "PAGE_FAULT_IN_NONPAGED_AREA", "SYSTEM_SERVICE_EXCEPTION"]
        info_x = x + qr_size + int(w * 0.02)
        sub_text = (
            "Для получения дополнительных сведений об этой проблеме посетите страницу:\n"
            "https://www.windows.com/stopcode\n\n"
            f"Код остановки: {random.choice(stop_codes)}\n"
            "Что вызвало проблему: shakal.sys"
        )
        draw.text((info_x, y), sub_text, fill=(255, 255, 255), font=f_sub)

        if self.bsod_glitch_var.get():
            g_type = random.choice(["tear_half", "mini_corner", "horizontal_slice"])
            if g_type == "tear_half":
                cut_y = random.randint(int(h * 0.35), int(h * 0.65))
                bsod.paste(base_img.crop((0, cut_y, w, h)), (0, cut_y))
            elif g_type == "mini_corner":
                mw, mh = int(w * 0.55), int(h * 0.55)
                small_bsod = bsod.resize((mw, mh), Image.Resampling.BILINEAR)
                res = base_img.copy()
                res.paste(small_bsod, (random.randint(0, w - mw), random.randint(0, h - mh)))
                return res
            elif g_type == "horizontal_slice":
                for _ in range(20):
                    sy = random.randint(0, h - 30)
                    sh = random.randint(6, 25)
                    drift = random.randint(-int(w * 0.3), int(w * 0.3))
                    strip = bsod.crop((0, sy, w, sy + sh))
                    bsod.paste(ImageChops.offset(strip, drift, 0), (0, sy))

        return bsod

    def draw_xp_drag(self, img, steps):
        if steps <= 0:
            return img
        w, h = img.size
        ww, wh = min(360, int(w * 0.4)), 170
        win_box = Image.new("RGB", (ww, wh), (236, 233, 216))
        d = ImageDraw.Draw(win_box)
        d.rectangle([0, 0, ww - 1, 26], fill=(0, 85, 230))
        d.rectangle([ww - 22, 4, ww - 6, 22], fill=(210, 50, 40))
        d.text((ww - 17, 5), "x", fill=(255, 255, 255), font=get_sys_font(["arial.ttf"], 10))
        f_xp = get_sys_font(["tahomabd.ttf", "arialbd.ttf"], 10)
        d.text((8, 6), "Ошибка приложения", fill=(255, 255, 255), font=f_xp)
        d.rectangle([0, 0, ww - 1, wh - 1], outline=(0, 40, 180), width=2)
        d.ellipse([20, 50, 56, 86], fill=(220, 20, 20))
        d.text((32, 54), "X", fill=(255, 255, 255), font=get_sys_font(["arialbd.ttf"], 18))
        d.text((70, 54), "Инструкция по адресу 0x004012F4\nобратилась к памяти 0x00000000.\nПамять не может быть read.", fill=(0, 0, 0), font=get_sys_font(["tahoma.ttf"], 9))
        d.rectangle([ww // 2 - 40, wh - 35, ww // 2 + 40, wh - 12], fill=(225, 225, 220), outline=(0, 60, 180), width=1)
        d.text((ww // 2 - 10, wh - 30), "ОК", fill=(0, 0, 0), font=f_xp)

        sx, sy = random.randint(20, max(21, w // 4)), random.randint(20, max(21, h // 4))
        dx, dy = random.randint(14, 22), random.randint(12, 18)
        for i in range(steps):
            px, py = min(w - ww, sx + i * dx), min(h - wh, sy + i * dy)
            img.paste(win_box, (px, py))
        return img

    def draw_fisheye(self, img, strength):
        if strength <= 0:
            return img
        w, h = img.size
        sw, sh = max(64, int(w * 0.5)), max(64, int(h * 0.5))
        small = img.resize((sw, sh), Image.Resampling.BILINEAR)
        k = (strength / 100.0) * 1.8
        cx, cy = sw / 2.0, sh / 2.0
        src = small.load()
        out = Image.new("RGB", (sw, sh), (0, 0, 0))
        dst = out.load()

        for y in range(sh):
            dy = (y - cy) / cy
            for x in range(sw):
                dx = (x - cx) / cx
                r = math.sqrt(dx * dx + dy * dy)
                if r < 1.0:
                    theta = 1.0 if r == 0 else math.atan(r * k) / math.atan(k)
                    nx = int(cx + (dx / r if r != 0 else 0) * theta * cx)
                    ny = int(cy + (dy / r if r != 0 else 0) * theta * cy)
                    if 0 <= nx < sw and 0 <= ny < sh:
                        dst[x, y] = src[nx, ny]

        res = out.resize((w, h), Image.Resampling.BILINEAR)
        draw = ImageDraw.Draw(res)
        f_osd = get_sys_font(["consola.ttf", "courbd.ttf"], max(12, int(h * 0.024)))
        now_str = datetime.now().strftime("%Y-%m-%d  %H:%M:%S")
        draw.text((25, 20), f"[CAM 03 - ПОДЪЕЗД]   {now_str}", fill=(0, 255, 60), font=f_osd)
        draw.text((w - 180, 20), "[REC  25 FPS]", fill=(255, 40, 40), font=f_osd)
        draw.ellipse([w - 200, 24, w - 188, 36], fill=(255, 0, 0))
        return res

    def execute_pipeline(self, img):
        if self.bsod_var.get():
            img = self.draw_modern_bsod(img)

        img = self.draw_fisheye(img, self.fisheye_var.get())
        img = self.draw_xp_drag(img, self.xp_drag_var.get())
        img = self.draw_swirl(img, self.swirl_var.get())

        dm = self.datamosh_var.get()
        if dm > 0:
            w, h = img.size
            for _ in range(int((dm / 100.0) * 35)):
                bw, bh = random.randint(32, 96), random.randint(16, 64)
                bx, by = random.randint(0, max(1, w - bw)), random.randint(0, max(1, h - bh))
                block = img.crop((bx, by, bx + bw, by + bh))
                img.paste(block, (max(0, min(w - bw, bx + random.randint(-40, 40))), max(0, min(h - bh, by + random.randint(5, 30)))))

        art = self.art_var.get()
        if art > 0:
            ratio = art / 50000.0
            for _ in range(int(ratio * 50)):
                sy = random.randint(0, max(1, img.height - 8))
                sh = random.randint(2, max(4, int(img.height * 0.04)))
                drift = random.randint(-int(img.width * 0.25 * ratio), int(img.width * 0.25 * ratio))
                strip = img.crop((0, sy, img.width, min(img.height, sy + sh)))
                img.paste(ImageChops.offset(strip, drift, 0), (0, sy))

        ad_count = self.ads_var.get()
        if ad_count > 0 and self.cached_ads:
            pool = list(self.cached_ads)
            random.shuffle(pool)
            alpha_f = self.ad_alpha_var.get() / 100.0
            for i in range(ad_count):
                ad = pool[i % len(pool)].copy()
                scale = random.uniform(0.18, 0.45)
                dim = max(30, int(min(img.size) * scale))
                ad.thumbnail((dim, dim))
                if alpha_f < 1.0:
                    r, g, b, a = ad.split()
                    a = a.point(lambda p: int(p * alpha_f))
                    ad = Image.merge("RGBA", (r, g, b, a))
                rx = random.randint(0, max(1, img.width - ad.width))
                ry = random.randint(0, max(1, img.height - ad.height))
                img.paste(ad.convert("RGB"), (rx, ry), ad)

        if self.antivirus_alert_var.get():
            img = self.draw_antivirus(img)

        if self.cursor_trail_var.get():
            draw = ImageDraw.Draw(img)
            w, h = img.size
            sx, sy = random.randint(w // 4, (w * 3) // 4), random.randint(h // 4, (h * 3) // 4)
            dx, dy = random.randint(8, 16), random.randint(8, 16)
            cursor_pts = [(0, 0), (0, 16), (4, 12), (7, 19), (10, 18), (7, 11), (12, 11)]
            for i in range(25):
                cx, cy = sx + i * dx, sy + i * dy
                pts = [(cx + px, cy + py) for px, py in cursor_pts]
                draw.polygon(pts, fill=(255, 255, 255), outline=(0, 0, 0))

        if self.screamer_img_var.get() and self.cached_screamers:
            sc = random.choice(self.cached_screamers).copy()
            if self.scr_extreme_var.get():
                sc.thumbnail((int(img.width * 0.95), int(img.height * 0.95)))
                sc = ImageEnhance.Color(sc).enhance(3.5)
            else:
                sc.thumbnail((int(img.width * 0.6), int(img.height * 0.6)))
            cx, cy = (img.width - sc.width) // 2, (img.height - sc.height) // 2
            img.paste(sc.convert("RGB"), (cx, cy), sc)

        if self.matrix_lines_var.get():
            draw = ImageDraw.Draw(img)
            colors = [(0, 255, 120), (255, 0, 180), (255, 255, 255)]
            for _ in range(random.randint(2, 5)):
                lx = random.randint(10, img.width - 10)
                draw.line([(lx, 0), (lx, img.height)], fill=random.choice(colors), width=random.choice([1, 2]))

        if self.dead_pixels_var.get():
            draw = ImageDraw.Draw(img)
            colors = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)]
            for _ in range(random.randint(40, 100)):
                draw.point((random.randint(0, img.width - 1), random.randint(0, img.height - 1)), fill=random.choice(colors))

        if self.win_activate_var.get():
            draw = ImageDraw.Draw(img)
            f_main = get_sys_font(["segoeuib.ttf", "arialbd.ttf"], 18)
            f_sub = get_sys_font(["segoeui.ttf", "arial.ttf"], 12)
            x, y = max(10, img.width - 380), max(10, img.height - 75)
            draw.text((x, y), "Активация Windows", fill=(210, 210, 210), font=f_main)
            draw.text((x, y + 26), "Чтобы активировать Windows, перейдите в раздел Параметры.", fill=(180, 180, 180), font=f_sub)

        du = self.dialup_var.get()
        if du > 0:
            cut_y = max(10, int(img.height * (1.0 - (du / 100.0) * 0.7)))
            draw = ImageDraw.Draw(img)
            draw.rectangle([0, cut_y, img.width, img.height], fill=(180, 180, 180))

        if self.crt_var.get() > 0:
            img = self.draw_crt_scanlines(img, self.crt_var.get())

        if self.jitter_var.get() > 0:
            img = self.draw_jitter(img, self.jitter_var.get())

        if self.vignette_var.get() > 0:
            img = self.draw_vignette(img, self.vignette_var.get())

        if self.vhs_tracking_var.get() > 0:
            img = self.draw_vhs_tracking(img, self.vhs_tracking_var.get())

        if self.bitcrush_var.get() > 0:
            img = self.draw_bitcrush(img, self.bitcrush_var.get())

        if self.solarize_var.get():
            img = ImageOps.solarize(img, threshold=128)

        if self.invert_var.get():
            img = ImageOps.invert(img)

        rgb_s = self.rgb_var.get()
        if rgb_s > 0:
            r, g, b = img.split()
            img = Image.merge("RGB", (ImageChops.offset(r, rgb_s, 0), g, ImageChops.offset(b, -rgb_s, 0)))

        fry = self.fry_var.get()
        if fry > 1.0:
            img = ImageEnhance.Color(img).enhance(fry * 1.3)
            img = ImageEnhance.Contrast(img).enhance(fry)

        sharp = self.sharp_var.get()
        if sharp > 1:
            for _ in range(min(5, (sharp + 2) // 3)):
                img = ImageEnhance.Sharpness(img).enhance(3.2)

        pix = self.pix_var.get()
        if pix > 1:
            sw, sh = max(16, img.width // pix), max(16, img.height // pix)
            img = img.resize((sw, sh), Image.Resampling.BILINEAR).resize((img.width, img.height), Image.Resampling.NEAREST)

        # Ghost Windows in screenshot
        ghost_s = self.ghost_windows_var.get()
        if ghost_s > 0:
            gw = int(img.width * 0.44)
            gh = int(img.height * 0.4)
            gx = (img.width - gw) // 2
            gy = (img.height - gh) // 2
            cut = img.crop((gx, gy, gx + gw, gy + gh))
            steps = min(5, int((ghost_s / 100.0) * 5))
            for st in range(steps, 0, -1):
                ox = max(0, min(img.width - gw, gx + st * 22))
                oy = max(0, min(img.height - gh, gy + st * 16))
                img.paste(cut, (ox, oy))

        # GPU VRAM Artifacts in screenshot
        gpu_s = self.gpu_art_var.get()
        if gpu_s > 0:
            draw = ImageDraw.Draw(img)
            num_b = int((gpu_s / 100.0) * 20)
            for _ in range(num_b):
                bx = random.randint(0, max(1, img.width - 64))
                by = random.randint(0, max(1, img.height - 64))
                for bi in range(4):
                    for bj in range(4):
                        c = (255, 0, 255) if (bi + bj) % 2 == 0 else (0, 255, 255)
                        draw.rectangle([bx + bi*8, by + bj*8, bx + (bi+1)*8, by + (bj+1)*8], fill=c)

        p_val = max(72, min(NATIVE_H, self.global_res_var.get()))
        if p_val < NATIVE_H:
            aspect = NATIVE_W / float(NATIVE_H)
            tw = max(24, int(p_val * aspect))
            th = p_val
            img = img.resize((tw, th), Image.Resampling.BILINEAR)

        os.makedirs(self.save_dir, exist_ok=True)
        fname = f"shakal_{datetime.now().strftime('%Y%m%d_%H%M%S')}.jpg"
        save_path = os.path.join(self.save_dir, fname)

        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=max(1, min(100, self.q_var.get())))
        buf.seek(0)
        final_img = Image.open(buf)
        final_img.save(save_path, format="JPEG", quality=max(1, min(100, self.q_var.get())))

        if self.clip_var.get():
            copy_image_to_clipboard(final_img)

        return save_path

    def capture_fullscreen(self):
        try:
            delay = self.delay_var.get()
            self.root.withdraw()
            if delay > 0:
                time.sleep(delay)
            else:
                self.root.update_idletasks()

            img = ImageGrab.grab().convert("RGB")
            self.root.deiconify()

            ShakalAudioEngine.play(self.sound_choice_var.get())
            save_path = self.execute_pipeline(img)

            self.status_var.set(f"Снимок сохранен в {os.path.basename(self.save_dir)}")
            if self.open_var.get():
                os.startfile(save_path)
        except Exception as e:
            self.root.deiconify()
            self.status_var.set(f"Ошибка: {e}")

    def start_area_snip(self):
        self.root.withdraw()
        SnippingOverlay(self.root, self.on_area_selected)

    def on_area_selected(self, bbox):
        try:
            img = ImageGrab.grab(bbox=bbox).convert("RGB")
            self.root.deiconify()
            ShakalAudioEngine.play(self.sound_choice_var.get())
            save_path = self.execute_pipeline(img)

            self.status_var.set("Область сохранена и скопирована")
            if self.open_var.get():
                os.startfile(save_path)
        except Exception as e:
            self.root.deiconify()
            self.status_var.set(f"Ошибка области: {e}")

    def _native_hotkey_listener(self):
        vk_table = {"F8": 0x77, "F9": 0x78, "F10": 0x79, "F11": 0x7A, "F12": 0x7B}
        last_t = 0
        while self.running:
            try:
                # Instant Escape key handling when overlay is active (from any window!)
                if self.is_overlay_active and (user32.GetAsyncKeyState(0x1B) & 0x8000):
                    self.root.after(0, self.stop_all_prank_streams)
                    time.sleep(0.2)
                    continue

                now = time.time()
                if now - last_t > 0.35:
                    vk_scr = vk_table.get(self.bind_var.get(), 0x78)
                    vk_vid = vk_table.get(self.v_bind_var.get(), 0x79)
                    if user32.GetAsyncKeyState(vk_scr) & 0x8000:
                        last_t = now
                        self.root.after(0, self.capture_fullscreen)
                    elif user32.GetAsyncKeyState(vk_vid) & 0x8000:
                        last_t = now
                        self.root.after(0, self.toggle_video_recording)
                    elif user32.GetAsyncKeyState(0x7A) & 0x8000: # F11
                        last_t = now
                        self.root.after(0, self.toggle_overlay_screen1)
                    elif user32.GetAsyncKeyState(0x7B) & 0x8000: # F12
                        last_t = now
                        self.root.after(0, self.stop_all_prank_streams)
            except Exception:
                pass
            time.sleep(0.03)

    def on_close(self):
        self.running = False
        self.is_recording_video = False
        if self.discord_window:
            try:
                self.discord_window.destroy()
            except Exception:
                pass
        self.root.destroy()

if __name__ == "__main__":
    root = tk.Tk()
    app = ShakalStudioApp(root)
    root.mainloop()
