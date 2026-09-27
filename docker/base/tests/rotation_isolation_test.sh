#!/bin/sh
# server.log の「日付をまたいだあと前日付ファイルへ書き続ける」経路と、
# 実ディレクトリ固定後の経路を、JBoss を起動せずに再現する。
#
# PeriodicRotatingFileHandler の rollover は次の 3 手である。
#   1. 自分の FD を閉じる
#   2. 覚えていたパスで server.log を server.log.<suffix> へ rename する
#   3. 同じパスで server.log を開き直す
# rename と open は実行した瞬間のシンボリックリンクを辿る。
# すでに開いている他プロセスの FD は、名前が変わったあとも同じ inode に書く。
set -eu

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

ok() {
    echo "OK: $*"
}

assert_grep() {
    _file=$1
    _text=$2
    _label=$3
    if [ ! -f "${_file}" ]; then
        fail "${_label}: ファイルがありません: ${_file}"
    fi
    if ! grep -F -q -- "${_text}" "${_file}"; then
        echo "----- ${_file} -----" >&2
        cat "${_file}" >&2 || true
        fail "${_label}: '${_text}' が ${_file} に無い"
    fi
}

assert_absent() {
    if [ -e "$1" ]; then
        fail "$2: 存在してはいけないファイルがある: $1"
    fi
}

# 修正前の経路。共有 current を open / rename に使う。
model_vulnerable_current() {
    _root=$(mktemp -d)
    _mid="${_root}/mid"
    mkdir -p "${_mid}/OLD" "${_mid}/NEW"
    ln -s OLD "${_mid}/current"
    mkdir -p "${_root}/view"
    ln -s "${_mid}/current" "${_root}/view/log"

    exec 3>>"${_root}/view/log/server.log"
    echo "OLD-before-midnight" >&3

    ln -sfn NEW "${_mid}/current"
    exec 4>>"${_root}/view/log/server.log"
    echo "NEW-after-open" >&4

    exec 3>&-
    mv "${_root}/view/log/server.log" "${_root}/view/log/server.log.2026-09-16"
    exec 3>>"${_root}/view/log/server.log"
    echo "OLD-after-rollover" >&3
    echo "NEW-keeps-writing" >&4
    exec 3>&-
    exec 4>&-

    assert_grep "${_mid}/NEW/server.log.2026-09-16" "NEW-after-open" "vulnerable dated"
    assert_grep "${_mid}/NEW/server.log.2026-09-16" "NEW-keeps-writing" "vulnerable dated continues"
    assert_grep "${_mid}/NEW/server.log" "OLD-after-rollover" "vulnerable fresh is old task"
    assert_grep "${_mid}/OLD/server.log" "OLD-before-midnight" "vulnerable old inode kept its name"
    assert_absent "${_mid}/OLD/server.log.2026-09-16" "vulnerable old dir dated"
    rm -rf "${_root}"
    ok "vulnerable model: 後発タスクの追記は server.log.2026-09-16 に入る"
}

# 修正後。各コンテナの log は自分の tmp 経由で実ディレクトリに固定される。
# 共有 current をあとから張り替えても、rename も FD もそちらへ動かない。
model_pinned_directory() {
    _root=$(mktemp -d)
    _mid="${_root}/mid"
    mkdir -p "${_mid}/OLD" "${_mid}/NEW"
    ln -s OLD "${_mid}/current"

    mkdir -p "${_root}/oldv/tmp" "${_root}/newv/tmp"
    ln -s "${_mid}/OLD" "${_root}/oldv/tmp/jboss-log-target"
    ln -s tmp/jboss-log-target "${_root}/oldv/log"
    ln -s "${_mid}/NEW" "${_root}/newv/tmp/jboss-log-target"
    ln -s tmp/jboss-log-target "${_root}/newv/log"

    exec 3>>"${_root}/oldv/log/server.log"
    echo "OLD-before-midnight" >&3

    ln -sfn NEW "${_mid}/current"
    exec 4>>"${_root}/newv/log/server.log"
    echo "NEW-after-open" >&4

    exec 3>&-
    mv "${_root}/oldv/log/server.log" "${_root}/oldv/log/server.log.2026-09-16"
    exec 3>>"${_root}/oldv/log/server.log"
    echo "OLD-after-rollover" >&3
    echo "NEW-keeps-writing" >&4
    exec 3>&-
    exec 4>&-

    assert_grep "${_mid}/OLD/server.log.2026-09-16" "OLD-before-midnight" "pinned old dated"
    assert_grep "${_mid}/OLD/server.log" "OLD-after-rollover" "pinned old fresh"
    assert_grep "${_mid}/NEW/server.log" "NEW-after-open" "pinned new fresh"
    assert_grep "${_mid}/NEW/server.log" "NEW-keeps-writing" "pinned new continues"
    assert_absent "${_mid}/NEW/server.log.2026-09-16" "pinned new dated"
    rm -rf "${_root}"
    ok "pinned model: 後発タスクは server.log のまま、前日付ファイルは先発の中だけ"
}

# 旧イメージ (log -> current) でも、JBOSS_LOG_DIR が実ディレクトリなら
# standalone.sh と同じく rename は実ディレクトリの中で閉じる。
model_old_image_with_jboss_log_dir() {
    _root=$(mktemp -d)
    _mid="${_root}/mid"
    mkdir -p "${_mid}/OLD" "${_mid}/NEW"
    ln -s OLD "${_mid}/current"
    mkdir -p "${_root}/view"
    ln -s "${_mid}/current" "${_root}/view/log"

    _old_dir="${_mid}/OLD"
    _new_dir="${_mid}/NEW"
    exec 3>>"${_old_dir}/server.log"
    echo "OLD-before-midnight" >&3

    ln -sfn NEW "${_mid}/current"
    exec 4>>"${_new_dir}/server.log"
    echo "NEW-after-open" >&4

    exec 3>&-
    mv "${_old_dir}/server.log" "${_old_dir}/server.log.2026-09-16"
    exec 3>>"${_old_dir}/server.log"
    echo "OLD-after-rollover" >&3
    echo "NEW-keeps-writing" >&4
    exec 3>&-
    exec 4>&-

    assert_grep "${_old_dir}/server.log.2026-09-16" "OLD-before-midnight" "prop old dated"
    assert_grep "${_old_dir}/server.log" "OLD-after-rollover" "prop old fresh"
    assert_grep "${_new_dir}/server.log" "NEW-keeps-writing" "prop new fresh"
    assert_absent "${_new_dir}/server.log.2026-09-16" "prop new dated"
    # 共有リンクの解決先は後発へ動いている。開く経路に使うと危ない、という確認。
    _via=$(readlink -f "${_root}/view/log")
    [ "${_via}" = "$(readlink -f "${_new_dir}")" ] || fail "current の解決先が後発になっていない: ${_via}"
    rm -rf "${_root}"
    ok "JBOSS_LOG_DIR model: 旧イメージの共有リンクが動いても実ディレクトリの FD は残る"
}

prepare_jboss_tree() {
    _base=$1
    _style=$2
    _jh="${_base}/opt/jboss-eap"
    mkdir -p "${_jh}/standalone/configuration" \
             "${_jh}/standalone/tmp" \
             "${_jh}/standalone/data" \
             "${_base}/mnt/logs/comp/logs/svc"
    printf '%s\n' 'handler.FILE=org.jboss.logmanager.handlers.PeriodicRotatingFileHandler' \
        > "${_jh}/standalone/configuration/logging.properties"
    printf '%s\n' '<server/>' > "${_jh}/standalone/configuration/standalone.xml"
    rm -rf "${_jh}/standalone/log"
    if [ "${_style}" = "private" ]; then
        ln -s tmp/jboss-log-target "${_jh}/standalone/log"
    else
        ln -s "${_base}/mnt/logs/comp/logs/svc/mid/current" "${_jh}/standalone/log"
    fi
}

run_entrypoint() {
    _base=$1
    _outfile=$2
    shift 2
    # 残りの引数はエントリポイントの CMD。
    JBOSS_HOME="${_base}/opt/jboss-eap" \
    EFS_LOG_DIR="${_base}/mnt/logs/comp/logs/svc" \
    CONFIG_SEED_MODE=skip \
    COMPONENT_ROLE=back \
    Service_Name=interapi \
    /bin/sh "${ENTRYPOINT}" "$@"
    # CMD が outfile を書く。
    [ -f "${_outfile}" ] || fail "エントリポイントの CMD が結果ファイルを書きませんでした: ${_outfile}"
}

entrypoint_private_link_survives_current_flip() {
    _base=$(mktemp -d)
    prepare_jboss_tree "${_base}" private
    _out="${_base}/jboss-log-dir.txt"
    _saved_opts="${JAVA_OPTS-}"
    JAVA_OPTS='-Xmx128m' \
    run_entrypoint "${_base}" "${_out}" \
        /bin/sh -c "printf '%s\n' \"\$JBOSS_LOG_DIR\" > '${_out}'; printf '%s\n' \"\$JAVA_OPTS\" > '${_base}/java-opts.txt'"
    _concrete=$(cat "${_out}")
    [ -d "${_concrete}" ] || fail "JBOSS_LOG_DIR がディレクトリではない: ${_concrete}"
    case "${_concrete}" in
        "${_base}/mnt/logs/comp/logs/svc/mid/"*) ;;
        *) fail "JBOSS_LOG_DIR が mid 配下ではない: ${_concrete}" ;;
    esac
    _resolved=$(readlink -f "${_base}/opt/jboss-eap/standalone/log")
    [ "${_resolved}" = "$(readlink -f "${_concrete}")" ] || fail "private link の解決先が違う: ${_resolved} != ${_concrete}"
    ln -sfn "other-task" "${_base}/mnt/logs/comp/logs/svc/mid/current"
    _resolved2=$(readlink -f "${_base}/opt/jboss-eap/standalone/log")
    [ "${_resolved2}" = "$(readlink -f "${_concrete}")" ] || fail "current 張り替えで log の解決先が動いた: ${_resolved2}"
    _opts=$(cat "${_base}/java-opts.txt")
    [ "${_opts}" = "-Xmx128m" ] || fail "JAVA_OPTS が書き換わった: [${_opts}]"
    rm -rf "${_base}"
    ok "entrypoint: 新しいイメージは current を張り替えても実ディレクトリのまま (JAVA_OPTS は維持、元=${_saved_opts})"
}

entrypoint_old_image_pins_property() {
    _base=$(mktemp -d)
    prepare_jboss_tree "${_base}" current
    _out="${_base}/jboss-log-dir.txt"
    run_entrypoint "${_base}" "${_out}" \
        /bin/sh -c "printf '%s\n' \"\$JBOSS_LOG_DIR\" > '${_out}'"
    _concrete=$(cat "${_out}")
    [ -d "${_concrete}" ] || fail "old image: JBOSS_LOG_DIR が無い: ${_concrete}"
    # 起動直後は current も同じ場所を指す。
    [ "$(readlink -f "${_base}/opt/jboss-eap/standalone/log")" = "$(readlink -f "${_concrete}")" ] \
        || fail "old image: 起動直後の current 解決が実ディレクトリと違う"
    ln -sfn "other-task" "${_base}/mnt/logs/comp/logs/svc/mid/current"
    # 共有リンクの解決先は動く。JBOSS_LOG_DIR の文字列は動かない。
    [ "$(readlink -f "${_base}/opt/jboss-eap/standalone/log")" != "$(readlink -f "${_concrete}")" ] \
        || fail "old image: current を動かしたのに log の解決先が残った (テストの前提が壊れている)"
    case "${_concrete}" in
        *"/other-task"*) fail "old image: JBOSS_LOG_DIR が current の張り替えに追随した: ${_concrete}" ;;
    esac
    rm -rf "${_base}"
    ok "entrypoint: 旧イメージでも JBOSS_LOG_DIR は起動時の実ディレクトリに固定される"
}

entrypoint_strict_rejects_current() {
    _base=$(mktemp -d)
    prepare_jboss_tree "${_base}" current
    _out="${_base}/jboss-log-dir.txt"
    set +e
    LOG_LINK_STRICT=1 \
    JBOSS_HOME="${_base}/opt/jboss-eap" \
    EFS_LOG_DIR="${_base}/mnt/logs/comp/logs/svc" \
    CONFIG_SEED_MODE=skip \
    COMPONENT_ROLE=back \
    Service_Name=interapi \
    /bin/sh "${ENTRYPOINT}" /bin/sh -c "printf '%s\n' \"\$JBOSS_LOG_DIR\" > '${_out}'" \
        >"${_base}/stdout.txt" 2>"${_base}/stderr.txt"
    _st=$?
    set -e
    [ "${_st}" -ne 0 ] || fail "LOG_LINK_STRICT=1 なのに旧イメージで起動できた"
    if ! grep -F -q "共有 current" "${_base}/stderr.txt"; then
        echo "----- stderr -----" >&2
        cat "${_base}/stderr.txt" >&2 || true
        fail "LOG_LINK_STRICT のエラー文言が無い"
    fi
    rm -rf "${_base}"
    ok "entrypoint: LOG_LINK_STRICT=1 は共有 current のイメージを起動しない"
}

start_metadata() {
    _dir=$1
    _port=$2
    mkdir -p "${_dir}"
    # 呼び出し側が ${_dir}/task を用意する。entrypoint は ${URI}/task を取る。
    [ -f "${_dir}/task" ] || fail "メタデータファイルがありません: ${_dir}/task"
    if command -v python3 >/dev/null 2>&1; then
        python3 -m http.server "${_port}" --bind 127.0.0.1 --directory "${_dir}" >"${_dir}/http.log" 2>&1 &
        META_PID=$!
    elif command -v python >/dev/null 2>&1; then
        python -m http.server "${_port}" --bind 127.0.0.1 --directory "${_dir}" >"${_dir}/http.log" 2>&1 &
        META_PID=$!
    elif command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -q '^httpd$'; then
        busybox httpd -f -p "127.0.0.1:${_port}" -h "${_dir}" >"${_dir}/http.log" 2>&1 &
        META_PID=$!
    else
        fail "タスク ID テスト用の HTTP サーバを起動できない (python も busybox httpd も無い)"
    fi
    _i=0
    while [ "${_i}" -lt 50 ]; do
        if wget -q -T 1 -O - "http://127.0.0.1:${_port}/task" >/dev/null 2>&1 \
            || curl -fsS --max-time 1 "http://127.0.0.1:${_port}/task" >/dev/null 2>&1; then
            return 0
        fi
        _i=$((_i + 1))
        sleep 0.1 2>/dev/null || sleep 1
    done
    echo "----- http log -----" >&2
    cat "${_dir}/http.log" >&2 || true
    fail "メタデータサーバが応答しない"
}

stop_metadata() {
    if [ -n "${META_PID:-}" ]; then
        kill "${META_PID}" 2>/dev/null || true
        wait "${META_PID}" 2>/dev/null || true
        META_PID=""
    fi
}

entrypoint_taskid_mode() {
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        fail "curl も wget も無く、taskid モードを試験できない"
    fi
    _base=$(mktemp -d)
    prepare_jboss_tree "${_base}" private
    _port=8765
    mkdir -p "${_base}/meta"
    printf '%s\n' '{"TaskARN":"arn:aws:ecs:ap-northeast-1:123456789012:task/my-cluster/abc123def456"}' > "${_base}/meta/task"
    start_metadata "${_base}/meta" "${_port}"
    _out="${_base}/jboss-log-dir.txt"
    ECS_CONTAINER_METADATA_URI_V4="http://127.0.0.1:${_port}" \
    LOG_ID_MODE=taskid \
    run_entrypoint "${_base}" "${_out}" \
        /bin/sh -c "printf '%s\n' \"\$JBOSS_LOG_DIR\" > '${_out}'"
    _concrete=$(cat "${_out}")
    case "${_concrete}" in
        */abc123def456) ;;
        *)
            stop_metadata
            fail "taskid モードのディレクトリがタスク ID ではない: ${_concrete}"
            ;;
    esac
    # 同一タスク ID で再起動すると同じディレクトリを再利用する。
    _out2="${_base}/jboss-log-dir-2.txt"
    ECS_CONTAINER_METADATA_URI_V4="http://127.0.0.1:${_port}" \
    LOG_ID_MODE=taskid \
    JBOSS_HOME="${_base}/opt/jboss-eap" \
    EFS_LOG_DIR="${_base}/mnt/logs/comp/logs/svc" \
    CONFIG_SEED_MODE=skip \
    COMPONENT_ROLE=back \
    Service_Name=interapi \
    /bin/sh "${ENTRYPOINT}" /bin/sh -c "printf '%s\n' \"\$JBOSS_LOG_DIR\" > '${_out2}'"
    _second=$(cat "${_out2}")
    [ "${_second}" = "${_concrete}" ] || fail "taskid 再起動でディレクトリが変わった: ${_second} != ${_concrete}"
    stop_metadata

    # パス区切りを含むタスク ID は採用せず、timestamp 名へ落とす。
    # ##*/ で最後の要素だけが残る。ドットはディレクトリ名に採用しない。
    printf '%s\n' '{"TaskARN":"arn:aws:ecs:ap-northeast-1:1:task/my-cluster/bad.name"}' > "${_base}/meta/task"
    start_metadata "${_base}/meta" "${_port}"
    _out3="${_base}/jboss-log-dir-3.txt"
    ECS_CONTAINER_METADATA_URI_V4="http://127.0.0.1:${_port}" \
    LOG_ID_MODE=taskid \
    JBOSS_HOME="${_base}/opt/jboss-eap" \
    EFS_LOG_DIR="${_base}/mnt/logs/comp/logs/svc" \
    CONFIG_SEED_MODE=skip \
    COMPONENT_ROLE=back \
    Service_Name=interapi \
    /bin/sh "${ENTRYPOINT}" /bin/sh -c "printf '%s\n' \"\$JBOSS_LOG_DIR\" > '${_out3}'" \
        >"${_base}/stdout3.txt" 2>"${_base}/stderr3.txt"
    _third=$(cat "${_out3}")
    case "${_third}" in
        */bad.name|*/.|*/..) fail "不正なタスク ID をディレクトリに使った: ${_third}" ;;
    esac
    case "${_third}" in
        "${_base}/mnt/logs/comp/logs/svc/mid/"[0-9][0-9][0-9][0-9]*) ;;
        *)
            echo "----- stderr -----" >&2
            cat "${_base}/stderr3.txt" >&2 || true
            stop_metadata
            fail "フォールバック先が timestamp 形式ではない: ${_third}"
            ;;
    esac
    if ! grep -F -q "フォールバック" "${_base}/stderr3.txt"; then
        stop_metadata
        fail "不正タスク ID のフォールバック警告が無い"
    fi
    stop_metadata
    rm -rf "${_base}"
    ok "entrypoint: taskid モードはタスク ID を使い、不正な ID は timestamp へ落とす"
}

entrypoint_taskid_wrapper() {
    _base=$(mktemp -d)
    mkdir -p /usr/local/bin
    cp "${ENTRYPOINT}" /usr/local/bin/efs-entrypoint.sh
    cp "${WRAPPER}" /usr/local/bin/efs-entrypoint-taskid.sh
    chmod 0755 /usr/local/bin/efs-entrypoint.sh /usr/local/bin/efs-entrypoint-taskid.sh
    prepare_jboss_tree "${_base}" private
    _port=8766
    mkdir -p "${_base}/meta"
    printf '%s\n' '{"TaskARN":"arn:aws:ecs:ap-northeast-1:123456789012:task/my-cluster/abc123def456"}' > "${_base}/meta/task"
    start_metadata "${_base}/meta" "${_port}"
    _out="${_base}/jboss-log-dir.txt"
    ECS_CONTAINER_METADATA_URI_V4="http://127.0.0.1:${_port}" \
    JBOSS_HOME="${_base}/opt/jboss-eap" \
    EFS_LOG_DIR="${_base}/mnt/logs/comp/logs/svc" \
    CONFIG_SEED_MODE=skip \
    COMPONENT_ROLE=back \
    Service_Name=interapi \
    /bin/sh /usr/local/bin/efs-entrypoint-taskid.sh \
        /bin/sh -c "printf '%s\n' \"\$JBOSS_LOG_DIR\" > '${_out}'"
    _concrete=$(cat "${_out}")
    case "${_concrete}" in
        */abc123def456) ;;
        *)
            stop_metadata
            fail "ラッパーが taskid モードにならなかった: ${_concrete}"
            ;;
    esac
    stop_metadata

    cp "${WRAPPER}" "${_base}/efs-entrypoint.sh"
    set +e
    /bin/sh "${_base}/efs-entrypoint.sh" /bin/true >"${_base}/wrap-out.txt" 2>"${_base}/wrap-err.txt"
    _st=$?
    set -e
    [ "${_st}" -ne 0 ] || fail "ラッパーを efs-entrypoint.sh の名前で実行できてしまった"
    if ! grep -F -q "上書き" "${_base}/wrap-err.txt"; then
        # 文言は「として配置しています」
        if ! grep -F -q "efs-entrypoint.sh として配置" "${_base}/wrap-err.txt"; then
            cat "${_base}/wrap-err.txt" >&2 || true
            fail "ラッパーの自己名ガード文言が無い"
        fi
    fi
    rm -rf "${_base}"
    ok "entrypoint: taskid ラッパーは本実装を呼び、自分自身への上書きは拒否する"
}

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
ENTRYPOINT="${ROOT}/docker/base/entrypoint.sh"
WRAPPER="${ROOT}/docker/base/entrypoint.taskid.sh"
[ -f "${ENTRYPOINT}" ] || fail "entrypoint が無い: ${ENTRYPOINT}"
[ -f "${WRAPPER}" ] || fail "wrapper が無い: ${WRAPPER}"

model_vulnerable_current
model_pinned_directory
model_old_image_with_jboss_log_dir
entrypoint_private_link_survives_current_flip
entrypoint_old_image_pins_property
entrypoint_strict_rejects_current
entrypoint_taskid_mode
entrypoint_taskid_wrapper

ok "all rotation isolation checks passed"
