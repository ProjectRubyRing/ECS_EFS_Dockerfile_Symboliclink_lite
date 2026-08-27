# ECS + EFS シンボリックリンク設計解説

対象: ECS クラスタ上の 4 サービス (`interapi` / `intra-api` / `intra-web(intraweb)` / `sfapi`)。
各タスクはフロントコンテナ・バックコンテナ・サイドカーコンテナで構成され、
フロント/バックは EFS を `/mnt/logs` (アプリログ・ミドルウェアログ) と
`/mnt/data` (帳票ファイル) にマウントする。
タスク定義は `readonlyRootFilesystem=true` で運用する。

> 起動しても `server.log` に何も出ない / ECS のログにもエラーが出ない、
> といった症状の切り分けは [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md) を参照。

---

## 1. 全体像 (リンク構成図)

```
【ルートFS = イメージビルド時に作成 (起動後は read-only)】

  フロントコンテナ
    /webapp/webapp9mf02/logs ──────────────► /mnt/logs/<Component_name>/logs/<Service_Name>
    /webapp/webapp9mf02/pdf  ──────────────► /mnt/data/pdf          ※ intra-web のみ作成
    /opt/jboss-eap/standalone/log ─────────► /mnt/logs/<Component_name>/logs/<Service_Name>/mid/current

  バックコンテナ
    /webapp/webapp9mb02/logs ──────────────► /mnt/logs/<Component_name>/logs/<Service_Name>
    /opt/jboss-eap/standalone/log ─────────► /mnt/logs/<Component_name>/logs/<Service_Name>/mid/current

【タスクローカルの書き込み可能ボリューム = 起動のたびに空でマウントされる】

  /opt/jboss-eap/standalone/configuration ◄── 起動時に configuration-seed から書き戻す
  /opt/jboss-eap/standalone/tmp           … JBoss の VFS 展開先
  /opt/jboss-eap/standalone/data          … content リポジトリ

  /opt/jboss-eap/standalone/configuration-seed   … ルート FS (ビルド時に退避・読み取り専用)

【EFS 上 = エントリポイントがタスク起動のたびに作成 (常に書き込み可)】

    /mnt/logs/<Component_name>/logs/<Service_Name>/            … アプリログ実体
    /mnt/logs/<Component_name>/logs/<Service_Name>/mid/
        ├── current ──► <起動時刻-ランダム8桁>  (起動ごとに ln -sfn で張り替え)
        ├── <起動時刻-ランダム8桁-1>/       … 前々回起動の JBoss ログ (残存)
        ├── <起動時刻-ランダム8桁-2>/       … 前回起動の JBoss ログ (残存)
        └── <起動時刻-ランダム8桁-3>/       … 今回起動の JBoss ログ ◄─ current
    /mnt/data/pdf/                          … intra-web フロントの起動時に無ければ作成
```

> ディレクトリ名は例:`20260722103045-x7sk1z0e`
> (`起動時刻(YYYYMMDDhhmmss)` + `-` + `ランダム英数字8桁`)。
> ECS タスク ID を使う旧方式は `docker/base/entrypoint.taskid.sh` に保管している
> (下記 3 章および `REJECTED_ALTERNATIVES.md` 案 A' を参照)。

## 2. なぜこの構成なのか — readonlyRootFilesystem=true との両立

`readonlyRootFilesystem=true` のコンテナは、**起動後にルートファイルシステムへ
一切書き込めない**。したがって:

- ルート FS 側に置くもの (シンボリックリンク 3 種、既存 log ディレクトリの削除、
  `configuration-seed` の作成) は **必ずイメージビルド時 (Dockerfile の RUN)**
  に済ませる。
- 起動後に書き込みが必要なもの (ログ実体ディレクトリ、起動ごとのディレクトリ、
  `current` リンクの張り替え、`/mnt/data/pdf` の作成) は **すべて EFS マウント上**
  で行う。EFS ボリュームは readonlyRootFilesystem の制約対象外であり、
  タスク定義側で read-only 指定をしない限り書き込み可能。
- **JBoss 自身が書き込むディレクトリ** (`standalone/configuration`,
  `standalone/tmp`, `standalone/data`) は EFS ではなく**タスクローカルの
  書き込み可能ボリューム**を当てる。`configuration` の中身はマウントで
  覆い隠されるため、ビルド時に退避した `configuration-seed` から
  エントリポイントが書き戻す (7 章)。

この分担により、起動後のルート FS 書き込みはゼロになる。

## 3. JBoss EAP ログの「起動ごとの一意性」— 2 段リンク方式 (採用案)

### 課題

要件は `/opt/jboss-eap/standalone/log` を
`/mnt/logs/<コンテナ名>/logs/<サービス名>/mid/<一意名>` に向けること。
しかし **一意名 (元々は ECS タスク ID) はイメージビルド時には確定できない**。
同一イメージから何百ものタスクが起動されるため、ビルド時に一意値を焼き込んでも
「全タスクで共通」になってしまう。一方、リンク自体はビルド時に作るしかない
(2 章の制約)。

### 解決: リンクを 2 段に分ける

1. **ビルド時 (ルート FS 側)**:
   `/opt/jboss-eap/standalone/log → /mnt/logs/<Component_name>/logs/<Service_Name>/mid/current`
   という「固定の」リンクを作成する。一意名を含まないためビルド時に確定できる。
2. **起動時 (EFS 側)**: エントリポイント `efs-entrypoint.sh` が
   - コンテナ起動時に `起動時刻(YYYYMMDDhhmmss)-ランダム英数字8桁` の一意名を生成する
   - `mid/<一意名>` ディレクトリを作成する (mkdir は原子的なので、同時起動でも衝突しない)
   - EFS 上のリンク `mid/current` を `ln -sfn <一意名> mid/current` で張り替える

JBoss がログを書くときのパス解決は
`/opt/jboss-eap/standalone/log` → `mid/current` → `mid/<今回の一意名>`
と 2 段で辿られ、**コンテナが起動し直すたびに新しいディレクトリへ書き込まれる**。
過去起動のディレクトリは EFS 上にそのまま残るため、
前の起動のログとの一意性が維持される。

### 一意ディレクトリ名の生成方式 — 起動時刻 + ランダム英数字 8 桁

ディレクトリ名は ECS タスク ID には依存せず、コンテナ起動時に自前で生成する。

- 形式: `起動時刻(YYYYMMDDhhmmss)` + `-` + `ランダム英数字8桁`
  (例: `20260722103045-x7sk1z0e`)。
- ランダム 8 桁は `[0-9a-z]` の 36 文字集合 (36^8 ≒ 2.8×10^12 通り)。
  生成は **`/dev/urandom` (暗号品質のエントロピー) を最優先**とし、
  使えない環境向けに `カーネル uuid` → `awk 乱数 (PID+ナノ秒シード)` へ多段
  フォールバックする。
- **同一 EFS を複数の ECS サービス・複数タスクが同時に使っても一意になる**。
  秒精度のタイムスタンプと高エントロピーな 8 桁の組み合わせで衝突確率は実質ゼロだが、
  さらに生成直後に `mkdir` で実在チェックし、万一衝突した場合は名前を引き直す
  (`mkdir` は原子的なので、同名を同時に狙った複数プロセスのうち成功するのは 1 つだけ)。

この方式では ECS メタデータエンドポイントを一切呼ばないため、ローカルの
`docker run` でもクラウドの ECS でも同じ挙動になる (環境差が無い)。

> **ECS タスク ID を使う旧実装について**
> ディレクトリ名に本物の ECS タスク ID を使う従来実装は
> `docker/base/entrypoint.taskid.sh` にそのまま保管している。
> `aws ecs describe-tasks` や CloudWatch のタスク ID とログを突き合わせたい
> 場合はこちらへ戻せる (base の Dockerfile の `COPY` 対象を差し替えるだけ)。
> トレードオフは `REJECTED_ALTERNATIVES.md` 案 A / 案 A' を参照。

## 4. Service_Name / Component_name の渡し方 (検討と採用)

タスク定義には環境変数 `Service_Name`(サービス名)・`Component_name`(コンテナ名)
が設定されるが、これは**タスク起動後にしか存在しない**。シンボリックリンクは
ビルド時に作る必要があるため、値の入手経路を次のとおり整理した。

| # | 経路 | 利用可能タイミング | 採否 |
|---|------|-------------------|------|
| 1 | `docker build --build-arg Service_Name=… --build-arg Component_name=…` | ビルド時 | **採用 (リンク作成用)** |
| 2 | タスク定義の environment (`Service_Name` / `Component_name`) | 起動後 | 採用 (エントリポイントの補助・突合せ用) |
| 3 | ECS メタデータエンドポイント v4 の `ServiceName` / コンテナ `Name` | 起動後 | 参考 (ビルド時に使えないため主経路にしない) |
| 4 | SSM パラメータストア / Secrets Manager | ビルド時・起動後 | 不採用 (build-arg で足りる。外部依存が増えるだけ) |

- **ビルド時**は CI (CodeBuild / GitHub Actions 等) がサービスごとに
  `--build-arg` を渡す。Dockerfile は値の未指定を `RUN test -n` で即エラーにする。
- 受け取った値は `ENV Service_Name` / `ENV Component_name` としてイメージに焼き込み、
  さらに **リンク先パス全体を `ENV EFS_LOG_DIR` として確定**させる。
  エントリポイントはこの `EFS_LOG_DIR` だけを見てディレクトリを作るため、
  タスク定義側の環境変数とビルド引数の値が万一食い違っても、
  「ビルド時に作ったリンク」と「起動時に作る実体」が必ず一致する。
- **起動時**のメタデータエンドポイント v4 は、タスクメタデータに `ServiceName`、
  コンテナメタデータに `Name`、`TaskARN` (タスク ID) を含むため、環境変数を使わずに
  同じ情報を取得することも可能である。ただしこれはあくまで起動後の話であり、
  ビルド時のリンク作成には使えない。**現行実装 (`entrypoint.sh`) はメタデータ
  エンドポイントを一切使わず**、ミドルウェアログのディレクトリ名も
  「起動時刻-ランダム8桁」で自前生成する。タスク ID を用いる旧実装
  (`entrypoint.taskid.sh`) のみメタデータエンドポイントからタスク ID を取得する。

**帰結**: イメージは「サービス × コンポーネント」ごとに個別ビルドとなる
(4 サービス × front/back = 最大 8 イメージ)。これはリンク先パスに
サービス名を焼き込むという要件の必然的な帰結である。
単一イメージで済ませたい場合の代替案は `REJECTED_ALTERNATIVES.md` の案 E を参照。

## 5. ビルドとデプロイの流れ

```bash
# 1. base (全サービス共通・1 回だけ)
#    JBoss EAP 導入済みの本番ビルドでは STRICT_SEED=1 を付け、
#    configuration-seed の作成漏れをビルド時に検出させる (7 章)。
docker build -t myapp-base:latest --build-arg STRICT_SEED=1 docker/base

# 2. front / back (サービスごとに build-arg を変えてビルド)
docker build -t interapi-front:latest \
  --build-arg BASE_IMAGE=myapp-base:latest \
  --build-arg Service_Name=interapi \
  --build-arg Component_name=interapi-front \
  docker/front

docker build -t interapi-back:latest \
  --build-arg BASE_IMAGE=myapp-base:latest \
  --build-arg Service_Name=interapi \
  --build-arg Component_name=interapi-back \
  docker/back
# … intra-api / intra-web / sfapi も同様
```

タスク定義側の要点:

```jsonc
{
  "containerDefinitions": [{
    "name": "interapi-front",                       // = Component_name
    "readonlyRootFilesystem": true,
    "environment": [
      { "name": "Service_Name",   "value": "interapi" },
      { "name": "Component_name", "value": "interapi-front" }
    ],
    "mountPoints": [
      { "sourceVolume": "logs", "containerPath": "/mnt/logs" },
      { "sourceVolume": "data", "containerPath": "/mnt/data" },

      // ↓ seed 方式に必須 (7 章)。JBoss が書き込む領域をタスクローカルの
      //   空ボリュームへ逃がす。front / back でボリューム名を分けること。
      { "sourceVolume": "front-jboss-conf", "containerPath": "/opt/jboss-eap/standalone/configuration" },
      { "sourceVolume": "front-jboss-tmp",  "containerPath": "/opt/jboss-eap/standalone/tmp" },
      { "sourceVolume": "front-jboss-data", "containerPath": "/opt/jboss-eap/standalone/data" }
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/interapi",
        "awslogs-region": "ap-northeast-1",
        "awslogs-stream-prefix": "front",
        "awslogs-create-group": "true"
      }
    }
  }],
  "volumes": [
    { "name": "logs", "efsVolumeConfiguration": { "fileSystemId": "fs-xxxx", "rootDirectory": "/logs-root" } },
    { "name": "data", "efsVolumeConfiguration": { "fileSystemId": "fs-xxxx", "rootDirectory": "/data-root" } },

    // efsVolumeConfiguration も host も指定しない = タスクスコープの空ボリューム。
    // configuration は EFS 共有にしないこと (タスク間で上書きし合うため)。
    { "name": "front-jboss-conf" },
    { "name": "front-jboss-tmp"  },
    { "name": "front-jboss-data" }
  ]
}
```

## 6. 運用上の注意点

1. **同一サービスの並行タスク (desiredCount > 1) と `current` リンク**
   同じサービス・同じコンポーネントのタスクが複数同時に走ると、後から起動した
   タスクが `current` を自分の一意名へ張り替える。各タスクの実体ディレクトリ
   (`mid/<起動時刻-ランダム8桁>`) は一意なので **混ざらないが**、`current` は
   「最後に起動したタスク」を指すため、先行タスクがローテーションで新規作成する
   ファイルは後発タスクのディレクトリ側へ入り得る (open 済みファイルハンドルは
   影響なし)。この `current` 競合の性質はタスク ID 方式でも同じである。
   desiredCount=1 (ローリング時の一時 2 タスクは許容) なら実害はほぼ無いが、
   常時複数タスクで厳密な分離が必要なら `REJECTED_ALTERNATIVES.md` の
   案 C (jboss.server.log.dir) か案 D (エフェメラルボリューム間接リンク) を検討すること。
2. **EFS のパーミッション**: コンテナの実行ユーザー (例: jboss, uid=185) が
   `/mnt/logs` `/mnt/data` に書けるよう、EFS アクセスポイント
   (ownerUid/ownerGid/permissions) の利用を推奨。
   また `efs-entrypoint.sh` は冒頭で **`umask 002`** を設定する。既定の
   umask 022 では作成するディレクトリが `0755` (group に write 権限なし) となり、
   EFS アクセスポイントで同一 gid・別 uid の後続タスクが `mid/<タスクID>`
   ディレクトリを作成/更新できず失敗しうる。`umask 002` により `0775`
   (group write 可) で作成させ、タスク ID ディレクトリの作成失敗を防ぐ。
3. **古いタスク ID ディレクトリの削除**: `mid/` 配下は起動のたびに増える。
   ライフサイクル管理 (EFS の IA/アーカイブ、または定期削除バッチ) を用意すること。
   名前の接頭辞が起動時刻 (`YYYYMMDDhhmmss`) なので、更新時刻だけでなく
   ディレクトリ名でも新旧の並べ替え・世代削除がしやすい。
4. **dangling リンクは正常**: ビルド直後のイメージ内ではリンク先が存在しないため
   リンクは「切れて」見えるが、ECS が EFS をマウントしエントリポイントが
   実体を作った時点で解決される。`docker run` をローカルで行う場合は
   `-v` で `/mnt/logs` `/mnt/data` に書き込み可能なボリュームを与えること。
5. **改行コード**: `entrypoint.sh` は LF 必須。base の Dockerfile 内で
   `sed -i 's/\r$//'` により CRLF 混入を除去している。
6. **Compose での検証は ECS と条件を揃える**: Docker の named volume は初回
   マウント時にイメージ側の中身を自動コピーするが、**ECS のボリュームは
   一切コピーしない**。Compose 側に `read_only: true` と `nocopy: true` を
   付けないと、7 章の書き戻しが壊れていても Compose では正常に起動してしまい、
   ECS でだけ無音で失敗する。詳細は `TROUBLESHOOTING.md` 6 章。

---

## 7. configuration ディレクトリの seed 方式

### 課題

`readonlyRootFilesystem=true` では JBoss EAP が
`/opt/jboss-eap/standalone/configuration` へ書き込めない。起動時に
`standalone_xml_history/` を作るだけで失敗する。したがって
`configuration` にも**書き込み可能ボリュームを当てる必要がある**。

ところが **ECS のボリュームは「空」でマウントされ、イメージ内に焼き込んだ
`configuration` の中身は覆い隠されて見えなくなる**。`standalone.xml` も
`logging.properties` も消えた状態で JBoss が起動することになる。

> Docker Compose の named volume は初回マウント時にイメージ側の中身を
> 自動コピーするため、この問題は Compose では表面化しない。
> ECS/Fargate はコピーしない。**Compose で動いても ECS で動く保証にならない。**

### 解決: ビルド時に退避 → 起動時に書き戻す

| タイミング | 場所 | 処理 |
|---|---|---|
| ビルド時 | ルート FS (読み取り専用でよい) | `configuration/` → `configuration-seed/` へ丸ごと退避 |
| 起動時 | 書き込み可能ボリューム | `configuration-seed/` → `configuration/` へ書き戻す |

`configuration-seed` はルート FS 上に残り、起動後は読み取りしかしないため
`readonlyRootFilesystem=true` と両立する。

### なぜ「無音での失敗」が起きるのか — 検証を厚くしている理由

JBoss EAP の起動時ロギングは
`-Dlogging.configuration=file:<configuration>/logging.properties`
でブートストラップされる。**この 1 ファイルが欠けると CONSOLE ハンドラも
FILE ハンドラも構成されず、`server.log` は作られず標準出力にも何も出ない。**

つまり「書き戻しの失敗」は「原因が一切ログに残らないままコンテナが黙って
死ぬ」に直結する。そのため `efs-entrypoint.sh` は JBoss へ制御を渡す前に
必要条件をすべて検証し、満たさない場合は理由を明示して `exit 1` する。

- `configuration` / `tmp` / `data` / `log` 解決先への**実書き込み検証**
  (`mount` のパースではなく `touch` で判定し、`EROFS` と `EACCES` の両方を検出)
- 書き戻し後の `logging.properties` / `standalone.xml` の存在検証
- `standalone/log` の `readlink -f` による dangling 検出
- 失敗時は `id` / `ls -la standalone` / `mount` / `readlink` の診断ダンプを出力

正常時は CloudWatch に `[efs-entrypoint] preflight OK.` まで 4 行が出る。

### cp のオプション — ビルド時と起動時で変える

| | コマンド | 理由 |
|---|---|---|
| ビルド時 | `cp -a "${SRC}/." "${DST}/"` | root かつ同一 FS なので所有権・時刻を保持してよい |
| 起動時 | `cp -Rf "${SEED_DIR}/." "${CONF_DIR}/"` | **`-a` / `-p` は使わない**。所有権保持のための `chown` が失敗し、「ファイルはコピーできているのに終了コードが非 0」になる。`set -e` と組み合わさると無音死する。**`-f` は付ける** — 別 uid が残した既存ファイルを open できず `cannot create regular file ... Permission denied` になるのを防ぐ (下記) |

いずれも**末尾 `/.` が必須**。`${SRC}/*` はドットファイルを取りこぼし、
`${SRC}` は `dst/configuration-seed/` を作ってしまう。

**`-a` を避ける理由は EFS アクセスポイント固有ではない。**
失敗するかどうかは「コピー元の uid/gid をコピー先に設定する権限があるか」の
一点で決まり、アクセスポイントはその条件を作る一例にすぎない。

| ケース | `cp -a` は失敗するか |
|---|---|
| **非 root 実行 (`USER jboss`)** | **必ず失敗**。`CAP_CHOWN` の無い uid は他人の uid へ `chown` できない (EPERM)。**コピー先がタスクローカルボリューム / tmpfs / bind mount でも同じ** |
| EFS アクセスポイント経由 | 必ず失敗 (AP が uid/gid を強制する) |
| EFS 直マウント + `ClientRootAccess` 無し | 失敗する (root squash で root も chown 不可) |
| root 実行 + ローカル FS / squash 無し | 失敗しない (ビルド時がこれに当たる) |

本設計では書き戻し先 `configuration` は**タスクローカルボリューム**であり
EFS ですらないため、実際に効くのは 1 行目の「非 root 実行」である
(seed は root 所有で作られ、実行ユーザーは `jboss`)。
したがって「AP を使っていないから `cp -a` に戻してよい」は成り立たない。
詳細と EFS 抜きの最小再現は
[`CP_PRESERVE_OWNERSHIP.md`](./CP_PRESERVE_OWNERSHIP.md) を参照。

#### 起動時に `-f` を付ける理由 — 所有権保持とは別の失敗

`cp -a` の `failed to preserve ownership` は「コピーは済んだのに終了コードだけ 1」だが、
`cannot create regular file ... Permission denied` は `open(2)` が `EACCES` で
**コピー自体が行われていない**。原因は次の 2 つだけ。

| 何が書けないか | 起きる状況 | 対処 |
|---|---|---|
| **既存ファイル** | 前回タスクが**別 uid**・group write 無しで作ったものが残っている (`configuration` を永続化している場合) | `-f` が unlink して作り直す。親ディレクトリの write 権限だけで足りる |
| **親ディレクトリ** | AP の uid/gid 不一致、`ClientWrite` 欠落、ボリューム未マウント (EROFS) | `-f` では通らない。書けないパスを列挙して `exit 1` する |

あわせて起動時に次の 2 つを行い、同じ問題が次回起動に持ち越されないようにしている。

- `prepare_conf_tree`: seed 側のディレクトリ構造を先に作り、既存ディレクトリには
  `g+rwX` を試みる (所有者でなければ失敗するので best-effort)
- コピー後の `chmod -R g+rwX "${CONF_DIR}"`: 同一 gid・別 uid の次タスクが
  `-f` 無しでも上書きできる状態にする

`configuration` に**エフェメラル**なタスクローカルボリュームを当てていれば
毎起動で空になるため既存ファイル問題は原理的に発生しない。これが推奨構成である。
切り分け手順は [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md) 3 章 A-1。

### 切り替え用の環境変数

| 変数 | 既定 | 意味 |
|---|---|---|
| `CONFIG_SEED_MODE` | `overwrite` | `overwrite`=毎起動上書き (推奨) / `missing`=設定ファイルが無いときだけ復元 / `skip`=復元しない |
| `JBOSS_CONFIG_FILE` | `standalone.xml` | 起動に使う設定ファイル名 |
| `STRICT_SEED` (build-arg) | `0` | `1` で seed が空のときビルドを失敗させる。CI では必ず `1` |

### タスク定義の必須要件

`configuration` / `tmp` / `data` に**タスクローカルの**書き込み可能ボリュームを
当てる。具体的な JSON と注意点 (front/back でボリューム名を分ける、
`configuration` を EFS 共有にしない 等) は
[`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md) 5-3 を参照。
