"""LiteAvatar CPU 即時性測試：量測音訊轉口型參數、逐幀生成的速度，並輸出對口型影片。

用法（在 lite-avatar 目錄內、已啟用虛擬環境）：
    python bench_liteavatar.py --data_dir data/preload --audio long.wav --out result --threads 1
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import wave

import cv2

sys.path.insert(0, os.getcwd())
from lite_avatar import liteAvatar  # noqa: E402

FPS = 30


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data_dir", required=True)
    ap.add_argument("--audio", required=True, help="16 kHz、單聲道、16-bit WAV")
    ap.add_argument("--out", required=True)
    ap.add_argument("--threads", type=int, default=1)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    with wave.open(a.audio, "rb") as w:
        if (w.getframerate(), w.getnchannels(), w.getsampwidth()) != (16000, 1, 2):
            sys.exit("音訊必須是 16 kHz、單聲道、16-bit WAV")
        audio_s = w.getnframes() / w.getframerate()

    t0 = time.perf_counter()
    la = liteAvatar(data_dir=a.data_dir, num_threads=a.threads, generate_offline=True)
    t_load = time.perf_counter() - t0

    audio = liteAvatar.read_wav_to_bytes(a.audio)
    t0 = time.perf_counter()
    params = la.audio2param(audio)
    t_a2m = time.perf_counter() - t0

    # 與 lite_avatar.handle() 相同的排程，但生成期間不寫檔，只量純運算速度
    n = len(params)
    bg = la.bg_video_frame_count
    t0 = time.perf_counter()
    for i in range(n):
        fid = i % bg if (i // bg) % 2 == 0 else bg - 1 - i % bg
        la.input_queue.put((params[i], fid, i))
    la.input_queue.put(None)
    frames = {}
    first_frame_s = None
    while True:
        item = la.output_queue.get()
        if item is None:
            break
        if first_frame_s is None:
            first_frame_s = time.perf_counter() - t0
        frames[item[0]] = item[1]
    t_gen = time.perf_counter() - t0
    for t in la.threads_prep:
        t.join()

    tmp = os.path.join(a.out, f"frames_t{a.threads}")
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    for i in sorted(frames):
        cv2.imwrite(os.path.join(tmp, f"{i + 1:05d}.jpg"), frames[i])
    mp4 = os.path.join(a.out, f"liteavatar_t{a.threads}.mp4")
    subprocess.run([shutil.which("ffmpeg") or "ffmpeg", "-y", "-loglevel", "error", "-r", str(FPS),
                    "-i", os.path.join(tmp, "%05d.jpg"), "-i", a.audio, "-c:v", "libx264",
                    "-pix_fmt", "yuv420p", "-b:v", "5000k", "-shortest", mp4], check=True)
    shutil.rmtree(tmp, ignore_errors=True)

    gen_fps = n / t_gen if t_gen else 0.0
    # 即時倍率 > 1 代表處理速度比播放速度快
    rtf = audio_s / (t_a2m + t_gen) if (t_a2m + t_gen) else 0.0
    h, w = next(iter(frames.values())).shape[:2]
    res = {
        "threads": a.threads,
        "audio_seconds": round(audio_s, 2),
        "frames": n,
        "resolution": f"{w}x{h}",
        "model_load_s": round(t_load, 2),
        "audio2mouth_s": round(t_a2m, 2),
        "face_gen_s": round(t_gen, 2),
        "first_frame_s": round(first_frame_s or 0, 3),
        "face_gen_fps": round(gen_fps, 1),
        "realtime_factor": round(rtf, 2),
        "realtime_ok": gen_fps >= FPS * 0.95 and rtf >= 1.0,
        "video": os.path.abspath(mp4),
    }
    with open(os.path.join(a.out, f"bench_t{a.threads}.json"), "w", encoding="utf-8") as f:
        json.dump(res, f, ensure_ascii=False, indent=2)
    print("BENCH_RESULT " + json.dumps(res, ensure_ascii=False))
    os._exit(0)  # 背景執行緒為 daemon，直接結束


if __name__ == "__main__":
    main()
