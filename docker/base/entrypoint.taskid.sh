#!/bin/sh
# =============================================================================
# efs-entrypoint.taskid.sh  【保管用・旧実装 (ビルドには未使用)】
#
# これは「JBoss EAP ミドルウェアログのディレクトリ名に ECS タスク ID を使う」
# 旧実装をそのまま保管したファイルである。現在 base イメージがビルドで
# COPY するのは entrypoint.sh (起動時刻-ランダム8桁方式) であり、本ファイルは
# 参照用として残している。タスク ID 方式へ戻したい場合は base の Dockerfile の
# COPY 対象をこのファイルに差し替えればよい。
#   COPY entrypoint.taskid.sh /usr/local/bin/efs-entrypoint.sh
#
# ★★ 切り替え時の必須作業 ★★
#   本ファイルには entrypoint.sh に後から追加した以下が入っていない。
#     - 「1. configuration の復元 (configuration-seed → configuration)」ブロック
#     - die / dump_diag / is_writable による fail-fast と事前検証
#   これらが無いまま ECS (readonlyRootFilesystem=true + configuration に
#   書き込み可能ボリューム) で動かすと、configuration が空のまま JBoss が起動し、
#   logging.properties 不在により **server.log にも標準出力にも一切ログが出ない**
#   まま失敗する。切り替える場合は entrypoint.sh の当該ブロックを必ず移植すること。
#   背景と対処は docs/TROUBLESHOOTING.md を参照。
# -----------------------------------------------------------------------------
# efs-entrypoint.sh (旧)
#
# readonlyRootFilesystem=true のタスクでも動作するエントリポイント。
# ルートファイルシステムには一切書き込まず、書き込み先は EFS マウント
# (/mnt/logs, /mnt/data) のみに限定する。
#
# やること:
#   1. EFS 上にアプリログ/ミドルウェアログ用ディレクトリを作成する
#      (イメージビルド時に焼き込んだシンボリックリンクの「実体側」を用意する)
#   2. ECS メタデータエンドポイント v4 から ECS タスク ID を取得し、
#      /mnt/logs/<Component_name>/logs/<Service_Name>/mid/<タスクID> を作成、
#      EFS 上の `current` シンボリックリンクをそのディレクトリへ張り替える。
#      ルート FS 側の /opt/jboss-eap/standalone/log はビルド時に
#      `.../mid/current` へ向けて作成済みのため、2 段リンク経由で
#      タスクごとに一意なディレクトリへ書き込まれる。
#   3. タスク ID が取得できない場合は「起動時刻 + ランダム値」による
#      代替ディレクトリ名で同じ一意性を担保する。
#   4. サービスが intra-web かつフロントコンテナの場合のみ、
#      EFS 上に /mnt/data/pdf がなければ作成する。
#
# 必要な環境変数(すべてイメージビルド時に ENV で焼き込み済み):
#   EFS_LOG_DIR    : /mnt/logs/<Component_name>/logs/<Service_Name>
#   COMPONENT_ROLE : front | back
#   Service_Name   : サービス名 (interapi / intra-api / intra-web(intraweb) / sfapi)
# =============================================================================
set -eu

: "${EFS_LOG_DIR:?EFS_LOG_DIR が未設定です (イメージビルド時の ENV 焼き込み漏れ)}"

# --- 1. アプリログ用ディレクトリ (シンボリックリンクの実体) ------------------
mkdir -p "${EFS_LOG_DIR}"

# --- 2. ミドルウェア(JBoss EAP)ログ用: タスク ID ディレクトリ ----------------
MID_DIR="${EFS_LOG_DIR}/mid"
mkdir -p "${MID_DIR}"

TASK_ID=""
if [ -n "${ECS_CONTAINER_METADATA_URI_V4:-}" ]; then
    # curl / wget どちらが入っていても動くようにフォールバックする
    META="$(curl -fsS --max-time 5 "${ECS_CONTAINER_METADATA_URI_V4}/task" 2>/dev/null \
         || wget -q -T 5 -O - "${ECS_CONTAINER_METADATA_URI_V4}/task" 2>/dev/null \
         || true)"
    # jq が無い前提で TaskARN を抜き出す
    # 例: arn:aws:ecs:ap-northeast-1:123456789012:task/my-cluster/0123456789abcdef0123456789abcdef
    TASK_ARN="$(printf '%s' "${META}" | sed -n 's/.*"TaskARN"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    TASK_ID="${TASK_ARN##*/}"
fi

if [ -z "${TASK_ID}" ]; then
    # --- 3. 代替ディレクトリ名 (メタデータ未取得時のフォールバック) ---------
    # 「起動時刻(秒) + ランダム 8 桁」でタスク切替のたびに一意な名前になる。
    RAND="$(cut -c1-8 /proc/sys/kernel/random/uuid 2>/dev/null || echo "$$")"
    TASK_ID="$(date +%Y%m%d%H%M%S)-${RAND}"
    echo "[efs-entrypoint] WARN: ECS タスク ID を取得できないため代替名 ${TASK_ID} を使用します" >&2
fi

mkdir -p "${MID_DIR}/${TASK_ID}"
# EFS 上の current リンクを今回タスクのディレクトリへ張り替える。
# 相対リンクにしておくことで EFS をどこにマウントしても壊れない。
# (-n: current が既存リンクでもリンク先ディレクトリの中に作らない)
ln -sfn "${TASK_ID}" "${MID_DIR}/current"
echo "[efs-entrypoint] JBoss EAP log dir: ${MID_DIR}/${TASK_ID}"

# --- 4. 帳票 pdf ディレクトリ (intra-web のフロントコンテナのみ) -------------
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
