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

# --- 0. umask 設定 -----------------------------------------------------------
# 既定の umask 022 では、以下で作成するディレクトリが 0755 (group に write 権限
# なし) になる。EFS アクセスポイントで同一 gid・別 uid の後続タスクが
# `mid/<タスクID>` ディレクトリを作成/更新しようとすると group write 不可で
# 失敗する。umask 002 に切り替えて 0775 (group write 可) で作成させ、
# タスク ID ディレクトリの作成失敗を防ぐ。
umask 002

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
