# `cp -a` が非 0 終了する条件 — EFS アクセスポイントは原因の一つにすぎない

対象の疑問:

> `cp -a` の問題は EFS アクセスポイントを利用しない場合にも発生するのか。

**結論: 発生する。**
「EFS アクセスポイントだから起きる」のではなく、
**「コピー元の uid/gid をコピー先に設定できない」条件が揃えば起きる**現象であり、
アクセスポイントはその条件を作る一例にすぎない。とくに
**実行ユーザーが非 root なら、EFS を一切使っていなくても必ず起きる**。

関連: [`DESIGN.md`](./DESIGN.md) 7 章「cp のオプション」/
[`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md) 3 章 A

> 本書は GNU coreutils の `cp` (JBoss EAP の UBI / RHEL ベースイメージ) を前提とする。
> BusyBox など別実装では診断メッセージや終了コードの扱いが異なり得る。

---

## 1. 何が起きているのか

`cp -a` は `-dR --preserve=all` と等価で、この `--preserve=ownership` が
コピー先に対して `chown(2)` / `lchown(2)` を呼ぶ。
GNU `cp` は所有権の保持に失敗すると次を出力し、
**ファイル自体はコピーしたうえで exit 1 を返す**。

```
cp: failed to preserve ownership for '/opt/jboss-eap/standalone/configuration/standalone.xml': Operation not permitted
```

重要な性質が 2 つある。

- **ownership の保持失敗は必ず終了コードに反映される。**
  coreutils が「保持に失敗しても終了コードを変えない」と定めているのは
  SELinux コンテキストや capabilities といった一部の属性だけで、
  ownership はそこに含まれない
- **コピー自体は成功している。**
  `ls` すれば中身は揃って見えるのに、終了コードだけが 1 になる

結果として `set -e` の entrypoint は「ファイルは全部あるのに、そこで死ぬ」。
JBoss へ制御が渡らないので `server.log` も awslogs も無音になり、
本リポジトリで最も切り分けにくい失敗の形になる (→ TROUBLESHOOTING.md 2 章)。

---

## 2. chown が失敗する条件

`chown(2)` で**他人の uid へ変更できるのは `CAP_CHOWN` を持つプロセス (実質 root) だけ**
というのが Linux の仕様。ここから、失敗するかどうかは
**「実行 uid」×「その uid が root として扱われるか」**で決まる。

| # | ケース | AP の有無 | `cp -a` は失敗するか | 理由 |
|:-:|--------|:---------:|:---------------------:|------|
| 1 | **実行ユーザーが非 root** (`USER jboss` 等) | **無関係** | **必ず失敗** | POSIX / Linux の仕様。`CAP_CHOWN` の無い uid は自分以外の uid へ chown できない (EPERM)。**EFS どころかタスクローカルボリューム・tmpfs・bind mount でも同じ** |
| 2 | EFS 直マウント + IAM ポリシーに `ClientRootAccess` 無し | AP 無し | 失敗する | root squash により uid 0 が 65534 にマップされ、root でも chown できない |
| 3 | EFS 直マウント + root + root squash 無し | AP 無し | 失敗しない | chown が通る。ただし後述のとおり脆い |
| 4 | EFS アクセスポイント (POSIX user 強制) | AP 有り | **必ず失敗** | AP がすべてのファイル操作の uid/gid を強制する。既存ドキュメントに書かれていたケース |
| 5 | タスクローカルボリューム + root | 無関係 | 失敗しない | seed も root 所有なので chown が no-op になる |
| 6 | 一般の NFS サーバ (`root_squash` 既定) | 無関係 | 失敗する | EFS に限らず NFS では珍しくない設定 |

つまり **AP の有無は判定条件ではない**。判定条件は
**「コピー先に対して、コピー元の uid/gid を設定する権限があるか」**の一点。

---

## 3. 本リポジトリで実際に効いてくるのは #1 (非 root)

見落としやすいが、本設計では書き戻し先
`${JBOSS_HOME}/standalone/configuration` は **タスクローカルの書き込み可能ボリューム**
である (DESIGN.md 7 章「タスク定義の必須要件」— `configuration` を EFS 共有にしない)。
したがって、**この `cp` に EFS アクセスポイントは一切関与していない**。

それでも `cp -a` が危険なのは、uid が食い違うため。

| | 所有者 | 根拠 |
|---|---|---|
| seed (コピー元) | **root** | `docker/base/Dockerfile` の seed 作成 RUN は `USER root` 下で走る |
| 実行ユーザー (コピー主体) | **jboss** | `docker/front/Dockerfile` / `docker/back/Dockerfile` 末尾の `USER jboss` を本番ベースイメージで有効化する想定 |

jboss がコピーすればコピー先は jboss 所有で作られ、`-a` がそれを root へ
chown しようとして EPERM → exit 1。
**AP を使う構成でも使わない構成でも結果は同じ**である。

### 「AP を使っていないから `cp -a` に戻してよい」は成り立たない

戻してよいのは上表の #3 / #5、すなわち
**root で実行し、かつ書き戻し先が root squash されていない**場合だけ。
これは `USER jboss` を有効にした瞬間に崩れる前提であり、
さらに将来 `configuration` を EFS に載せ替えれば #4 でも崩れる。
条件付きで安全なだけのオプションを使う理由がない。

---

## 4. EFS 抜きでの最小再現

EFS もアクセスポイントも登場しない、ローカル Docker だけの再現。

```sh
docker run --rm debian:12 sh -uc '
mkdir -p /seed /dst
echo x > /seed/a
chmod -R a+rX /seed
chmod 777 /dst
su -s /bin/sh nobody -c "
  cp -a /seed/. /dst/; echo \"cp -a exit=\$?\"
  cp -R /seed/. /dst/; echo \"cp -R exit=\$?\"
"
'
```

期待される出力:

```
cp: failed to preserve ownership for '/dst/a': Operation not permitted
cp -a exit=1
cp -R exit=0
```

`/dst` は EFS ではなくコンテナのローカル FS である点が要点。
**ファイルシステムではなく実行 uid が原因**であることがこれで確定する。

---

## 5. 対応方針 — 現状の実装のままで正しい

| 箇所 | 現状 | 判定 |
|------|------|------|
| 起動時 `docker/base/entrypoint.sh` | `cp -R "${SEED_DIR}/." "${CONF_DIR}/"` | **変更不要**。所有権を保持しないので上表のどのケースでも成功する |
| ビルド時 `docker/base/Dockerfile` | `cp -a "${JBOSS_CONF_DIR}/." "${JBOSS_CONF_SEED_DIR}/"` | **変更不要**。root かつ overlayfs 同一 FS なので chown は no-op で通る (#5) |

補足:

- **タイムスタンプだけ残したい**場合は、起動時に `cp -R --preserve=timestamps` が
  安全な中間解。自分が作成したファイルへの `utimensat(2)` は非 root でも許可されるため
  EPERM にならない。所有権には触らない
- **`cp -a ... || true` で握り潰すのは不可**。本物の EROFS / EACCES まで
  一緒に無視され、`configuration` が空のまま起動して再び無音死する
  (TROUBLESHOOTING.md 3 章 A)
- `-a` は SELinux コンテキストや capabilities も保持しようとするが、
  これらの失敗は終了コードを変えない仕様。EFS (NFSv4.1) がこれらの属性に
  対応していなくても非 0 終了の直接原因にはならない。
  **犯人は常に ownership** だと考えてよい

---

## 6. 早見表 — `cp -a` を使ってよいか

```
コピーを実行するのは root か？
├─ いいえ (USER jboss など)  → cp -a は必ず失敗。cp -R を使う
└─ はい
   ├─ コピー先が EFS アクセスポイント経由 → 失敗。cp -R を使う
   ├─ コピー先が EFS 直マウントで ClientRootAccess 無し → 失敗。cp -R を使う
   ├─ コピー先が root_squash な NFS → 失敗。cp -R を使う
   └─ それ以外 (ビルド時の overlayfs 等) → cp -a で可
```

迷ったら `cp -R`。所有権保持が本当に必要な場面は seed 方式には無い。
なお `-a` / `-R` いずれの場合も**末尾 `/.` が必須**である
(`${SRC}/*` はドットファイルを取りこぼし、`${SRC}` は `dst/configuration-seed/` を作る)。
