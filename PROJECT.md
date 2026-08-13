---
projectctl_version: 1
registry_page_id: "3bb0520b-2dc7-818d-9218-ddf9416afdf9"
registry_url: "https://app.notion.com/p/3bb0520b2dc7818d9218ddf9416afdf9"
workspace_path: "/Users/zhaochunxian/Dev/personal/超簡單語音輸入法"
created_at: "2026-08-13T17:57:20.698Z"
---

# 超簡單語音輸入法

## 這是什麼

語音輸入法的 **Mac 客戶端**：連按兩下 `Ctrl` 開始錄音，按任何一鍵停止，
辨識完的文字自動貼進目前的 App。

Mac 端只做錄音與貼上；Whisper 辨識、能量閘門、繁體轉換、常用詞校正、歷史紀錄，
都在家裡的伺服器 **Spark**（`ssh dogi@spark-cb4e`，專案在 `~/.local/share/voice-input`）上。
伺服器端專案的 `mac/` 目錄是本專案的上游。

細節、架構圖、版本落差與還原方式見 [README.md](./README.md)。

## 管理連結

- Notion：https://app.notion.com/p/3bb0520b2dc7818d9218ddf9416afdf9
- 管理狀態、卡點與下一步只更新 Notion。
- 開始協作前，Codex／其他 agent 先讀本檔。

## 進入方式

檔案實體在本專案，原位是符號連結（`~/bin/`、`~/.hammerspoon/`），改這裡就等於改線上：

```bash
voice-input-mac.sh ping     # 測 Spark 通不通
hs -c "hs.reload()"         # 改完 lua 後重載 Hammerspoon
```

需求：`sox`、Hammerspoon（要輔助使用權限）、Tailscale 連線且 MagicDNS 開啟。
