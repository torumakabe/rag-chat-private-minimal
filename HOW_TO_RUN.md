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

1. Azure ポータルで **仮想ネットワーク ゲートウェイ** リソースを開き、「**ポイント対サイトの構成**」ブレードに進みます。
2. 「**構成**」タブで以下の設定を行います。
   
    - **トンネルの種類**：**OpenVPN (SSL)**
    - **認証の種類**：**Azure Active Directory** (Entra ID)
    - **Azure Active Directory** (Entra ID) の情報は、[こちら](https://learn.microsoft.com/ja-jp/azure/vpn-gateway/point-to-site-entra-gateway#configure-vpn) のドキュメントを参考にテナント ID を使って設定してください。
   ![Azure ポータルで VPN ゲートウェイの Entra ID 認証を設定しているスクリーンショット](/image/vpn-gateway-settings.png)

    - 設定を保存したら、「VPN クライアントのダウンロード」をクリックして VPN クライアント プロファイル構成パッケージを取得します。

3. ダウンロードした構成パッケージを確認します。
   ダウンロードした zip ファイルを解凍し、`AzureVPN` フォルダ内に **"azurevpnconfig.xml"** が存在することを確認します。

4. Azure VPN クライアントに構成パッケージをインポートし、VPN 接続を確立します。

    > **前提**：Azure VPN クライアントがインストールされていない場合は、[こちら](https://learn.microsoft.com/ja-jp/azure/vpn-gateway/point-to-site-entra-vpn-client-windows#download) のドキュメントを参考にインストールしてください。

    1. Azure VPN クライアントを起動し、左下の「**+**」をクリックして「**インポート**」を選択します。
        ![Azure VPN クライアントのホーム画面のスクリーンショット](/image/azure-vpn-how-to-import.png)
    2. 先ほどダウンロードした **"azurevpnconfig.xml"** を開き構成をインポートします。
    3. 任意の接続名を入力し、「**保存**」をクリックします。
        ![Azure VPN クライアントでの、プロファイルをインポート後の保存画面のスクリーンショット](/image/azure-vpn-save-profile.png)
    4. 接続名のプロファイルに対して「**接続**」をクリックして接続を開始します。
        ![Azure VPN クライアントで保存したプロファイルに接続する画面のスクリーンショット](/image/azure-vpn-how-to-connect.png)

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
