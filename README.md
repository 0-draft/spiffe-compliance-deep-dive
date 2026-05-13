# spiffe-compliance-deep-dive

SPIRE が発行する SVID が「ほんとに SPIFFE 仕様に準拠してるか」を、コピペ 1 発で目視検証するためのリポジトリ。

ある日「これ SPIFFE 準拠です」と書かれた実装を見て、改めて「準拠」の条件をパッと言えない自分に気づいた。`github.com/spiffe/spiffe` の standards を上から下まで読み直して、出てきた MUST / MUST NOT を全部リストアップして、SPIRE で発行した実物の証明書とトークンを openssl と jq でぶつけて確認したのがここ。

仕様の解説は dev.to 側の記事 **「SPIFFE 準拠 Deep Dive」** に書いた。ここはその記事の Section 10 で使うハンズオン部分だけを切り出してある。

## やってること

`run.sh` が以下を全部やる。途中で Ctrl+C しても `trap cleanup EXIT` で `docker compose down -v` まで走るので、リソースが残らない。

1. SPIRE Server を Docker で起動
2. Trust Bundle を export して Agent に渡す
3. Join Token を発行
4. Workload Entry を 1 個登録（`unix:uid:0` を `spiffe://example.org/payments/web-fe` にマップ）
5. SPIRE Agent を起動（join token で初回認証）
6. X.509-SVID を取り出して openssl で開く
7. SAN の URI、Basic Constraints、Key Usage、EKU を仕様と突き合わせる
8. JWT-SVID を取り出して `.` で 3 分割、Base64URL デコード
9. `alg` / `sub` / `aud` / `exp` を仕様と突き合わせる
10. Trust Bundle の CA 証明書を openssl で開いて自己署名と path なし SPIFFE ID を確認
11. Workload API の UDS が応答することを `spire-agent healthcheck` で確認
12. 自動クリーンアップ

X.509-SVID なら、たとえばこういう箇所を見る。

```text
X509v3 Key Usage: critical
    Digital Signature, Key Encipherment, Key Agreement
X509v3 Basic Constraints: critical
    CA:FALSE
X509v3 Subject Alternative Name:
    URI:spiffe://example.org/payments/web-fe
```

JWT-SVID ならこの形が出る。

```json
{
  "alg": "ES256",
  "kid": "...",
  "typ": "JWT"
}
{
  "aud": ["https://api.example.com"],
  "exp": 1778672723,
  "iat": 1778672423,
  "sub": "spiffe://example.org/payments/web-fe"
}
```

仕様（X509-SVID 4 章 / JWT-SVID 3 章）と 1 対 1 で対応する。

## 動かす

```bash
git clone https://github.com/0-draft/spiffe-compliance-deep-dive.git
cd spiffe-compliance-deep-dive
bash run.sh
```

必要なのは Docker、jq、openssl。Docker は Desktop でも Rancher Desktop でも OrbStack でも何でもいい。所要 1 分くらい。

動作確認は macOS 14 + Rancher Desktop で取った。SPIRE のバージョンは `docker-compose.yml` で `v1.14.6` に pin してある。SPIRE が breaking change を入れたときに記事と乖離しないように。

## 中身

```text
run.sh                   # 12 ステップの検証スクリプト
docker-compose.yml       # SPIRE Server + Agent
server/server.conf       # 自己署名 CA、sqlite、join_token attestor
agent/agent.conf         # unix workload attestor
```

## ハマったとこ

distroless image だったのを忘れて、`docker compose exec spire-agent cat ...` でハマった。`cat` も `ls` も入ってない。SVID の取り出しは `docker cp` 経由、socket の応答確認は `spire-agent healthcheck` で代用してる。

Named volume を `/var/lib/spire/server/.data` にマウントしたら spire user (uid=1000) が書けなくて DB が開けなかった。デモ用途なので永続化を諦めて、コンテナの writable layer に置いてある。本番でやるなら named volume を事前 chown する init container を挟む。

`spire-server token generate -spiffeID` に `spiffe://td/spire/...` を渡すと「予約 namespace」と怒られる。`spire-server` 配下のパスは SPIRE 内部用なので、ユーザは別の path（例：`/myagent`）を使う。Agent が attestation した後の実際の SPIFFE ID は `spiffe://td/spire/agent/join_token/<token>` になるので、workload entry の `-parentID` はそっちを指定する必要がある。

## 自前実装の検証に使いたい場合

`run.sh` の ⑧ 〜 ⑪ の検証ロジックだけ抜き出せば、任意の SVID PEM / JWT / Bundle JSON に対して同じ検査を流せる。「SPIFFE 準拠です」と言ってる別実装が怪しいときに、突き合わせる用。

## License

MIT。SPIFFE / SPIRE 自体のライセンスは各 upstream リポジトリ参照。
