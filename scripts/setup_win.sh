#!/usr/bin/env bash
# ==============================================================================
# NIBB ゲノムインフォマティクス・トレーニングコース (GITC 2027 春)
# Windows 11 (WSL2 / Ubuntu 24.04 LTS) 用 解析環境自動セットアップスクリプト
#
# 設計方針:
#   - 不足しているソフトウェアのみを補完し、既存の解析環境（apt / Conda /
#     手動配置ツール・Python 環境）の優先順位や設定は極力変更しない。
#
# 使い方:
#   curl -O https://raw.githubusercontent.com/nibb-unix/gitc202702-unix/main/scripts/setup_win.sh
#   bash setup_win.sh
# ==============================================================================

# 対話的な設定画面（tzdata やサービス再起動確認など）が出ないようにする
export DEBIAN_FRONTEND=noninteractive

# 表示用のカラーコード定義
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 一時作業ディレクトリの作成と終了時の自動クリーンアップ設定
TMP_WORK="$(mktemp -d)"
cleanup() {
    if [ -n "$TMP_WORK" ] && [ -d "$TMP_WORK" ]; then
        rm -rf "$TMP_WORK"
    fi
}
trap cleanup EXIT

# インストールに失敗した項目を記録する配列
FAILED_PACKAGES=()

echo "============================================================"
echo " NIBB GITC 解析環境セットアップ (Windows 11 / Ubuntu 24.04)"
echo "============================================================"
echo ""

# ------------------------------------------------------------------------------
# 0. 実行環境の事前チェック（Ubuntu 24.04 および対応 CPU アーキテクチャの確認）
# ------------------------------------------------------------------------------
OS_NAME="$(uname -s)"
if [ "$OS_NAME" != "Linux" ]; then
    echo -e "${RED}[エラー] このスクリプトは Windows 11 (Ubuntu 24.04 / Linux) 専用です。${NC}"
    echo "macOS をお使いの場合は、setup_mac.sh を使用してください。"
    exit 1
fi

if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    source /etc/os-release
fi

if [ "${ID:-}" != "ubuntu" ] || [ "${VERSION_ID:-}" != "24.04" ]; then
    echo -e "${RED}[エラー] このスクリプトは Ubuntu 24.04 専用です。${NC}"
    echo "検出された OS: ${PRETTY_NAME:-不明}"
    exit 1
fi

ARCH_NAME="$(uname -m)"
case "$ARCH_NAME" in
    x86_64|aarch64)
        ;;
    *)
        echo -e "${RED}[エラー] 非対応の CPU アーキテクチャです: $ARCH_NAME${NC}"
        exit 1
        ;;
esac

echo "検出されたシステム: ${PRETTY_NAME} ($ARCH_NAME)"
echo ""
echo "これより不足している解析ソフトウェアのインストールを開始します。"
echo "途中で [sudo] password for ... と表示されたら、"
echo "Ubuntu の初期設定時にご自身で決めたパスワードを入力して Enter を押してください。"
echo "（※入力中は画面に文字や * は表示されませんが正常に入力されています）"
echo ""

# sudo 権限の事前確認（ここでパスワード認証を済ませる）
if ! sudo -v; then
    echo -e "${RED}[エラー] sudo 認証に失敗しました。パスワードを確認して再実行してください。${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# 1. apt パッケージリストの更新と基本ツールのインストール
# ------------------------------------------------------------------------------
echo "------------------------------------------------------------"
echo " [Step 1/4] Ubuntu パッケージリストを更新しています..."
echo "------------------------------------------------------------"
if ! sudo apt-get update; then
    echo -e "${RED}[エラー] apt パッケージリストの更新に失敗しました。ネットワーク接続を確認してください。${NC}"
    exit 1
fi

echo ""
echo "------------------------------------------------------------"
echo " [Step 2/4] 解析ソフトウェアを一括インストールしています..."
echo " （通信環境により 5〜15 分程度かかる場合があります）"
echo "------------------------------------------------------------"

# Ubuntu 24.04 公式リポジトリのパッケージを導入
# （Python ライブラリはシステム環境との競合を防ぐため apt 公式パッケージのみ使用）
APT_PACKAGES=(
    "curl"
    "wget"
    "unzip"
    "bowtie2"
    "samtools"
    "cutadapt"
    "fastqc"
    "ncbi-blast+"
    "python3"
    "python3-numpy"
    "python3-htseq"
)

for pkg in "${APT_PACKAGES[@]}"; do
    echo ">>> インストール中: $pkg"
    if ! sudo apt-get install -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        "$pkg"; then
        echo -e "${YELLOW}[警告] $pkg のインストールに失敗しました。後続の処理を続行します。${NC}"
        FAILED_PACKAGES+=("$pkg")
    fi
done

# ------------------------------------------------------------------------------
# 2. sratoolkit と seqkit の導入（既存環境がある場合は優先してスキップ）
# ------------------------------------------------------------------------------
echo ""
echo "------------------------------------------------------------"
echo " [Step 3/4] sratoolkit と seqkit を確認・導入しています..."
echo "------------------------------------------------------------"

mkdir -p "$HOME/bin"

# 2-1. SRA Toolkit の導入
if command -v fasterq-dump >/dev/null 2>&1; then
    echo ">>> sratoolkit (fasterq-dump) は既に利用可能です（スキップ）。"
    echo "    使用する実行ファイル: $(command -v fasterq-dump)"
elif [ -x "$HOME/bin/sratoolkit/bin/fasterq-dump" ]; then
    echo ">>> sratoolkit は既に $HOME/bin/sratoolkit に配置済みです（スキップ）。"
else
    if [ "$ARCH_NAME" = "aarch64" ]; then
        # ARM64 (Snapdragon 等) は Ubuntu 24.04 公式パッケージを導入
        echo ">>> ARM64 環境のため apt 経由で sra-toolkit を導入しています..."
        if ! sudo apt-get install -y sra-toolkit; then
            echo -e "${YELLOW}[警告] sra-toolkit のインストールに失敗しました。${NC}"
            FAILED_PACKAGES+=("sra-toolkit")
        fi
    else
        # x86_64 (一般的な Intel / AMD Windows PC) は NCBI 公式バイナリを取得
        echo ">>> sratoolkit (NCBI 公式 Ubuntu バイナリ) をダウンロード・展開しています..."
        SRA_URL="https://ftp-trace.ncbi.nlm.nih.gov/sra/sdk/current/sratoolkit.current-ubuntu64.tar.gz"
        if curl -fsSL -o "$TMP_WORK/sratoolkit.tar.gz" "$SRA_URL"; then
            tar -zxf "$TMP_WORK/sratoolkit.tar.gz" -C "$TMP_WORK"
            SRA_EXTRACTED_DIR="$(find "$TMP_WORK" -maxdepth 1 -type d -name "sratoolkit.*-ubuntu64" | head -n 1)"
            if [ -n "$SRA_EXTRACTED_DIR" ]; then
                rm -rf "$HOME/bin/sratoolkit"
                mv "$SRA_EXTRACTED_DIR" "$HOME/bin/sratoolkit"
                echo ">>> sratoolkit の配置が完了しました。"
            else
                echo -e "${YELLOW}[警告] sratoolkit の展開ディレクトリが見つかりませんでした。${NC}"
                FAILED_PACKAGES+=("sratoolkit")
            fi
        else
            echo -e "${YELLOW}[警告] sratoolkit のダウンロードに失敗しました。${NC}"
            FAILED_PACKAGES+=("sratoolkit")
        fi
    fi
fi

# SRA Toolkit 未設定の新規環境のみ、公式の非対話コマンドでデフォルト設定を初期化
if [ ! -f "$HOME/.ncbi/user-settings.mkfg" ]; then
    if PATH="$PATH:$HOME/bin/sratoolkit/bin" command -v vdb-config >/dev/null 2>&1; then
        echo ">>> SRA Toolkit の初期設定を行っています..."
        PATH="$PATH:$HOME/bin/sratoolkit/bin" vdb-config --restore-defaults >/dev/null 2>&1 || true
    fi
fi

# 2-2. seqkit の導入（既存コマンドを優先し、未導入の場合のみ公式バイナリを取得）
SEQKIT_VER="v2.14.0"
if command -v seqkit >/dev/null 2>&1; then
    echo ">>> seqkit は既に利用可能です（スキップ）。"
    echo "    使用する実行ファイル: $(command -v seqkit)"
elif [ -x "$HOME/bin/seqkit" ]; then
    echo ">>> seqkit は既に $HOME/bin/seqkit に配置済みです（スキップ）。"
else
    echo ">>> seqkit ($SEQKIT_VER) をダウンロード・展開しています..."
    if [ "$ARCH_NAME" = "aarch64" ]; then
        SEQKIT_URL="https://github.com/shenwei356/seqkit/releases/download/${SEQKIT_VER}/seqkit_linux_arm64.tar.gz"
    else
        SEQKIT_URL="https://github.com/shenwei356/seqkit/releases/download/${SEQKIT_VER}/seqkit_linux_amd64.tar.gz"
    fi

    if curl -fsSL -o "$TMP_WORK/seqkit.tar.gz" "$SEQKIT_URL"; then
        tar -zxf "$TMP_WORK/seqkit.tar.gz" -C "$TMP_WORK"
        if [ -f "$TMP_WORK/seqkit" ]; then
            mv "$TMP_WORK/seqkit" "$HOME/bin/seqkit"
            chmod +x "$HOME/bin/seqkit"
            echo ">>> seqkit ($SEQKIT_VER) の配置が完了しました。"
        else
            echo -e "${YELLOW}[警告] seqkit の実行ファイルが見つかりませんでした。${NC}"
            FAILED_PACKAGES+=("seqkit")
        fi
    else
        echo -e "${YELLOW}[警告] seqkit のダウンロードに失敗しました。${NC}"
        FAILED_PACKAGES+=("seqkit")
    fi
fi

# ------------------------------------------------------------------------------
# 3. パス（PATH）の自動設定（~/.bashrc に統一・既存環境の優先順位を維持）
# ------------------------------------------------------------------------------
echo ""
echo "------------------------------------------------------------"
echo " [Step 4/4] パス（PATH）の設定を反映しています..."
echo "------------------------------------------------------------"

# 既存環境（/usr/local/bin や Conda 等）の優先順位を変えないよう末尾に追加する
PATH_LINE='export PATH="$PATH:$HOME/bin:$HOME/bin/sratoolkit/bin"'
RC_FILE="$HOME/.bashrc"

touch "$RC_FILE"
if ! grep -Fxq "$PATH_LINE" "$RC_FILE"; then
    {
        echo ""
        echo "# Added by NIBB GITC setup script"
        echo "$PATH_LINE"
    } >> "$RC_FILE"
    echo ">>> $RC_FILE に PATH 設定を追記しました。"
else
    echo ">>> $RC_FILE には既に同じ PATH 設定が存在します（スキップ）。"
fi

# 現在のスクリプト実行環境にも PATH を即時適用
export PATH="$PATH:$HOME/bin:$HOME/bin/sratoolkit/bin"

# ------------------------------------------------------------------------------
# 4. 環境構築セルフチェック（コマンドの存在・実行確認とバージョン表示）
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

check_tool "curl" "curl" "curl --version"
check_tool "unzip" "unzip" "unzip -v"
check_tool "bowtie2" "bowtie2" "bowtie2 --version"
check_tool "samtools" "samtools" "samtools --version"
check_tool "cutadapt" "cutadapt" "cutadapt --version"
check_tool "fastqc" "fastqc" "fastqc --version"
check_tool "blastn (ncbi-blast+)" "blastn" "blastn -version"
check_tool "fasterq-dump (sratoolkit)" "fasterq-dump" "fasterq-dump --version"
check_tool "seqkit" "seqkit" "seqkit version"
check_tool "python3 (/usr/bin/python3)" "/usr/bin/python3" "/usr/bin/python3 --version"

# apt で導入したシステム Python 上のライブラリ読み込み確認
if [ -x /usr/bin/python3 ] && PY_LIB_VER="$(/usr/bin/python3 -c 'import numpy, HTSeq; print(f"numpy {numpy.__version__}, HTSeq {HTSeq.__version__}")' 2>/dev/null)"; then
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
    echo " 設定を確実に反映するため、一度ターミナルを閉じて開き直してください。"
else
    echo -e " ${RED}一部のソフトウェアのインストールまたは動作確認が完了しませんでした。${NC}"
    echo " 1. 一度ターミナルを閉じて開き直し、再度 bash setup_win.sh を実行してください。"
    echo " 2. それでも [NG] が残る場合は、Wiki の「手動インストール」手順をお試しください。"
fi
echo "============================================================"