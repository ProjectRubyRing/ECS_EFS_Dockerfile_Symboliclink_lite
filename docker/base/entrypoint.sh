#!/bin/sh
# =============================================================================
# efs-entrypoint.sh
#
# readonlyRootFilesystem=true のタスクでも動作するエントリポイント。
# ルートファイルシステムには一切書き込まず、書き込み先は EFS マウント
# (/mnt/logs, /mnt/data) のみに限定する。
#
# やること:
#   1. EFS 上にアプリログ/ミドルウェアログ用ディレクトリを作成する
#      (イメージビルド時に焼き込んだシンボリックリンクの「実体側」を用意する)
#   2. コンテナ起動時に「起動時刻 + ランダム英数字 8 桁」で一意なディレクトリ名
#      を生成し、/mnt/logs/<Component_name>/logs/<Service_Name>/mid/<一意名> を
#      作成、EFS 上の `current` シンボリックリンクをそのディレクトリへ張り替える。
#      ルート FS 側の /opt/jboss-eap/standalone/log はビルド時に
#      `.../mid/current` へ向けて作成済みのため、2 段リンク経由で
#      起動のたびに一意なディレクトリへ書き込まれる。
#   3. サービスが intra-web かつフロントコンテナの場合のみ、
#      EFS 上に /mnt/data/pdf がなければ作成する。
#
# 一意ディレクトリ名の方針 (ECS タスク ID は使わない):
#   ECS メタデータエンドポイントに依存せず、コンテナ起動時に自前で
#   「起動時刻(YYYYMMDDhhmmss) + '-' + ランダム英数字 8 桁」を生成する。
#   同一 EFS 配下は複数の ECS サービス・複数タスクから同時に呼ばれ得るため、
#   ランダム 8 桁は /dev/urandom (暗号品質のエントロピー) を最優先に生成し、
#   秒精度のタイムスタンプと組み合わせることで衝突確率を実質ゼロにする。
#   /dev/urandom が無い環境向けに uuid / awk 乱数へ多段フォールバックする。
#   さらに生成直後に mkdir で実在チェックし、万一衝突しても引き直す。
#   ※ タスク ID を使う旧実装は entrypoint.taskid.sh に保管している。
#
# 必要な環境変数(すべてイメージビルド時に ENV で焼き込み済み):
#   EFS_LOG_DIR    : /mnt/logs/<Component_name>/logs/<Service_Name>
#   COMPONENT_ROLE : front | back
#   Service_Name   : サービス名 (interapi / intra-api / intra-web(intraweb) / sfapi)
# =============================================================================
set -eu

: "${EFS_LOG_DIR:?EFS_LOG_DIR が未設定です (イメージビルド時の ENV 焼き込み漏れ)}"

# --- ランダム英数字 8 桁の生成 ----------------------------------------------
# [0-9a-z] の 36 文字集合から 8 桁 (36^8 ≒ 2.8e12 通り) を生成する。
# 大文字を含めないのは、目視での紛れや取り回しの事故を避けるため。
# 複数サービス・複数タスクから同時に呼ばれても、秒精度タイムスタンプと
# 合わせて一意になるだけのエントロピーを確保する。
gen_rand8() {
    _r=""
    # 1) /dev/urandom (最優先: 高エントロピー)。head がパイプを閉じても
    #    set -e に影響しないよう、パイプ全体を || true で保護する。
    if [ -r /dev/urandom ]; then
        _r="$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 8 || true)"
    fi
    # 2) カーネル uuid から英数字を抽出 (/dev/urandom が使えない場合)
    if [ "${#_r}" -lt 8 ] && [ -r /proc/sys/kernel/random/uuid ]; then
        _r="$(LC_ALL=C tr -dc 'a-z0-9' < /proc/sys/kernel/random/uuid 2>/dev/null | head -c 8 || true)"
    fi
    # 3) 最後の砦: PID + ナノ秒を種にした awk 乱数 (外部デバイス非依存)
    if [ "${#_r}" -lt 8 ]; then
        _seed="$$$(date +%N 2>/dev/null || echo 0)"
        _r="$(awk -v seed="${_seed}" 'BEGIN{
                srand(seed); c="0123456789abcdefghijklmnopqrstuvwxyz"; s="";
                for(i=0;i<8;i++){ s=s substr(c,int(rand()*36)+1,1) } print s }')"
    fi
    printf '%s' "${_r}"
}

# --- 1. アプリログ用ディレクトリ (シンボリックリンクの実体) ------------------
mkdir -p "${EFS_LOG_DIR}"

# --- 2. ミドルウェア(JBoss EAP)ログ用: 起動時刻-ランダム8桁ディレクトリ -------
MID_DIR="${EFS_LOG_DIR}/mid"
mkdir -p "${MID_DIR}"

# 「起動時刻(秒) + ランダム 8 桁」で起動のたびに一意な名前を作る。
# 万一同一秒・同一乱数で既存ディレクトリと衝突した場合に備え、
# 衝突しない名前になるまで数回だけ引き直す (mkdir は原子的なので、
# 複数タスクが同時に同名を狙っても片方だけが成功する)。
LOG_ID=""
_i=0
while [ "${_i}" -lt 5 ]; do
    _cand="$(date +%Y%m%d%H%M%S)-$(gen_rand8)"
    if mkdir "${MID_DIR}/${_cand}" 2>/dev/null; then
        LOG_ID="${_cand}"
        break
    fi
    _i=$((_i + 1))
done
if [ -z "${LOG_ID}" ]; then
    # ここへ来ることはまず無いが、保険として PID を足して確実に作る
    LOG_ID="$(date +%Y%m%d%H%M%S)-$(gen_rand8)-$$"
    mkdir -p "${MID_DIR}/${LOG_ID}"
fi

# EFS 上の current リンクを今回起動のディレクトリへ張り替える。
# 相対リンクにしておくことで EFS をどこにマウントしても壊れない。
# (-n: current が既存リンクでもリンク先ディレクトリの中に作らない)
ln -sfn "${LOG_ID}" "${MID_DIR}/current"
echo "[efs-entrypoint] JBoss EAP log dir: ${MID_DIR}/${LOG_ID}"

# --- 3. 帳票 pdf ディレクトリ (intra-web のフロントコンテナのみ) -------------
if [ "${COMPONENT_ROLE:-}" = "front" ]; then
    case "${Service_Name:-}" in
        intra-web|intraweb)
            if [ ! -d /mnt/data/pdf ]; then
                mkdir -p /mnt/data/pdf
                echo "[efs-entrypoint] created /mnt/data/pdf"
            fi
            ;;
    esac
fi

# 本来の起動コマンド (CMD) へ制御を渡す
exec "$@"
