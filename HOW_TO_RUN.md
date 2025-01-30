# 実行方法

本ドキュメントでは、本リポジトリをクローンして Azure 上のリソースを構築し、VPN 経由で接続する手順から、アプリケーションのデプロイ、および Azure AI Search インデックスの作成までの流れを説明し、手元の PC からアプリケーションにアクセスする方法を紹介します。

## ステップ ①：リポジトリをクローン & リソースのプロビジョニング

1. リポジトリをクローンしてディレクトリに移動します。

    ```bash
    git clone https://github.com/torumakabe/rag-chat-private-minimal.git
    cd .\rag-chat-private-minimal\
    ```

2. Azure 仮想ネットワークとローカル PC を接続するため、VPN ゲートウェイを使用する設定を行います。環境変数 `USE_VPN` を `true` に設定します。

    ```bash
    azd env set USE_VPN true
    ```

3. Azure リソースをプロビジョニング（作成）します。

    ```bash
    azd provision
    ```

## ステップ ②：VPN 接続

1. **ルート証明書**と**クライアント**証明書を作成します（以下は Windows PowerShell 例）。

    ```powershell
    # ルート証明書を作成
    $cert = New-SelfSignedCertificate -Type Custom -KeySpec Signature -Subject "CN=P2SRootCert" -KeyExportPolicy Exportable -HashAlgorithm sha256 -KeyLength 2048 -CertStoreLocation "Cert:\CurrentUser\My" -KeyUsageProperty Sign -KeyUsage CertSign

    # クライアント証明書を作成
    New-SelfSignedCertificate -Type Custom -DnsName P2SChildCert -KeySpec Signature -Subject "CN=P2SChildCert" -KeyExportPolicy Exportable -HashAlgorithm sha256 -KeyLength 2048 -CertStoreLocation "Cert:\CurrentUser\My" -Signer $cert -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.2")
    ```

2. Windows の「**ユーザー証明書の管理**」から、作成されたルート証明書（`P2SRootCert`）を右クリック → 「全てのタスク」→「エクスポート」を選択し、ルート証明書をエクスポートします。

    ![証明書ストアのスクリーンショット](/image/cert-store-screenshot.png)

3. Azure ポータルで **仮想ネットワーク ゲートウェイ** リソースを開き、「**ポイント対サイトの構成**」ブレードに進みます。
   ![Azure ポータルでの VPN ゲートウェイ設定中のスクリーンショット](/image/vpn-gateway-setting.png)

    - ルート証明書欄に先ほどエクスポートしたルート証明書の内容を貼り付けます。（※ 先頭行と最後の行の `-----BEGIN CERTIFICATE-----` / `-----END CERTIFICATE-----` は除外して貼り付けてください）
    - 設定を保存したら、「VPN クライアントのダウンロード」をクリックして VPN クライアントを取得します。

4. ダウンロードしたファイルを実行し、VPN 接続を確立します。
   ![Azure と VPN 接続するためのモーダルのスクリーンショット](/image/azure-vpn-connection.png)

    ![Windows 11 での VPN 設定画面のスクリーンショット](/image/windows-vpn-setting.png)

5. ターミナルやコマンド プロンプトで接続を確認します。

    ```powershell
    ipconfig
    ```

    ![ipconfig コマンドを実行した結果のスクリーンショット](/image/ipconfig-result.png)

## ステップ ③：`hosts` ファイルの更新

VPN 経由で Azure の各リソースにアクセスするため、`hosts` ファイルに「ドメイン名」と「プライベート IP アドレス」の組み合わせを追記します。

1. リポジトリ内のスクリプトを実行して、必要な `hosts` 情報を取得します。
    ```powershell
    .\scripts\util\hosts\gen_hosts.ps1
    ```
2. スクリプトの実行結果に表示される「ドメイン名」と「プライベート IP アドレス」のペアをコピーし、**hosts** ファイルに追記します。

    - Windows 11 の場合、hosts ファイルは C:\Windows\System32\drivers\etc\hosts にあります。

これでローカル PC から Azure の各リソースにアクセスできるようになります。

## ステップ ④：アプリケーションのデプロイ

VSCode の Azure 拡張機能を用いて、以下のコンポーネントをそれぞれのサービスにデプロイします。

-   `frontend` → App Service
-   `admin` → App Service
-   `backend` → Azure Functions

## ステップ ⑤：Azure AI Search インデックスの作成

1. Azure ポータルで AI Search リソースに移動し、「**アクセス制御（IAM）**」ブレードを開きます。自分のアカウントに「**検索インデックス データ共同作成者**」のロールを割り当てます。

    ![Azure ポータルで自分にロールを割り当てているスクリーンショット](/image/assign-role-to-myself.png)

2. `scripts\search` ディレクトリへ移動し、インデックス作成用の Python スクリプトを実行します。

    ```powershell
    cd scripts\search
    python -m venv .venv
    .venv\Scripts\activate

    pip install -r requirements.txt

    python craete_index.py
    ```

これにより、Azure AI Search のインデックスが作成されます。

## ステップ ⑥：アプリケーション動作確認

上記のすべての手順を完了したら、ブラウザからアプリケーションにアクセスし、動作を確認してください。
