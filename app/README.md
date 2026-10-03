# 獨立 Mac App

macOS 14+，支援 Apple Silicon 與 Intel。App 使用 AVAudioEngine 收音、原生快捷鍵及 Quartz 貼上；日常操作不需要 Hammerspoon、sox、Homebrew 或 Python。浮動島音柱仍是動畫。

首次使用先連上 Tailscale，從 Spark 的 /download 取得正式安裝包。App 產生配對碼，在 /account 登入後確認。裝置憑證只存 Keychain；詞庫、校正及歷史由伺服器按帳號隔離。

雙按 Ctrl 開始，單按 Ctrl 結束並辨識，Esc 取消。Ctrl+Option+V 可備援，Ctrl+Option+P 開面板。可關閉雙 Ctrl、選擇開始／結束的快捷鍵，設定登入啟動及本機靈敏度。首次試說需要麥克風及輔助使用授權。

焦點／選取位置改變時不自動貼上，結果留在面板供複製。剪貼簿保留原格式，只有未被其他操作變更才恢復。失敗錄音留在私人 Application Support/VoiceInput/Recordings，可重試或清除，重開 App 仍可恢復。

學習提示只追蹤這次貼入的文字欄位、最多 90 秒，內容只留記憶體。短詞修改會提示五秒；按學起來才新增個人校正。也可手動修正最近結果，先比較、再確認。

## 建置

```sh
swift test --package-path app --disable-sandbox
app/build.sh --candidate
```

預設產物在 app/dist，不替換正在使用的 App；產生 universal DMG、SHA-256 和 candidate.json。--install / --run 才安裝到 ~/Applications，並保留舊 App 備份。

正式版本：設定 VOICE_INPUT_VERSION、VOICE_INPUT_SIGNING_IDENTITY（Developer ID Application）、VOICE_INPUT_NOTARY_PROFILE，再執行 app/build.sh --release。開發／ad-hoc 憑證不能代替正式發布。發布前必須由乾淨來源建置、完成公證與真實電腦驗收。

## 舊版遷移

首次啟動若找到 Hammerspoon 語音載入設定，先阻止新版快捷鍵接管。面板提供備份及停用，只處理識別出的語音載入行，其他模組不變。舊版 IPC 可用時確認已重載；無法確認時需使用者 Reload Config 後確認。一般新電腦不會需要此步驟。

伺服器與 Windows 實作在 livangvang/voice-input 的 codex/voice-input-accounts 分支，完整 API、遷移及驗收文件為 docs/desktop-accounts.md。兩個平台的 CI 候選包不代表已正式發布；正式下載頁只提供發布完成的版本。
