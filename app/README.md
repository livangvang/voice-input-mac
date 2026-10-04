# 獨立 Mac App

macOS 14+，支援 Apple Silicon 與 Intel。App 使用 AVAudioEngine 收音、原生快捷鍵及 Quartz 貼上；日常操作不需要 Hammerspoon、sox、Homebrew 或 Python。浮動島音柱仍是動畫。

首次使用先連上 Tailscale，從 Spark 的 /download 取得正式安裝包。App 產生配對碼，在 /account 登入後確認。裝置憑證只存 Keychain；詞庫、校正及歷史由伺服器按帳號隔離。

雙按 Ctrl 開始，單按 Ctrl 結束並辨識，Esc 取消。Ctrl+Option+V 可備援，Ctrl+Option+P 開面板。可關閉雙 Ctrl、選擇開始／結束的快捷鍵，設定登入啟動及本機靈敏度。首次試說需要麥克風及輔助使用授權。

1.1.9 使用短促、較清楚的敲擊提示：開始敲一下，結束敲兩下。開始音在麥克風啟動成功後播放，結束音在停止收音後立即播放，不等待辨識完成；Esc 取消不播放結束音。提示由內附 WAV 以 App 播放音量 100% 播放，仍遵循 Mac 輸出音量。音檔由 `scripts/generate-recording-sounds.py` 產生。

1.1.3 改用 AppKit 的被動按鍵監聽；即使 App 忙碌，其他程式仍收到原本的按鍵。快捷鍵及 Esc 也會送達目前的程式，因此建議使用預設雙 Ctrl；若自訂組合鍵，請避免與常用程式的快捷鍵衝突。延遲超過 1.5 秒的按鍵不觸發錄音。

Keychain 讀寫在背景 actor 執行，介面與每次 API 請求只使用按伺服器分開的記憶體快取。啟動時不自動要求 Keychain 確認；遇到更新後的存取限制，按「恢復帳號存取」才開啟系統確認。伺服器與辨識服務檢查不等待帳號憑證，也不傳送裝置憑證。

焦點／選取位置改變時不自動貼上，結果留在面板供複製。剪貼簿保留原格式，只有未被其他操作變更才恢復。失敗錄音留在私人 Application Support/VoiceInput/Recordings，仍可選擇重試；下一次按快捷鍵可直接錄新的一段，較早的失敗檔案保留在 Saved 子目錄。

HTTP 200 的空白／略過回應也視為未完成，錄音會保留。舊服務中音量足夠而動態比值介於 2.0 與原門檻之間時，可手動確認這段確實有說話，僅本次放寬比值。診斷只記固定事件與數量，不含文字、錄音、視窗標題或帳號憑證。

1.1.5 在 App 啟動時初始化錄音、快捷鍵與帳號，避免登入／背景啟動因主視窗未顯示而完全沒開始。面板尚未建立時，Dock 再開啟或「開啟面板」會建立復原視窗；關閉視窗後錄音功能繼續運作。

1.1.7 使用原始硬體收音，撤回 1.1.6 的人聲處理路徑：實機曾產生全零音訊，僅確認檔案存在不足以證明收音成功。每次錄音記錄總樣本與非零樣本數；全零或無樣本不送辨識，直接提示沒有收到聲音，不增加音量門檻。

辨識失敗或未收到語音時，只在不啟用前景焦點的浮動島提示八秒，不自動開設定或擋住下一次錄音。可直接再按快捷鍵說話；連線失敗時點泡泡可重試到當前欄位，仍核對焦點和選取範圍。無法安全貼上的文字可點泡泡複製。設定和保留錄音仍可從 Dock、選單或 Ctrl+Option+P 手動開啟。

伺服器回報 `speech_gate=vad` 時顯示自動人聲判定，不顯示未使用的音量滑桿；辨識與校正模型不變。

學習提示只追蹤這次貼入的文字欄位、最多 90 秒，內容只留記憶體。短詞修改會提示五秒；按學起來才新增個人校正。也可手動修正最近結果，先比較、再確認。

## 建置

```sh
swift test --package-path app --disable-sandbox
app/build.sh --candidate
```

預設產物在 app/dist，不替換正在使用的 App；產生 universal DMG、SHA-256 和 candidate.json。--install / --run 才安裝到 ~/Applications，並保留舊 App 備份。

正式版本：設定 VOICE_INPUT_VERSION、VOICE_INPUT_SIGNING_IDENTITY（Developer ID Application）、VOICE_INPUT_NOTARY_PROFILE，再執行 app/build.sh --release。小群測試可設定固定的 Apple Development 憑證，避免每次更新都因 ad-hoc 身分改變而失去系統授權；由 ad-hoc 換成開發憑證的第一次仍可能需要重新允許 App。開發／ad-hoc 憑證不能代替正式發布。發布前必須由乾淨來源建置、完成公證與真實電腦驗收。

## 舊版遷移

首次啟動若找到 Hammerspoon 語音載入設定，先阻止新版快捷鍵接管。面板提供備份及停用，只處理識別出的語音載入行，其他模組不變。舊版 IPC 可用時確認已重載；無法確認時需使用者 Reload Config 後確認。一般新電腦不會需要此步驟。

伺服器與 Windows 實作在 livangvang/voice-input 的 codex/voice-input-accounts 分支，完整 API、遷移及驗收文件為 docs/desktop-accounts.md。兩個平台的 CI 候選包不代表已正式發布；正式下載頁只提供發布完成的版本。

## App 圖示

圖示沿用浮動島的三根音柱與外圍圓環，黑底、橘色中央音柱、白色兩側音柱。Dock 仍會顯示錄音、辨識與停用狀態；浮動島動畫維持原設定。

`Sources/VoiceInputApp/VoiceLogo.swift` 是 Dock 與圖檔的共同繪製來源。修改後執行 `./scripts/generate-icons.sh` 更新 `Assets/AppIcon.icns` 及 `Assets/logo.png`；`Assets/logo.svg` 是對應的向量稿。安裝包透過 `CFBundleIconFile` 帶入 Finder 圖示。
