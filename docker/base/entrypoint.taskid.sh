#!/bin/sh
# =============================================================================
# efs-entrypoint-taskid.sh
#
# ECS タスク ID をミドルウェアログのディレクトリ名に使う起動入口。
# 実装そのものは entrypoint.sh にあり、本ファイルは LOG_ID_MODE=taskid を
# セットしてそちらへ渡すだけのラッパーである。
#
# 以前このパスに置いていた「タスク ID 版の完全なスクリプト」は使わない。
# あのスクリプトには次が無く、差し替えると server.log が無音になるか、
# 日付をまたぐローリングデプロイで前日付ファイルへ追記する経路が残る。
#   - configuration-seed から configuration への書き戻し
#   - 実ディレクトリへのログパス固定 (current を open / rename に使わない)
#
# 使い方 (いずれか一つ):
#   1. タスク定義の environment に LOG_ID_MODE=taskid を足し、
#      ENTRYPOINT は /usr/local/bin/efs-entrypoint.sh のままにする。
#   2. ENTRYPOINT を /usr/local/bin/efs-entrypoint-taskid.sh に変える。
#      base イメージはこのラッパーをそのパスへ COPY している。
#
# やってはいけないこと:
#   本ファイルを efs-entrypoint.sh という名前で上書きしない。
#   上書きすると、呼び出す実装ファイルが自分自身になり起動できない。
# =============================================================================
set -eu

if [ "$(basename "$0")" = "efs-entrypoint.sh" ]; then
    echo "[efs-entrypoint] FATAL: entrypoint.taskid.sh を efs-entrypoint.sh として配置しています。" >&2
    echo "[efs-entrypoint] FATAL: 実装は entrypoint.sh です。LOG_ID_MODE=taskid を設定するか、" >&2
    echo "[efs-entrypoint] FATAL: ENTRYPOINT を /usr/local/bin/efs-entrypoint-taskid.sh にしてください。" >&2
    exit 1
fi

IMPL="/usr/local/bin/efs-entrypoint.sh"
if [ ! -f "${IMPL}" ]; then
    echo "[efs-entrypoint] FATAL: ${IMPL} がありません。base イメージの COPY を確認してください。" >&2
    exit 1
fi

export LOG_ID_MODE=taskid
exec "${IMPL}" "$@"
