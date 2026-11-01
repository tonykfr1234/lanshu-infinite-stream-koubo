#!/usr/bin/env bash
# LiteAvatar 即時數位人驗證腳本（在 WSL2 Ubuntu 內執行）
#   bash verify_liteavatar.sh
# 可調整：WORK=安裝目錄（預設 ~/rt-avatar）  THREADS="1 4"（測試的執行緒數）
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HOME/rt-avatar}"
THREADS="${THREADS:-1 4}"
LITE_COMMIT=5b7ec850945e03d56fb290b05fb68440c359fa86   # 2025-06-30 驗證過的版本
LOG="$WORK/verify.log"
mkdir -p "$WORK"
exec > >(tee -a "$LOG") 2>&1

step() { printf '\n==== %s ====\n' "$*"; }
step "0. 系統資訊  $(date '+%F %T')"
grep -qi microsoft /proc/version && echo "執行環境：WSL2" || echo "警告：看起來不是 WSL2（這個腳本仍可在一般 Ubuntu 執行）"
. /etc/os-release && echo "系統：$PRETTY_NAME"
echo "CPU：$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | xargs)  核心數：$(nproc)"
free -h | awk '/Mem:/{print "記憶體：" $2 "（WSL 可用）"}'
NVSMI=$(command -v nvidia-smi || echo /usr/lib/wsl/lib/nvidia-smi)
if [ -x "$NVSMI" ]; then "$NVSMI" --query-gpu=name,memory.total,driver_version --format=csv,noheader | sed 's/^/GPU：/'
else echo "GPU：WSL 內找不到 nvidia-smi（請確認 Windows 已安裝 NVIDIA 驅動程式）"; fi

step "1. 安裝系統套件（需要 sudo 密碼）"
sudo apt-get update -qq
sudo apt-get install -y -qq git ffmpeg unzip curl ca-certificates libgl1 libglib2.0-0 >/dev/null
echo "ffmpeg：$(ffmpeg -version | head -1)"

step "2. 安裝 uv（Python 版本與套件管理工具）"
if ! command -v uv >/dev/null; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"
uv --version

step "3. 下載 LiteAvatar 原始碼"
cd "$WORK"
if [ ! -d lite-avatar/.git ]; then
  git clone https://github.com/HumanAIGC/lite-avatar.git
fi
cd lite-avatar
git fetch -q --depth 1 origin "$LITE_COMMIT" 2>/dev/null || true
git checkout -q "$LITE_COMMIT" && echo "版本：$LITE_COMMIT"

step "4. 建立 Python 3.10 虛擬環境並安裝相依套件（約 3–4 GB，首次需要幾分鐘）"
[ -d .venv ] || uv venv -q --python 3.10 .venv
# shellcheck disable=SC1091
. .venv/bin/activate
uv pip install -q -r requirements.txt \
  --extra-index-url https://download.pytorch.org/whl/cu118 --index-strategy unsafe-best-match

step "5. 從 ModelScope 下載模型權重"
PARA=weights/speech_paraformer-large_asr_nat-zh-cn-16k-common-vocab8404-pytorch
if [ -f weights/model_1.onnx ] && [ -f "$PARA/model.pb" ] && [ -f "$PARA/lm/lm.pb" ]; then
  echo "權重已存在，略過"
else
  # 專案固定的 modelscope 1.8.1 沒有 download 指令，改用新版 CLI 單獨下載
  uvx -q --python 3.10 --from 'modelscope>=1.20' modelscope download \
    --model HumanAIGC-Engineering/LiteAvatarGallery \
    lite_avatar_weights/lm.pb lite_avatar_weights/model_1.onnx lite_avatar_weights/model.pb --local_dir ./
  mv lite_avatar_weights/lm.pb "$PARA/lm/"
  mv lite_avatar_weights/model_1.onnx weights/
  mv lite_avatar_weights/model.pb "$PARA/"
  rm -rf lite_avatar_weights
fi
ls -lh weights/model_1.onnx "$PARA/model.pb" "$PARA/lm/lm.pb"

step "6. 準備範例人物與測試語音"
[ -d data/preload ] || unzip -q data/sample_data.zip -d data
# 專案內建的中文範例語音約 5.5 秒，重複 3 次成約 16.6 秒，讓測速較穩定
ffmpeg -y -loglevel error -stream_loop 2 -i "$PARA/example/asr_example.wav" -c copy "$WORK/test_16k.wav"
echo "測試語音：$WORK/test_16k.wav"

step "7. 檢查 GPU 是否可被 PyTorch 使用（給之後的 MuseTalk 用）"
python - <<'PY'
import torch
ok = torch.cuda.is_available()
print("torch", torch.__version__, "| CUDA 可用：", ok, "|", torch.cuda.get_device_name(0) if ok else "—")
PY

step "8. LiteAvatar CPU 即時性測試"
OUT="$WORK/result"
mkdir -p "$OUT"
for t in $THREADS; do
  echo "--- 執行緒數 $t ---"
  python "$HERE/bench_liteavatar.py" --data_dir data/preload --audio "$WORK/test_16k.wav" \
    --out "$OUT" --threads "$t" 2>"$OUT/bench_t$t.stderr.log" | grep BENCH_RESULT || {
      echo "測試失敗，錯誤訊息最後 30 行："; tail -30 "$OUT/bench_t$t.stderr.log"; exit 1; }
done

step "9. 結果摘要"
python - "$OUT" <<'PY'
import json, glob, sys
for f in sorted(glob.glob(sys.argv[1] + "/bench_t*.json")):
    r = json.load(open(f, encoding="utf-8"))
    print(f"執行緒 {r['threads']}：生成 {r['face_gen_fps']} 幀/秒（目標 30）、即時倍率 {r['realtime_factor']}x、"
          f"首幀 {r['first_frame_s']} 秒、解析度 {r['resolution']} → {'✅ 可即時' if r['realtime_ok'] else '⚠️ 未達即時'}")
PY

# 把影片和紀錄複製到 Windows 桌面，方便直接開
if command -v cmd.exe >/dev/null && command -v wslpath >/dev/null; then
  WINHOME=$(wslpath "$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')" 2>/dev/null || true)
  if [ -n "$WINHOME" ] && [ -d "$WINHOME/Desktop" ]; then
    DEST="$WINHOME/Desktop/liteavatar-verify"
    mkdir -p "$DEST" && cp "$OUT"/*.mp4 "$OUT"/*.json "$LOG" "$DEST"/
    echo "已複製影片與紀錄到 Windows 桌面：liteavatar-verify 資料夾"
  fi
fi
echo "完整紀錄：$LOG"
