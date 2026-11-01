# 即時數位人驗證：LiteAvatar（在 Windows 的 WSL2 執行）

這份腳本會在你的電腦上自動安裝阿里開源的 [LiteAvatar](https://github.com/HumanAIGC/lite-avatar)，它也是 OpenAvatarChat 預設的形象引擎。接著用範例人物和一段中文語音產生對口型影片，並量出你的電腦每秒能生成幾幀，判斷能不能即時跑。

驗證對象：Intel i5-14500、64 GB 記憶體、RTX 3060 12 GB。LiteAvatar 主要用 CPU 運算，腳本也會順便檢查 GPU 能不能在 WSL 裡被 PyTorch 使用，之後升級到 MuseTalk 時會用到。

## 一、安裝 WSL2 與 Ubuntu（只需做一次）

用「以系統管理員身分執行」開啟 PowerShell：

```powershell
wsl --install -d Ubuntu-22.04
```

完成後重新開機。Ubuntu 會自動開啟，照提示設定 Linux 使用者名稱和密碼。

確認 GPU 有進到 WSL（在 Ubuntu 視窗裡執行）：

```bash
nvidia-smi
```

能看到 RTX 3060 就沒問題。WSL 不需要另外安裝 Linux 版 NVIDIA 驅動程式，Windows 的驅動程式就夠了。

## 二、取得腳本並執行

在 Ubuntu 視窗裡執行：

```bash
git clone -b claude/lanshu-infinite-stream-install-45y8ix https://github.com/tonykfr1234/lanshu-infinite-stream-koubo.git ~/koubo
```

```bash
bash ~/koubo/realtime-avatar/verify_liteavatar.sh
```

- 中途會要求輸入剛才設定的 Linux 密碼，用來安裝 ffmpeg 等系統套件。
- 首次執行會下載約 3–4 GB 的套件和模型權重，整體約 10–20 分鐘，視網路速度而定。
- 重複執行時，已下載的東西會略過。

## 三、看結果

腳本最後會印出類似這樣的摘要：

```text
執行緒 1：生成 xx 幀/秒（目標 30）、即時倍率 x.xx x、首幀 x.xxx 秒、解析度 WxH → ✅ 可即時
```

- **生成幀率**：30 以上就代表能跑出流暢的即時畫面。
- **即時倍率**：大於 1 代表處理速度比語音播放快，也就是能即時跟上。
- 影片和紀錄會複製到 Windows 桌面的 `liteavatar-verify` 資料夾，可以直接打開看嘴型對不對。
- 完整紀錄在 Ubuntu 的 `~/rt-avatar/verify.log`，把它的內容或最後的摘要貼回給 Claude，就能判讀下一步。

## 常見問題

| 狀況 | 處理方式 |
| --- | --- |
| 步驟 5 下載權重失敗 | ModelScope 在中國，網路不穩時重跑腳本即可，已完成的步驟會略過 |
| `git clone` 要求帳號密碼 | 這個儲存庫若是私人的，請改從 GitHub 網頁下載 ZIP，把 `realtime-avatar` 資料夾複製到 Ubuntu 的家目錄（檔案總管網址列輸入 `\\wsl$`），再執行 `bash ~/realtime-avatar/verify_liteavatar.sh` |
| 只想測單一執行緒數 | `THREADS="1" bash ~/koubo/realtime-avatar/verify_liteavatar.sh` |
| 想裝到別的目錄 | `WORK=/path/to/dir bash ~/koubo/realtime-avatar/verify_liteavatar.sh` |

## 備註

- 版本固定在 LiteAvatar 的 `5b7ec85` 提交（2025-06-30）。
- 原專案固定使用的 `modelscope==1.8.1` 沒有 `download` 指令，所以腳本改用新版 ModelScope 指令列工具，單獨下載權重。
- 原專案的推論程式把 ffmpeg 路徑寫死成 `/usr/bin/ffmpeg`，所以選擇在 WSL 裡跑。測速另外由 `bench_liteavatar.py` 負責，它會把「生成畫面」和「寫入硬碟」分開計時。
- 範例人物與模型權重的授權以 LiteAvatar 和 ModelScope 頁面為準。
