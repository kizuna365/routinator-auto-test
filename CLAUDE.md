# routinator-auto-test

Routinator のバージョンアップ時に機能退行がないかを確認する検証スクリプト群。
`.github/` の self-test ワークフローと同等の内容をローカルでも実行できるようにしてある。

## スクリプトの命名規則

`<大分類><中分類>_<連番>_<内容>.sh`

| 接頭辞 | 検証内容 |
|---|---|
| `11_*` | インストール確認 (パッケージ / バージョン / 依存関係) |
| `12_*` | 設定ファイル (デフォルト値 / 配置場所 / カスタム設定) |
| `21_*` | RPKI データ取得 (rsync / RRDP / 全 RIR / timeout) |
| `22_*` | データ検証 (証明書チェーン / ROA 署名 / CRL / manifest / 不正データ拒否) |
| `31_*` | VRP 出力形式 (csv / json / openbgpd) |
| `32_*` | VRP データの正確性 (prefix / AS) |
| `41_*` | RTR サーバー起動 (プロセス起動 / ポート listen) |
| `42_*` | RTR プロトコル動作 (クライアント接続 / 差分更新) |

新しいテストを追加するときはこの体系に沿った番号を振る。

## 実行方法

全件を通しで実行:

```bash
./run_local_all.sh
```

1 本だけ Docker コンテナ内で実行:

```bash
./run_in_container.sh 22_1_check_cert_chain_validation.sh
```

どちらも Docker を使う。共通の環境変数は `TCP_RMEM` / `TCP_WMEM` / `TCP_CC` / `NO_SYSCTL`。

## TCP バッファ調整について

日本の実機から RIR リポジトリへの RTT は 100〜250ms あり、カーネル既定の受信バッファ上限
(6MiB) では RRDP snapshot (数百MB) の取得が帯域遅延積で頭打ちになって `21_*` が timeout する。
新しい network namespace はホストの sysctl を継承しないため、`docker run --sysctl` で明示的に
渡す必要がある。背景の詳細は `run_in_container.sh` 冒頭のコメントを参照。

## 生成物を追跡しない

実行すると RPKI キャッシュ・VRP 出力・ログがカレントに生成される。コミット対象に入れないこと。
`.gitignore` 済み: `*.log`, `routinator-*/`
