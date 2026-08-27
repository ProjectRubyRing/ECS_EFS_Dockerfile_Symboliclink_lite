# トラブルシュート — ECS で server.log に何も出ない / エラーも出ない

対象症状:

> ECS 上でタスクを起動しても `server.log` に一切ログが出力されず、
> CloudWatch (awslogs) 側にも明確なエラーが見当たらない。
> **同等の Docker Compose 環境ではエラーが再現しない。**

本書は `configuration-seed` → `configuration` の書き戻し (seed 方式) を
導入した構成を前提に、原因の切り分けと恒久対応をまとめる。
設計の全体像は [`DESIGN.md`](./DESIGN.md)、採用しなかった案は
[`REJECTED_ALTERNATIVES.md`](./REJECTED_ALTERNATIVES.md) を参照。
`cp -a` が非 0 終了する条件だけを掘り下げたものは
[`CP_PRESERVE_OWNERSHIP.md`](./CP_PRESERVE_OWNERSHIP.md)。

---

## 1. 前提 — Compose と ECS の 3 つの差分

seed 方式はこの 3 つ全部に触るため、Compose で再現しないのはほぼ必然である。

| # | 差分 | 効き方 |
|---|------|--------|
| 1 | **`readonlyRootFilesystem=true`** | Compose は `read_only` 未指定＝ルート FS 書き込み可。ECS だけ `cp` が `EROFS` で落ちる |
| 2 | **空ボリュームへのイメージ内容の自動コピー** | Docker の **named volume は初回マウント時にイメージ側の中身を自動コピーする**。**ECS (Fargate エフェメラル / EFS) は一切コピーしない** |
| 3 | **EFS アクセスポイントの uid/gid 強制** | Compose のバインドマウントは root で素通り。ECS は uid/gid が強制され `cp` / `mkdir` / `ln` が `EACCES` |

### 特に #2 が本症状の核心

seed 方式を入れたということは、ECS 側で
`/opt/jboss-eap/standalone/configuration` に**書き込み可能ボリュームを
マウントしている**はずである。

- **Compose**: named volume が勝手にイメージの `configuration` を埋めるため、
  **書き戻し処理が壊れていても正常に起動してしまう**（＝バグが隠蔽される）
- **ECS**: ボリュームは空でマウントされる。書き戻しに失敗した瞬間に
  `configuration` が空になる

つまり Compose 環境は、この不具合に対して**テストとして機能していない**。
6 章の手順で Compose 側を ECS に寄せること。

---

## 2. なぜ「完全に無音」になるのか

JBoss EAP がここまで黙るパターンは限られており、原因はかなり絞り込める。

### 2-1. `logging.properties` が無いと JBoss は無音になる

JBoss EAP の起動時ロギングは次でブートストラップされる。

```
-Dlogging.configuration=file:$JBOSS_HOME/standalone/configuration/logging.properties
```

**この 1 ファイルが欠けると CONSOLE ハンドラも FILE ハンドラも構成されず、
`server.log` は作られず標準出力にも何も出ない。**
`configuration` が空になる＝この状態に直行する。

### 2-2. 本番構成では出力先が `server.log` だけのことが多い

`standalone.xml` から console-handler を外している場合、出力先は
`server.log` のみ。その `server.log` が
`/opt/jboss-eap/standalone/log`（＝EFS への 2 段リンク）に書けなければ、
やはり全部消える。

**結論**: 症状から **「configuration が空/不完全」または「log リンクの先に
書けない」のどちらか（あるいは両方）** に絞れる。

---

## 3. 原因候補（優先度順）

| 優先 | 原因 | 決定的な確認方法 |
|:---:|------|------------------|
| 🔴 | **A. 書き戻し失敗で `configuration` が空/部分的** | `ls -la $JBOSS_HOME/standalone/configuration/` |
| 🔴 | **B. `configuration` 以外の可変領域が read-only** | `touch $JBOSS_HOME/standalone/tmp/.w` |
| 🟠 | **C. log の 2 段リンクが解決できない/書けない** | `readlink -f $JBOSS_HOME/standalone/log` |
| 🟠 | **D. そもそもコンテナが起動していない** | `aws ecs describe-tasks` の `stoppedReason` |
| 🟡 | **E. `configuration` を EFS 共有にして同時上書き** | マウント種別が EFS か確認 |
| 🟡 | **F. stdout が awslogs に届いていない** | `standalone.conf` のリダイレクト有無 |

### 🔴 A. 書き戻しが失敗して configuration が空 / 部分的（最有力）

ECS でだけ失敗する典型パターン。

| 書き方 | 何が起きるか |
|---|---|
| `cp -a seed/. configuration/` が **EROFS** | `configuration` にボリュームを当て忘れている（readonlyRootFilesystem 下）。`set -eu` なら entrypoint が即死、`\|\| true` を付けていると空のまま起動して無音 |
| `cp -a` が **chown 失敗で非 0 終了** | `-a`(＝`-p`) の所有権保持が `chown` の EPERM で失敗する。**ファイルはコピーされているのに終了コードは 1** → `set -e` で entrypoint 死。**EFS アクセスポイント固有ではなく、非 root 実行 (`USER jboss`) ならタスクローカルボリューム上でも必ず起きる**。→ **`-a` / `-p` を使わず `cp -R` にする**。条件の全体像は [`CP_PRESERVE_OWNERSHIP.md`](./CP_PRESERVE_OWNERSHIP.md) |
| `cp` が **`cannot create regular file ... Permission denied`** | コピー**先**の既存エントリを上書きできない。ディレクトリは書けるのにファイルだけ落ちる場合は、**前回タスクが別 uid・group write 無しで作った残存ファイル**が原因。`cp -Rf` (open に失敗したら unlink して作り直す) で解消する。サブディレクトリごと書けない場合はボリュームの永続化をやめるか中身を作り直す。→ [3-A-1](#3-a-1-cannot-create-regular-file--permission-denied-の切り分け) |
| `cp -r seed/* configuration/` | **ドットファイルを拾わない**。→ **`cp -R seed/. configuration/`（末尾 `/.`）にする** |
| `cp -a seed configuration/` | `configuration/configuration-seed/` が出来るだけで中身は空 |
| コピー先が **EACCES** | EFS AP の ownerUid/ownerGid と実行 uid の不一致、`elasticfilesystem:ClientWrite` 欠落、EFS ファイルシステムポリシーの root squash |

**結果はどれも同じ: `logging.properties` が無い → 完全無音。**

#### 3-A-1. `cannot create regular file ... Permission denied` の切り分け

```
cp: cannot create regular file '/opt/jboss-eap/standalone/configuration/./standalone.xml': Permission denied
[efs-entrypoint] FATAL: seed の書き戻しに失敗しました
```

`failed to preserve ownership`（`cp -a` の chown 失敗。→
[`CP_PRESERVE_OWNERSHIP.md`](./CP_PRESERVE_OWNERSHIP.md)）とは**別物**である。
こちらは `open(O_WRONLY|O_CREAT|O_TRUNC)` 自体が `EACCES` で、
**コピーは 1 バイトも行われていない**。

`open` が `EACCES` になる条件は 2 つしかない。

| # | 条件 | 見分け方 | 対処 |
|:-:|------|----------|------|
| 1 | **既存ファイル**に write 権限が無い（別 uid 所有・`0644` など） | エラーに出るパスが `ls -l` で自分以外の所有 / `-rw-r--r--` | **`cp -Rf`**。ディレクトリに write 権限があれば unlink して作り直せる |
| 2 | **親ディレクトリ**に write 権限が無い | `ls -ld <親>` が自分以外の所有かつ group write 無し / `touch <親>/.w` も失敗 | AP の uid/gid・`ClientWrite` を直す。永続ボリュームなら中身を作り直す |

entrypoint は `#1` を自動で解消し（`cp -Rf` + コピー後の `chmod -R g+rwX`）、
`#2` なら書けないパスを列挙して落ちる。

```
[efs-entrypoint] 考えられる原因: ...
---------- configuration permissions ----------
# id
# ls -ld /opt/jboss-eap/standalone/configuration
# /opt/jboss-eap/standalone/configuration 配下で書き込めない既存エントリ (先頭 20 件)
```

**なぜ `is_writable` を通ったのに落ちるのか**: `is_writable` は
`configuration` 直下に新規ファイルを 1 つ作れるかしか見ていない。
`#1`（既存ファイルの上書き）も `#2`（サブディレクトリ）もこの検査は素通りする。

**恒久対策**: `configuration` にはタスクローカルの**エフェメラル**ボリュームを
当てる（毎起動で空 → 残存ファイルが原理的に発生しない）。
EFS など永続ストレージを当てている場合は、uid が変わるたびに同じ問題が起きる。

---

### 🔴 B. configuration 以外の書き込み先が read-only のまま

seed で `configuration` だけ救済しても、JBoss EAP は起動時に以下へ書く。
`readonlyRootFilesystem=true` では全部 `EROFS` になる。

```
standalone/tmp/          ← VFS 展開。ここが書けないと起動最初期で死ぬ
standalone/data/         ← content リポジトリ
standalone/deployments/  ← デプロイスキャナ
standalone/configuration/standalone_xml_history/   ← configuration 直下に作る
standalone/log/          ← 本構成では EFS へリンク済み
```

特に **`standalone_xml_history/`** は `configuration` 直下に作られるため、
`configuration` をボリューム化していないと確実に失敗する。
`tmp/vfs` の失敗はロギング構成より前段なので、`logging.properties` 不在と
重なると例外ごと握り潰されて無音になる。

### 🟠 C. log の 2 段リンクが解決できていない / 書けない

- entrypoint が A で死んでいれば `mid/<起動時刻-ランダム8桁>` も `current` も
  作られず、`/opt/jboss-eap/standalone/log` は **dangling symlink** のまま
- **書き戻し処理を entrypoint の先頭に置くと A の失敗が C を連鎖させる**
- 単独でも起き得る: EFS AP の uid/gid で
  `ln -sfn ... "${MID_DIR}/current"` が `EACCES`
  （既存 `current` が別 uid 所有 + 親ディレクトリに group write が無い）
- `umask 002` は入っているが、**既存ディレクトリの権限までは直さない**

### 🟠 D. そもそもコンテナが起動していない

「ECS の各ログに何も無い」場合、コンテナが 1 度も走っていない線を先に潰すこと。
この場合ロググループのログストリームすら作られない。

- `ResourceInitializationError: failed to invoke EFS utils`
  — SG の 2049 未開放、マウントターゲットが AZ に無い、DNS 解決不可、IAM 不足
- awslogs ロググループ未作成（`awslogs-create-group: "true"` 未指定）
  → **ログドライバ初期化失敗でコンテナ起動不可**
- イメージ pull 失敗、ヘルスチェック即失敗による再起動ループ

→ **CloudWatch より先に `stoppedReason` / `containers[].reason` /
`exitCode` とサービスイベントを見る。**

### 🟡 E. configuration を EFS 共有にした場合の同時上書き

`configuration` のマウント先が EFS で、複数タスク／ローリングデプロイ中の
新旧タスクが同じパスを共有していると、**起動のたびに全タスクが seed で
上書きする**。他タスクが読んでいる最中の `standalone.xml` が差し替わり、
パースエラーや 0 バイト読み込みが起きる。Compose は単一なので再現しない。

→ **`configuration` はタスクローカルなエフェメラルボリュームにすること。
EFS 共有にしてはいけない。**

### 🟡 F. stdout が awslogs に届いていない

- `standalone.conf` や独自ラッパーで `> .../server.log 2>&1` に
  リダイレクトしていると PID1 の stdout は無音
- ログドライバが awsfirelens 経由で流路が別
- タスクメモリが小さく JVM が起動途中で OOM kill（exit 137）

---

## 4. 切り分け手順

### Step 1 — コンテナが起動したのかを確定する

```bash
aws ecs describe-tasks --cluster <cluster> --tasks <task-arn> \
  --query 'tasks[0].{stopped:stoppedReason,containers:containers[].{name:name,exit:exitCode,reason:reason}}'

aws ecs describe-services --cluster <cluster> --services <svc> \
  --query 'services[0].events[:10]'
```

### Step 2 — ECS Exec で中を見る（決定打）

```bash
aws ecs execute-command --cluster <c> --task <t> --container <name> \
  --interactive --command /bin/sh
```

```sh
id                                            # 実行 uid/gid（EFS AP と一致しているか）
mount | grep -E 'standalone|/mnt'             # configuration に何がマウントされ、ro か

ls -la /opt/jboss-eap/standalone/
ls -la /opt/jboss-eap/standalone/configuration/        # ★ logging.properties / standalone.xml があるか
ls -la /opt/jboss-eap/standalone/configuration-seed/   # seed 側は健在か
readlink -f /opt/jboss-eap/standalone/log              # ★ dangling でないか
ls -la /mnt/logs/*/logs/*/mid/                         # current と実体ディレクトリがあるか

# 書き込みテスト（EROFS か EACCES かで原因が割れる）
for d in configuration tmp data deployments log; do
    p=/opt/jboss-eap/standalone/$d
    if touch "$p/.w" 2>/dev/null; then rm -f "$p/.w"; echo "OK   $p"; else echo "NG   $p"; fi
done
```

### Step 3 — 手で JBoss を起動して黙っている理由を出す

```sh
/opt/jboss-eap/bin/standalone.sh -b 0.0.0.0 2>&1 | head -50
```

### Step 4 — entrypoint の preflight 出力を読む

本リポジトリの `docker/base/entrypoint.sh` は JBoss へ制御を渡す前に
必要条件をすべて検証し、満たさなければ理由を明示して `exit 1` する。
正常時は以下が CloudWatch に出る。

```
[efs-entrypoint] configuration を復元しました (mode=overwrite, 12 エントリ)
[efs-entrypoint] JBoss EAP log dir: /mnt/logs/intra-web-front/logs/intra-web/mid/20260827104512-x7sk1z0e
[efs-entrypoint] log -> /mnt/logs/intra-web-front/logs/intra-web/mid/20260827104512-x7sk1z0e (書き込み可)
[efs-entrypoint] preflight OK. starting: /opt/jboss-eap/bin/standalone.sh -b 0.0.0.0
```

**この 4 行が出ていなければ、出ていない行の直前が失敗箇所**である。
異常時は `FATAL:` 行に続けて `id` / `ls -la standalone` / `mount` /
`readlink -f log` の診断ダンプが出力される。

---

## 5. seed 方式を維持する場合の対応

`configuration-seed` 方式はそのまま維持できる。ただし**タスク定義側の
ボリューム設定とセットでなければ成立しない**。本リポジトリの実装は以下。

### 5-1. ビルド時 — `docker/base/Dockerfile`

`configuration` を `configuration-seed` へ退避する。
**この RUN は必ず JBoss EAP 導入 RUN の「後ろ」に置くこと。**

```dockerfile
ARG STRICT_SEED=0
RUN set -eu; \
    mkdir -p "${JBOSS_HOME}/standalone"; \
    if [ -d "${JBOSS_CONF_DIR}" ] && [ -n "$(ls -A "${JBOSS_CONF_DIR}" 2>/dev/null)" ]; then \
        rm -rf "${JBOSS_CONF_SEED_DIR}"; \
        mkdir -p "${JBOSS_CONF_SEED_DIR}"; \
        cp -a "${JBOSS_CONF_DIR}/." "${JBOSS_CONF_SEED_DIR}/"; \
        rm -rf "${JBOSS_CONF_SEED_DIR}/standalone_xml_history"; \
        chmod -R g+rwX "${JBOSS_CONF_SEED_DIR}"; \
        test -f "${JBOSS_CONF_SEED_DIR}/logging.properties" || exit 1; \
    fi
```

要点:

- **末尾 `/.` が必須**。`${SRC}/*` はドットファイルを取りこぼし、
  `${SRC}` は `dst/configuration-seed/` を作ってしまう
- ビルド時は root かつ同一 FS なので `-a` で問題ない
  （所有権を保持しない `cp -R` を使うのは**起動時側だけ**）
- `chmod -R g+rwX` — EFS AP で同一 gid・別 uid のタスクが更新できるように
- `standalone_xml_history` は起動のたびに JBoss が作り直すので seed から除く
- `logging.properties` の存在を**ビルド時に検証**して、無音死するイメージを
  そもそも作らせない
- CI では `--build-arg STRICT_SEED=1` を付け、seed が空ならビルドを失敗させる

### 5-2. 起動時 — `docker/base/entrypoint.sh`

```sh
    prepare_conf_tree      # seed 側のディレクトリ構造を先に作り、既存には g+rwX を試みる

    # cp のオプションに注意:
    #   -a / -p は所有権を保持しようとするが、EFS アクセスポイントは
    #   uid/gid を強制するため chown が必ず失敗し、「ファイルはコピー
    #   できているのに終了コードが非 0」になる。set -e と組み合わさると
    #   ここで無音死する典型パターンなので使わない。
    #   -f は既存の書き込み不可ファイルを unlink して作り直す。
    #   「cannot create regular file ... Permission denied」の対策 (3 章 A-1)。
    if ! cp -Rf "${SEED_DIR}/." "${CONF_DIR}/"; then
        dump_conf_perm     # 書けないパスを列挙してから落とす
        die "seed の書き戻しに失敗しました (${SEED_DIR} -> ${CONF_DIR})"
    fi

    # 次回起動 (同一 gid・別 uid) が上書きできるように付け直す (best-effort)
    chmod -R g+rwX "${CONF_DIR}" 2>/dev/null || true
```

> **`-a` を避ける理由は EFS アクセスポイント固有ではない。**
> `-a`(＝`-p`) は `chown(2)` を呼ぶため、**非 root 実行 (`USER jboss`) なら
> コピー先がタスクローカルボリュームであっても必ず EPERM になる**。
> EFS 直マウントでも `ClientRootAccess` が無ければ root ごと squash されて同じ結果。
> 条件の全体像と EFS 抜きの最小再現は
> [`CP_PRESERVE_OWNERSHIP.md`](./CP_PRESERVE_OWNERSHIP.md) を参照。

書き戻しの前後で以下を検証し、満たさなければ理由を出して `exit 1` する。

| 検証 | 落ちる理由 |
|---|---|
| `SEED_DIR` の存在・非空 | base のビルドで seed 作成に失敗している |
| `CONF_DIR` への**実書き込み** | ボリューム未マウント (EROFS) / uid gid 不一致 (EACCES) |
| `CONF_DIR` 配下の**既存エントリの上書き可否** | 残存ファイルは `cp -Rf` が unlink して解消。ディレクトリ側が書けない場合は該当パスを列挙して `exit 1` (3 章 A-1) |
| `CONF_DIR/logging.properties` | **無いと JBoss が完全に無音で死ぬ** |
| `CONF_DIR/${JBOSS_CONFIG_FILE}` | 設定ファイル名の不一致 |
| `standalone/log` の `readlink -f` | 2 段リンクが dangling |
| `standalone/log` 解決先への実書き込み | `server.log` が作れない＝無音 |
| `standalone/tmp` `standalone/data` への実書き込み | 起動最初期で死ぬ (B) |
| `standalone/deployments` `content` | 警告のみ |

書き込み可否は `mount` のパースではなく**実際に `touch` して判定**する。
`readonlyRootFilesystem` による `EROFS` と EFS AP による `EACCES` の
両方を取りこぼさないため。

環境変数で挙動を切り替えられる。

| 変数 | 既定 | 意味 |
|---|---|---|
| `CONFIG_SEED_MODE` | `overwrite` | `overwrite`=毎起動上書き（推奨）/ `missing`=設定ファイルが無いときだけ復元 / `skip`=復元しない（configuration を永続化する運用） |
| `JBOSS_CONFIG_FILE` | `standalone.xml` | 起動に使う設定ファイル名 |

> `overwrite` は上書きであり、seed に無い残存ファイルの削除は行わない。
> タスクローカルのエフェメラルボリュームなら毎起動空なので問題にならない。

### 5-3. タスク定義 — ここが無いと seed 方式は成立しない

`configuration` / `tmp` / `data` に**書き込み可能ボリューム**を当てる。

```jsonc
{
  "containerDefinitions": [{
    "name": "intra-web-front",
    "readonlyRootFilesystem": true,
    "environment": [
      { "name": "Service_Name",     "value": "intra-web" },
      { "name": "Component_name",   "value": "intra-web-front" },
      { "name": "CONFIG_SEED_MODE", "value": "overwrite" }
    ],
    "mountPoints": [
      { "sourceVolume": "logs", "containerPath": "/mnt/logs" },
      { "sourceVolume": "data", "containerPath": "/mnt/data" },

      // ↓ seed 方式に必須。ホストパス無しのボリューム = タスクローカル
      { "sourceVolume": "front-jboss-conf", "containerPath": "/opt/jboss-eap/standalone/configuration" },
      { "sourceVolume": "front-jboss-tmp",  "containerPath": "/opt/jboss-eap/standalone/tmp" },
      { "sourceVolume": "front-jboss-data", "containerPath": "/opt/jboss-eap/standalone/data" }
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/intra-web",
        "awslogs-region": "ap-northeast-1",
        "awslogs-stream-prefix": "front",
        "awslogs-create-group": "true"
      }
    }
  }],
  "volumes": [
    { "name": "logs", "efsVolumeConfiguration": { "fileSystemId": "fs-xxxx", "rootDirectory": "/logs-root" } },
    { "name": "data", "efsVolumeConfiguration": { "fileSystemId": "fs-xxxx", "rootDirectory": "/data-root" } },

    // efsVolumeConfiguration も host も指定しない = タスクスコープの空ボリューム
    { "name": "front-jboss-conf" },
    { "name": "front-jboss-tmp"  },
    { "name": "front-jboss-data" }
  ]
}
```

**注意点:**

1. **1 ボリューム = 1 マウント先。** `configuration` / `tmp` / `data` は
   別々のボリューム名にすること（同じ `sourceVolume` を複数の
   `containerPath` に当てると中身を共有してしまう）。
2. **front と back で別のボリューム名にすること。** 同一タスク内の
   別コンテナが同じ `sourceVolume` を指すと `configuration` を共有し、
   互いに seed で上書きし合う（E と同じ問題がタスク内で起きる）。
3. **`configuration` を EFS にしない。** タスクローカルのエフェメラル
   ボリュームにする（E 参照）。
4. **Fargate のエフェメラルストレージ容量**に注意。既定 20GiB、
   `ephemeralStorage` で最大 200GiB まで拡張可。
5. **EC2 起動タイプで `dockerVolumeConfiguration`（`autoprovision`）を
   使うと Docker ボリューム由来の自動コピーが働く**場合があり、Fargate と
   挙動が変わる。本実装は自動コピーに依存しないのでどちらでも動作する。

### 5-4. `entrypoint.taskid.sh` に切り替える場合

保管してある旧実装（タスク ID 方式）には
**「1. configuration の復元」ブロックと fail-fast 検証が入っていない。**
切り替える際は `entrypoint.sh` の当該ブロックを必ず移植すること。
移植しないまま ECS で動かすと、本書冒頭の症状がそのまま再発する。

---

## 6. Compose を ECS に寄せて再現させる

現状の Compose は 1 章 #1 と #2 の差分を素通ししており、**テストとして
機能していない**。以下 2 行を足せば ECS の失敗がローカルで再現する。

```yaml
services:
  front:
    read_only: true                                   # ← readonlyRootFilesystem=true 相当
    user: "185:185"                                   # ← EFS アクセスポイントの uid/gid 相当
    volumes:
      - type: volume
        source: front-jboss-conf
        target: /opt/jboss-eap/standalone/configuration
        volume:
          nocopy: true                                # ← ★ イメージからの自動コピーを無効化（ECS と同じ挙動）
      - type: volume
        source: front-jboss-tmp
        target: /opt/jboss-eap/standalone/tmp
        volume: { nocopy: true }
      - type: volume
        source: front-jboss-data
        target: /opt/jboss-eap/standalone/data
        volume: { nocopy: true }
      - ./local-efs/logs:/mnt/logs
      - ./local-efs/data:/mnt/data

volumes:
  front-jboss-conf:
  front-jboss-tmp:
  front-jboss-data:
```

**`nocopy: true` と `read_only: true` の 2 つが、ECS だけで落ちる原因を
ローカルに引きずり出す。** CI のスモークテストにはこの構成を使うこと。

---

## 7. チェックリスト

デプロイ前に以下を確認する。

- [ ] base イメージを `--build-arg STRICT_SEED=1` でビルドし、
      `[base] seeded ...: N files` が出ている（N > 0）
- [ ] seed に `logging.properties` と `standalone.xml` が含まれる
- [ ] タスク定義に `configuration` / `tmp` / `data` の書き込み可能ボリュームがある
- [ ] それらのボリューム名が front / back で重複していない
- [ ] `configuration` 用ボリュームが EFS ではなくタスクローカルである
- [ ] `awslogs-create-group: "true"` を指定している
- [ ] EFS のセキュリティグループで 2049/tcp が開いている
- [ ] EFS アクセスポイントの uid/gid とコンテナ実行ユーザーが一致している
- [ ] タスクロールに `elasticfilesystem:ClientMount` / `ClientWrite` がある
- [ ] Compose 側に `read_only: true` + `nocopy: true` を入れて再現テスト済み
- [ ] 起動後 CloudWatch に `[efs-entrypoint] preflight OK.` が出ている
