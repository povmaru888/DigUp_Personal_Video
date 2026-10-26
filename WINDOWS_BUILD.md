# Windows 10 x64 編譯與安裝檔製作

本版本的產品名稱是 **DigUp Personal Video**，安裝檔格式為 NSIS `.exe`，支援 64 位元 Windows 10／11。
影片只建立檔名、祖先目錄與磁碟位置索引；文字、圖片與獨立音訊仍使用 embedding。

## 1. 安裝必要工具

建議使用乾淨的 Windows 10/11 x64 實機或虛擬機。先安裝：

1. Visual Studio 2022 Build Tools：勾選 **Desktop development with C++**、MSVC x64、Windows 10/11 SDK、CMake。
2. Swift 6.4 for Windows：安裝官方 toolchain，確認 `swift --version` 可執行。
3. Rust stable x86_64-pc-windows-msvc：從 rustup 安裝，確認 `cargo --version`。
4. Node.js LTS：確認 `node --version` 與 `npm --version`。
5. Git for Windows。
6. Python 3，安裝時勾選加入 PATH。
7. MSYS2；在 **MSYS2 MINGW64** 終端執行：

```bash
pacman -Syu
pacman -S --needed mingw-w64-x86_64-toolchain mingw-w64-x86_64-meson \
  mingw-w64-x86_64-ninja mingw-w64-x86_64-nasm mingw-w64-x86_64-pkgconf \
  mingw-w64-x86_64-zlib make curl tar
```

若要讓 llama.cpp 使用 Vulkan GPU，再安裝 Vulkan SDK，並確認 `glslc` 位於 PATH；否則會建立 CPU 版本。

## 2. 解壓縮

將 ZIP 解壓到路徑較短、沒有特殊符號的位置，例如：

```text
C:\src\DigUpPersonalVideo
```

防毒軟體可能會明顯拖慢 Swift、Rust 與 C++ 編譯；必要時只針對此原始碼及建置目錄設定排除。

## 3. 取得預編譯依賴

從開始功能表開啟 **x64 Native Tools Command Prompt for VS 2022**，再由其中啟動 Git Bash，使
`VCToolsRedistDir`、MSVC、Swift、Rust、Node、Python 都能被找到。切換到專案目錄後執行：

```bash
scripts/fetch-vendor.sh
scripts/build-llama.sh
```

`fetch-vendor.sh` 會下載並核對固定 SHA-256 的 SQLite、stb、miniz 與 PDFium。
`build-llama.sh` 會依環境建立 CPU、Vulkan 或 CUDA 後端。

## 4. 編譯 ffmpeg

此步驟必須改用 **MSYS2 MINGW64** 終端。切換到同一個專案目錄後執行：

```bash
scripts/build-ffmpeg.sh
```

完成後應存在：

```text
Vendor/ffmpeg/bin/ffmpeg.exe
Vendor/ffmpeg/bin/ffprobe.exe
```

影片名稱索引不會呼叫這兩個程式；它們仍供獨立音訊與其他既有媒體功能使用。

## 5. 建立 NSIS 安裝檔

回到已載入 Visual Studio x64 環境的 Git Bash，確認：

```bash
swift --version
cargo --version
node --version
python --version
echo "$VCToolsRedistDir"
```

然後執行：

```bash
scripts/package-windows.sh
```

腳本會：

- 以 release 模式編譯 Swift helper；
- 收集 Swift、MSVC、llama.cpp、PDFium 與 ffmpeg 執行依賴；
- 產生第三方授權文件；
- 用 Tauri 2 建立 current-user NSIS x64 安裝檔；
- 在終端輸出安裝檔的 SHA-256。

成品位於：

```text
shell/src-tauri/target/release/bundle/nsis/*.exe
```

另存雜湊：

```bash
sha256sum shell/src-tauri/target/release/bundle/nsis/*.exe > SHA256SUMS.txt
```

## 6. 驗證安裝檔

最少應在乾淨的 Windows 10 x64 使用者帳戶驗證：安裝、首次啟動、加入只有影片的資料夾、未下載模型時搜尋影片、外接磁碟拔除／重接、開啟檔案、解除安裝。

完整自動測試需要 embedding 模型所在資料夾：

```bash
MODELS=/c/path/to/models scripts/check-windows-package.sh \
  shell/src-tauri/target/release/bundle/nsis/DigUp_Personal_Video*.exe
```

檔名若不同，請改成實際產生的 `.exe` 路徑。

## 7. 未簽章提示

若沒有 Windows Authenticode 憑證，安裝檔仍可建立，但 Windows SmartScreen 可能顯示「Windows 已保護您的電腦」。
測試時可選擇「其他資訊」→「仍要執行」。正式對外發佈前，建議用受信任憑證簽署安裝檔並再次計算 SHA-256。

## 8. 匯入舊版索引（選用）

安裝完成後，先關閉官方 DigUp 與 DigUp Personal Video，再於 PowerShell 執行安裝目錄中的：

```powershell
powershell -ExecutionPolicy Bypass -File .\import-personal-index.ps1
```

腳本只會複製舊資料庫到獨立資料目錄並建立備份，不修改官方資料庫。首次啟動客製版時才會執行 schema migration。

## 常見問題

- `VCToolsRedistDir` 為空：沒有從 Visual Studio x64 Developer Command Prompt 啟動 Git Bash。
- 找不到 `ffmpeg.exe`：尚未在 MSYS2 MINGW64 執行 `scripts/build-ffmpeg.sh`。
- `cl` 或 Windows SDK 找不到：Visual Studio C++ workload 未安裝或開錯終端。
- `swift build` 連結失敗：確認使用 Windows 版 Swift 6.4，且 MSVC x64 環境已載入。
- PowerShell 執行政策阻擋匯入腳本：只對該次命令使用 `-ExecutionPolicy Bypass`，不必更改系統全域設定。

