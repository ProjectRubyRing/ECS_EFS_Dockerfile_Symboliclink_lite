#!/bin/sh
# =============================================================================
# efs-entrypoint.sh
#
# readonlyRootFilesystem=true のタスクでも動作するエントリポイント。
# 書き込み先は EFS マウント (/mnt/logs, /mnt/data) と、タスク定義で
# 「書き込み可能ボリューム」を当てた JBoss の standalone 配下ディレクトリのみ。
#
# やること:
#   0. 診断ヘルパーの定義。
#      異常時は必ず「何が・どこで・なぜ」を出力してから終了する。
#      無音で落ちないことが本スクリプト最大の設計目標である (理由は下記)。
#   1. configuration の復元 (configuration-seed → configuration)
#      イメージビルド時に作った configuration-seed を起動時に書き戻す。
#      ECS では configuration に「空の」書き込み可能ボリュームがマウントされる
#      ため、この復元をしないと JBoss の設定一式が丸ごと消える。
#   2. EFS 上にアプリログ用ディレクトリを作成する
#      (イメージビルド時に焼き込んだシンボリックリンクの「実体側」を用意する)
#   3. コンテナ起動時に「起動時刻 + ランダム英数字 8 桁」で一意なディレクトリ名
#      を生成し、/mnt/logs/<Component_name>/logs/<Service_Name>/mid/<一意名> を
#      作成、EFS 上の `current` シンボリックリンクをそのディレクトリへ張り替える。
#      ルート FS 側の /opt/jboss-eap/standalone/log はビルド時に
#      `.../mid/current` へ向けて作成済みのため、2 段リンク経由で
#      起動のたびに一意なディレクトリへ書き込まれる。
#   4. JBoss が起動時に書き込む standalone 配下の可変ディレクトリを
#      「実際に書き込んでみて」検証する。
#   5. サービスが intra-web かつフロントコンテナの場合のみ、
#      EFS 上に /mnt/data/pdf がなければ作成する。
#
# 【なぜ fail-fast と事前検証にここまでこだわるのか】
#   JBoss EAP の起動時ロギングは
#     -Dlogging.configuration=file:<configuration>/logging.properties
#   でブートストラップされる。この 1 ファイルが欠けると CONSOLE ハンドラも
#   FILE ハンドラも構成されず、server.log は作られず標準出力にも何も出ない。
#   つまり「configuration の復元に失敗する」= 「原因が一切ログに残らないまま
#   コンテナが黙って死ぬ」という最悪の障害モードに直結する。
#   本スクリプトは JBoss へ制御を渡す前に必要条件をすべて検証し、
#   満たさない場合は理由を明示して exit 1 する。
#   詳細は docs/TROUBLESHOOTING.md を参照。
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
#      そちらには本ファイルの「1. configuration の復元」が入っていないため、
#      切り替える際は当該ブロックを必ず移植すること。
#
# 必要な環境変数(すべてイメージビルド時に ENV で焼き込み済み):
#   EFS_LOG_DIR    : /mnt/logs/<Component_name>/logs/<Service_Name>
#   COMPONENT_ROLE : front | back
#   Service_Name   : サービス名 (interapi / intra-api / intra-web(intraweb) / sfapi)
#   JBOSS_HOME     : JBoss EAP のインストール先 (既定 /opt/jboss-eap)
#
# 任意の環境変数(タスク定義から上書き可能):
#   CONFIG_SEED_MODE  : overwrite (既定) | missing | skip
#                       overwrite = 毎起動 seed で上書きする (推奨)
#                       missing   = 設定ファイルが無いときだけ復元する
#                       skip      = 復元しない (configuration を永続化する運用)
#   JBOSS_CONFIG_FILE : 起動に使う設定ファイル名 (既定 standalone.xml)
# =============================================================================
set -eu

# --- 0. umask 設定 -----------------------------------------------------------
# 既定の umask 022 では、以下で作成するディレクトリが 0755 (group に write 権限
# なし) になる。EFS アクセスポイントで同一 gid・別 uid の後続タスクが
# `mid/<一意名>` ディレクトリを作成/更新しようとすると group write 不可で
# 失敗する。umask 002 に切り替えて 0775 (group write 可) で作成させ、
# ディレクトリの作成失敗を防ぐ。
umask 002

# --- 0-1. 診断ヘルパー -------------------------------------------------------
JBOSS_HOME="${JBOSS_HOME:-/opt/jboss-eap}"
STANDALONE_DIR="${JBOSS_HOME}/standalone"

say() {
    echo "[efs-entrypoint] $*"
}

# 異常終了時は必ず「現場の状態」を添えて落とす。
# ECS では CloudWatch (awslogs) が stdout/stderr を拾うため、
# ここで出した情報だけが唯一の手掛かりになることが多い。
dump_diag() {
    {
        echo "---------------- diagnostics ----------------"
        echo "# id"
        id 2>/dev/null || true
        echo "# ls -la ${STANDALONE_DIR}"
        ls -la "${STANDALONE_DIR}" 2>/dev/null || true
        echo "# mount (standalone / mnt のみ)"
        mount 2>/dev/null | grep -E 'standalone|/mnt' || echo "(該当マウント無し)"
        echo "# readlink -f ${STANDALONE_DIR}/log"
        readlink -f "${STANDALONE_DIR}/log" 2>/dev/null || echo "(解決不能 = dangling symlink)"
        echo "---------------------------------------------"
    } >&2
}

die() {
    echo "[efs-entrypoint] FATAL: $*" >&2
    dump_diag
    exit 1
}

# 予期しない箇所での set -e 停止も無音にしない (exec 後は発火しない)
on_exit() {
    _st=$?
    if [ "${_st}" -ne 0 ]; then
        echo "[efs-entrypoint] FATAL: エントリポイントが異常終了しました (exit=${_st})" >&2
    fi
}
trap on_exit EXIT

# ディレクトリが「本当に書き込めるか」を実書き込みで判定する。
# mount 情報のパースではなく実書き込みで見ることで、
#   - readonlyRootFilesystem=true によるボリューム未マウント (EROFS)
#   - EFS アクセスポイントの uid/gid 不一致 (EACCES)
# の双方を取りこぼさずに検出できる。
is_writable() {
    _d="$1"
    [ -d "${_d}" ] || return 1
    _probe="${_d}/.efs-entrypoint-writetest.$$"
    if ( : > "${_probe}" ) 2>/dev/null; then
        rm -f "${_probe}" 2>/dev/null || true
        return 0
    fi
    return 1
}

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

# =============================================================================
# 1. configuration の復元 (configuration-seed → configuration)
# =============================================================================
# readonlyRootFilesystem=true では JBoss が configuration に書けない
# (standalone_xml_history の作成すら失敗する)。そのためタスク定義で
# /opt/jboss-eap/standalone/configuration に書き込み可能ボリュームを当てるが、
# ECS のボリュームは「空」でマウントされ、イメージ内の中身は見えなくなる。
# そこでビルド時に退避しておいた configuration-seed から毎起動書き戻す。
#
# 【Compose では失敗が表面化しない理由】
#   Docker の named volume は初回マウント時にイメージ側の中身を自動コピーする
#   (nocopy: true を指定しない限り)。したがってこの復元処理が壊れていても
#   Compose では正常に起動してしまう。ECS/Fargate は一切コピーしないため、
#   復元が失敗した瞬間に configuration が空になり JBoss が無音で死ぬ。
# -----------------------------------------------------------------------------
CONF_DIR="${JBOSS_CONF_DIR:-${STANDALONE_DIR}/configuration}"
SEED_DIR="${JBOSS_CONF_SEED_DIR:-${STANDALONE_DIR}/configuration-seed}"
CONFIG_SEED_MODE="${CONFIG_SEED_MODE:-overwrite}"
JBOSS_CONFIG_FILE="${JBOSS_CONFIG_FILE:-standalone.xml}"

restore_configuration() {
    [ -d "${SEED_DIR}" ] \
        || die "seed ディレクトリ ${SEED_DIR} がありません。base イメージのビルドで configuration-seed の作成に失敗しています。"

    if [ -z "$(ls -A "${SEED_DIR}" 2>/dev/null)" ]; then
        die "seed ディレクトリ ${SEED_DIR} が空です。base イメージのビルド時点で ${CONF_DIR} が空だった可能性があります。"
    fi

    # configuration 自体が無い場合、作れるのはルート FS が書ける環境だけ。
    # ECS (readonlyRootFilesystem=true) では失敗するが、その場合は
    # 直後の is_writable でより分かりやすいメッセージを出す。
    [ -d "${CONF_DIR}" ] || mkdir -p "${CONF_DIR}" 2>/dev/null || true

    if ! is_writable "${CONF_DIR}"; then
        echo "[efs-entrypoint] 考えられる原因:" >&2
        echo "[efs-entrypoint]   (a) タスク定義で ${CONF_DIR} に書き込み可能ボリュームを" >&2
        echo "[efs-entrypoint]       マウントしていない。readonlyRootFilesystem=true のため" >&2
        echo "[efs-entrypoint]       ルート FS 上のこのパスは EROFS になる。" >&2
        echo "[efs-entrypoint]   (b) EFS/アクセスポイントの uid/gid と実行ユーザーの不一致 (EACCES)。" >&2
        echo "[efs-entrypoint] 対処: タスク定義の volumes / mountPoints に" >&2
        echo "[efs-entrypoint]       { \"sourceVolume\": \"<name>\", \"containerPath\": \"${CONF_DIR}\" }" >&2
        echo "[efs-entrypoint]       を追加する。詳細は docs/TROUBLESHOOTING.md を参照。" >&2
        die "${CONF_DIR} に書き込めません。"
    fi

    if [ "${CONFIG_SEED_MODE}" = "missing" ] && [ -f "${CONF_DIR}/${JBOSS_CONFIG_FILE}" ]; then
        say "CONFIG_SEED_MODE=missing かつ ${JBOSS_CONFIG_FILE} が既存のため復元をスキップ"
        return 0
    fi

    # cp のオプションに注意:
    #   -a / -p は所有権とタイムスタンプを保持しようとするが、EFS アクセス
    #   ポイントは uid/gid を強制するため chown が必ず失敗し、
    #   「ファイルはコピーできているのに終了コードが非 0」になる。
    #   set -e と組み合わさるとここで無音死する典型パターンなので使わない。
    #   -R (保持なし) なら新規ファイルは実行 uid の所有になり、
    #   パーミッションビットは seed 側 (ビルド時に g+rwX 済み) が引き継がれる。
    #   なお `cp -R "${SEED_DIR}/." "${CONF_DIR}/"` の末尾 `/.` が重要で、
    #   `seed/*` ではドットファイルを取りこぼし、`seed` では
    #   configuration/configuration-seed/ が出来てしまう。
    # 本処理は上書きであり、seed に存在しない残存ファイルの削除は行わない。
    cp -R "${SEED_DIR}/." "${CONF_DIR}/" \
        || die "seed の書き戻しに失敗しました (${SEED_DIR} -> ${CONF_DIR})"

    say "configuration を復元しました (mode=${CONFIG_SEED_MODE}, $(ls -A1 "${CONF_DIR}" 2>/dev/null | wc -l) エントリ)"
}

case "${CONFIG_SEED_MODE}" in
    overwrite|missing)
        restore_configuration
        ;;
    skip)
        say "CONFIG_SEED_MODE=skip のため configuration の復元を行いません"
        ;;
    *)
        die "CONFIG_SEED_MODE の値が不正です: '${CONFIG_SEED_MODE}' (overwrite|missing|skip)"
        ;;
esac

# 復元後の必須ファイル検証。
# logging.properties が無いと JBoss は「server.log も標準出力も完全に無音」の
# まま起動に失敗する。ここで落として理由を残すのが本チェックの目的である。
if [ ! -f "${CONF_DIR}/logging.properties" ]; then
    echo "[efs-entrypoint] このファイルが無いと JBoss EAP は起動時ロギングを構成できず、" >&2
    echo "[efs-entrypoint] server.log も標準出力も完全に無音のまま起動に失敗します。" >&2
    echo "[efs-entrypoint] seed の作成漏れ (cp -r seed/* のようにドットファイルを取りこぼす" >&2
    echo "[efs-entrypoint] 書き方) か、ボリュームの二重マウントを疑ってください。" >&2
    die "${CONF_DIR}/logging.properties がありません。"
fi
[ -f "${CONF_DIR}/${JBOSS_CONFIG_FILE}" ] \
    || die "${CONF_DIR}/${JBOSS_CONFIG_FILE} がありません。JBOSS_CONFIG_FILE の値と seed の内容を確認してください。"

# =============================================================================
# 2. アプリログ用ディレクトリ (シンボリックリンクの実体)
# =============================================================================
mkdir -p "${EFS_LOG_DIR}" \
    || die "${EFS_LOG_DIR} を作成できません。EFS のマウント状態とアクセスポイントの uid/gid を確認してください。"

# =============================================================================
# 3. ミドルウェア(JBoss EAP)ログ用: 起動時刻-ランダム8桁ディレクトリ
# =============================================================================
MID_DIR="${EFS_LOG_DIR}/mid"
mkdir -p "${MID_DIR}" || die "${MID_DIR} を作成できません。"

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
    mkdir -p "${MID_DIR}/${LOG_ID}" \
        || die "${MID_DIR}/${LOG_ID} を作成できません。EFS の書き込み権限を確認してください。"
fi

# EFS 上の current リンクを今回起動のディレクトリへ張り替える。
# 相対リンクにしておくことで EFS をどこにマウントしても壊れない。
# (-n: current が既存リンクでもリンク先ディレクトリの中に作らない)
ln -sfn "${LOG_ID}" "${MID_DIR}/current" \
    || die "current リンクを張り替えられません (${MID_DIR}/current)。既存 current の所有者と ${MID_DIR} の group write 権限を確認してください。"
say "JBoss EAP log dir: ${MID_DIR}/${LOG_ID}"

# =============================================================================
# 4. JBoss が書き込む standalone 配下ディレクトリの検証
# =============================================================================
# readonlyRootFilesystem=true では、書き込み可能ボリュームを当てていない限り
# 以下はすべて EROFS になる。configuration だけ seed で救済しても、
# tmp / data が書けなければ JBoss はロギング構成より前段で落ち、
# やはり無音のまま終了する。実書き込みで検証して先に潰す。

# log は 2 段リンクの解決先が実在し、かつ書けることまで確認する
LOG_LINK="${STANDALONE_DIR}/log"
LOG_REAL="$(readlink -f "${LOG_LINK}" 2>/dev/null || true)"
if [ -z "${LOG_REAL}" ] || [ ! -d "${LOG_REAL}" ]; then
    die "${LOG_LINK} の解決に失敗しました (dangling symlink)。ビルド時のリンク先と EFS_LOG_DIR='${EFS_LOG_DIR}' が一致しているか確認してください。"
fi
is_writable "${LOG_REAL}" \
    || die "${LOG_LINK} -> ${LOG_REAL} に書き込めません。server.log を作成できないため JBoss は無音になります。EFS アクセスポイントの uid/gid を確認してください。"
say "log -> ${LOG_REAL} (書き込み可)"

# 起動に必須の可変ディレクトリ (書けなければ起動不能なので落とす)
for _d in tmp data; do
    _p="${STANDALONE_DIR}/${_d}"
    [ -d "${_p}" ] || continue
    if ! is_writable "${_p}"; then
        echo "[efs-entrypoint] JBoss EAP は起動時に standalone/tmp (VFS 展開) と" >&2
        echo "[efs-entrypoint] standalone/data に書き込みます。readonlyRootFilesystem=true では" >&2
        echo "[efs-entrypoint] 書き込み可能ボリュームのマウントが必須です。" >&2
        echo "[efs-entrypoint] タスク定義に containerPath=${_p} のマウントを追加してください。" >&2
        die "${_p} に書き込めません。"
    fi
done

# 必須ではないが書けないと機能が制限されるディレクトリ (警告のみ)
for _d in deployments content; do
    _p="${STANDALONE_DIR}/${_d}"
    [ -d "${_p}" ] || continue
    is_writable "${_p}" \
        || echo "[efs-entrypoint] WARN: ${_p} に書き込めません (デプロイスキャナ等が制限されます)" >&2
done

# =============================================================================
# 5. 帳票 pdf ディレクトリ (intra-web のフロントコンテナのみ)
# =============================================================================
if [ "${COMPONENT_ROLE:-}" = "front" ]; then
    case "${Service_Name:-}" in
        intra-web|intraweb)
            if [ ! -d /mnt/data/pdf ]; then
                mkdir -p /mnt/data/pdf || die "/mnt/data/pdf を作成できません。"
                say "created /mnt/data/pdf"
            fi
            ;;
    esac
fi

say "preflight OK. starting: $*"

# 本来の起動コマンド (CMD) へ制御を渡す
exec "$@"
