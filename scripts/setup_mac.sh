#!/usr/bin/env bash

# ==============================================================================
# NIBB ゲノムインフォマティクス・トレーニングコース (GITC 2027 春)
# macOS (Apple Silicon / macOS Sequoia 15 以降) 用 解析環境自動セットアップスクリプト
#
# 動作対象環境:
#   - CPU: Apple Silicon 搭載 Mac (arm64: M1 / M2 / M3 / M4 / M5 等)
#   - OS : macOS Sequoia (15) 以降
#
# 設計方針:
#   - 不足しているソフトウェアのみを補完し、既存の解析環境（Homebrew / Conda /
#     手動配置ツール・Python 環境）の優先順位や設定は極力変更しない。
#   - PEP 668 に準拠し、Homebrew 管理下の Python 環境へ --break-system-packages で
#     直接インストールすることは避け、専用仮想環境（~/.gitc_venv）を利用する。
#
# 使い方:
#   curl -O https://raw.githubusercontent.com/nibb-unix/gitc202702-unix/main/scripts/setup_mac.sh
#   bash setup_mac.sh
# ==============================================================================

# 表示用のカラーコード定義
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# インストールに失敗した項目を記録する配列
FAILED_PACKAGES=()

echo ""
echo "============================================================"
echo " NIBB GITC 解析環境セットアップ (macOS / Apple Silicon)"
echo "============================================================"
echo ""

# ------------------------------------------------------------------------------
# 0. 実行環境の事前チェック（macOS / Apple Silicon / macOS 15+ / CLT / Homebrew）
# ------------------------------------------------------------------------------
OS_NAME="$(uname -s)"
if [ "$OS_NAME" != "Darwin" ]; then
    echo -e "${RED}[エラー] このスクリプトは macOS 専用です。${NC}"
    echo "Windows 11 (Ubuntu / WSL2) をお使いの場合は、setup_win.sh を使用してください。"
    exit 1
fi

ARCH_NAME="$(uname -m)"
if [ "$ARCH_NAME" != "arm64" ]; then
    echo -e "${RED}[エラー] このスクリプトは Apple Silicon 搭載 Mac（arm64）専用です。${NC}"
    echo "検出された CPU アーキテクチャ: ${ARCH_NAME}"
    if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = "1" ]; then
        echo ""
        echo -e "${YELLOW}[ヒント] お使いのターミナルアプリが Intel 互換モード（Rosetta 2）で起動しています。${NC}"
        echo "ターミナルを終了（Command + Q）し、Finder で「ターミナル.app」の「情報を見る」から"
        echo "「Rosetta を使用して開く」のチェックを外してから再度実行してください。"
    else
        echo "Intel プロセッサ搭載 Mac は Homebrew 公式仕様変更によりサポート対象外となります。"
    fi
    exit 1
fi

MACOS_VER="$(sw_vers -productVersion 2>/dev/null || echo '0.0')"
MACOS_MAJOR="${MACOS_VER%%.*}"
if ! [[ "$MACOS_MAJOR" =~ ^[0-9]+$ ]] || [ "$MACOS_MAJOR" -lt 15 ]; then
    echo -e "${RED}[エラー] macOS Sequoia (15) 以降が必要です。${NC}"
    echo "検出された macOS バージョン: macOS ${MACOS_VER}"
    echo "「システム設定」＞「一般」＞「ソフトウェアアップデート」から"
    echo "macOS Sequoia (15) 以降にアップデートしたうえで、再度このスクリプトを実行してください。"
    exit 1
fi

echo "検出されたシステム: macOS ${MACOS_VER} (${ARCH_NAME} / Apple Silicon)"
echo ""

# Xcode Command Line Tools の確認
if ! xcode-select -p >/dev/null 2>&1; then
    echo -e "${RED}[エラー] Xcode Command Line Tools がインストールされていません。${NC}"
    echo "先に PDF マニュアル（setup_mac.pdf）の手順に従い、以下を実行してください:"
    echo "  xcode-select --install"
    exit 1
fi

# Homebrew の検出と有効化（Apple Silicon 標準パス /opt/homebrew を優先）
BREW_BIN=""
if [ -x "/opt/homebrew/bin/brew" ]; then
    BREW_BIN="/opt/homebrew/bin/brew"
elif command -v brew >/dev/null 2>&1; then
    BREW_BIN="$(command -v brew)"
else
    echo -e "${RED}[エラー] Homebrew (brew) が見つかりませんでした。${NC}"
    echo "先に PDF マニュアル（setup_mac.pdf）の手順に従い、Homebrew をインストールしてください。"
    exit 1
fi

# 現在のスクリプト実行環境で brew とその配下のコマンドを使えるようにする
eval "$("$BREW_BIN" shellenv)"
BREW_PREFIX="$("$BREW_BIN" --prefix)"
echo "使用する Homebrew: ${BREW_BIN} (prefix: ${BREW_PREFIX})"
echo ""
echo "これより不足している解析ソフトウェアのインストールを開始します。"
echo "（通信環境や Mac の性能により 5〜15 分程度かかる場合があります）"
echo ""

# ------------------------------------------------------------------------------
# 1. Homebrew データベースの更新
# ------------------------------------------------------------------------------
echo "------------------------------------------------------------"
echo " [Step 1/4] Homebrew のパッケージ情報を更新しています..."
echo "------------------------------------------------------------"
if ! brew update; then
    echo -e "${RED}[エラー] brew update に失敗しました。ネットワーク接続を確認してください。${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# 2. 解析ソフトウェアの一括インストール（brew install）
# ------------------------------------------------------------------------------
echo ""
echo "------------------------------------------------------------"
echo " [Step 2/4] 解析ソフトウェアを一括インストールしています..."
echo "------------------------------------------------------------"

# すべて Homebrew 公式リポジトリ (homebrew/core) から導入可能
BREW_PACKAGES=(
    "wget"
    "bowtie2"
    "samtools"
    "cutadapt"
    "fastqc"
    "blast"
    "sratoolkit"
    "seqkit"
    "python3"
)

for pkg in "${BREW_PACKAGES[@]}"; do
    # 既に Homebrew で導入済みの場合は再インストール・不要なアップグレードをスキップ
    if brew list --formula "$pkg" >/dev/null 2>&1; then
        echo ">>> $pkg は既に Homebrew で導入済みです（スキップ）。"
        continue
    fi

    # python3 以外は、Conda 等で既にコマンドが存在する場合も既存環境を優先してスキップ
    if [ "$pkg" != "python3" ]; then
        check_target="$pkg"
        [ "$pkg" = "blast" ] && check_target="blastn"
        [ "$pkg" = "sratoolkit" ] && check_target="fasterq-dump"
        if command -v "$check_target" >/dev/null 2>&1; then
            echo ">>> $pkg ($check_target) は既に利用可能です（スキップ: $(command -v "$check_target")）。"
            continue
        fi
    fi

    echo ">>> インストール中: $pkg"
    if ! brew install "$pkg"; then
        echo -e "${YELLOW}[警告] $pkg のインストールに失敗しました。後続の処理を続行します。${NC}"
        FAILED_PACKAGES+=("$pkg")
    fi
done

# SRA Toolkit 未設定の新規環境のみ、公式の非対話コマンドでデフォルト設定を初期化
if [ ! -f "$HOME/.ncbi/user-settings.mkfg" ]; then
    if command -v vdb-config >/dev/null 2>&1; then
        echo ">>> SRA Toolkit の初期設定を行っています..."
        vdb-config --restore-defaults >/dev/null 2>&1 || true
    fi
fi

# ------------------------------------------------------------------------------
# 3. Python ライブラリ（numpy, HTSeq）の導入（専用仮想環境 ~/.gitc_venv）
# ------------------------------------------------------------------------------
echo ""
echo "------------------------------------------------------------"
echo " [Step 3/4] Python ライブラリ（numpy, HTSeq）を確認・導入しています..."
echo "------------------------------------------------------------"

VENV_DIR="$HOME/.gitc_venv"
BREW_PYTHON="${BREW_PREFIX}/bin/python3"
[ ! -x "$BREW_PYTHON" ] && BREW_PYTHON="$(command -v python3)"

# 既に現在の python3（または既存の仮想環境）で numpy と HTSeq が使える場合はスキップ
if python3 -c "import numpy, HTSeq" >/dev/null 2>&1; then
    echo ">>> Python ライブラリ (numpy, HTSeq) は既に利用可能です（スキップ）。"
elif [ -x "$VENV_DIR/bin/python3" ] && "$VENV_DIR/bin/python3" -c "import numpy, HTSeq" >/dev/null 2>&1; then
    echo ">>> Python ライブラリ (numpy, HTSeq) は既に $VENV_DIR に導入済みです（スキップ）。"
else
    echo ">>> Homebrew Python 管理領域を保護するため、専用仮想環境 ($VENV_DIR) に導入します..."
    if [ -x "$BREW_PYTHON" ]; then
        if "$BREW_PYTHON" -m venv "$VENV_DIR" && \
           "$VENV_DIR/bin/pip" install --quiet --upgrade pip && \
           "$VENV_DIR/bin/pip" install --quiet numpy HTSeq; then
            echo ">>> numpy と HTSeq のインストールが完了しました。"
        else
            echo -e "${YELLOW}[警告] Python ライブラリ (numpy, HTSeq) のインストールに失敗しました。${NC}"
            FAILED_PACKAGES+=("Pythonライブラリ (numpy, HTSeq)")
        fi
    else
        echo -e "${YELLOW}[警告] python3 が見つからないため Python ライブラリの導入をスキップしました。${NC}"
        FAILED_PACKAGES+=("Pythonライブラリ (numpy, HTSeq)")
    fi
fi

# ------------------------------------------------------------------------------
# 4. パス（PATH）の自動設定（~/.zprofile への安全な追記）
# ------------------------------------------------------------------------------
echo ""
echo "------------------------------------------------------------"
echo " [Step 4/4] パス（PATH）の設定を反映しています..."
echo "------------------------------------------------------------"

ZPROFILE="$HOME/.zprofile"
touch "$ZPROFILE"

# Apple Silicon Mac (/opt/homebrew/bin/brew) の PATH 設定を未登録時のみ追記
if [ "$BREW_BIN" = "/opt/homebrew/bin/brew" ]; then
    BREW_ENV_LINE='eval "$(/opt/homebrew/bin/brew shellenv)"'
    if ! grep -Fqx "$BREW_ENV_LINE" "$ZPROFILE"; then
        {
            echo ""
            echo "# Added by NIBB GITC setup script (Homebrew PATH)"
            echo "$BREW_ENV_LINE"
        } >> "$ZPROFILE"
        echo ">>> $ZPROFILE に Homebrew の PATH 設定を追記しました。"
    else
        echo ">>> $ZPROFILE には既に Homebrew の PATH 設定が存在します（スキップ）。"
    fi
fi

# 専用仮想環境内に htseq-count がある場合、~/bin にリンクを作成して PATH 末尾に追加
if [ -x "$VENV_DIR/bin/htseq-count" ]; then
    mkdir -p "$HOME/bin"
    ln -sfn "$VENV_DIR/bin/htseq-count" "$HOME/bin/htseq-count"

    USER_BIN_LINE='export PATH="$PATH:$HOME/bin"'
    if ! grep -Fqx "$USER_BIN_LINE" "$ZPROFILE"; then
        {
            echo ""
            echo "# Added by NIBB GITC setup script (User bin PATH)"
            echo "$USER_BIN_LINE"
        } >> "$ZPROFILE"
        echo ">>> $ZPROFILE に $HOME/bin の PATH 設定を追記しました。"
    fi
    export PATH="$PATH:$HOME/bin"
fi

# ------------------------------------------------------------------------------
# 5. 環境構築セルフチェック（コマンドの存在・実行確認とバージョン表示）
# ------------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " 環境構築セルフチェック結果"
echo "============================================================"

ALL_OK=true

check_tool() {
    local label="$1"
    local cmd="$2"
    local ver_cmd="$3"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "  ${RED}[NG]${NC} $label （コマンドが見つかりません）"
        ALL_OK=false
        return
    fi

    local ver_out
    if ver_out="$(eval "$ver_cmd" 2>&1 | awk 'NF {print; exit}')"; then
        echo -e "  ${GREEN}[OK]${NC} $label  -->  ${ver_out}"
    else
        echo -e "  ${RED}[NG]${NC} $label （実行ファイルの動作エラー）"
        ALL_OK=false
    fi
}

check_tool "wget" "wget" "wget --version"
check_tool "bowtie2" "bowtie2" "bowtie2 --version"
check_tool "samtools" "samtools" "samtools --version"
check_tool "cutadapt" "cutadapt" "cutadapt --version"
check_tool "fastqc" "fastqc" "fastqc --version"
check_tool "blastn (blast)" "blastn" "blastn -version"
check_tool "fasterq-dump (sratoolkit)" "fasterq-dump" "fasterq-dump --version"
check_tool "seqkit" "seqkit" "seqkit version"
check_tool "python3" "python3" "python3 --version"

# Python ライブラリ（既存環境 または 専用仮想環境 ~/.gitc_venv）の読み込み確認
PY_CHECK_BIN="python3"
if [ -x "$VENV_DIR/bin/python3" ]; then
    PY_CHECK_BIN="$VENV_DIR/bin/python3"
fi

if PY_LIB_VER="$("$PY_CHECK_BIN" -c 'import numpy, HTSeq; print(f"numpy {numpy.__version__}, HTSeq {HTSeq.__version__}")' 2>/dev/null)"; then
    echo -e "  ${GREEN}[OK]${NC} Pythonライブラリ  -->  ${PY_LIB_VER}"
else
    echo -e "  ${RED}[NG]${NC} Pythonライブラリ (numpy, HTSeq)"
    ALL_OK=false
fi

if [ ${#FAILED_PACKAGES[@]} -gt 0 ]; then
    ALL_OK=false
    echo "------------------------------------------------------------"
    echo -e " ${YELLOW}[警告] インストールに失敗した項目:${NC} ${FAILED_PACKAGES[*]}"
fi

echo "============================================================"
if [ "$ALL_OK" = true ]; then
    echo -e " ${GREEN}すべてのソフトウェアの準備が正常に完了しました！${NC}"
    echo " 設定を確実に反映するため、一度ターミナルを完全に終了（Command + Q）して開き直してください。"
else
    echo -e " ${RED}一部のソフトウェアのインストールまたは動作確認が完了しませんでした。${NC}"
    echo " 1. 一度ターミナルを閉じて開き直し、再度 bash setup_mac.sh を実行してください。"
    echo " 2. それでも [NG] が残る場合は、Wiki の「macOS 手動インストール手順」をお試しください。"
fi
echo "============================================================"
echo ""