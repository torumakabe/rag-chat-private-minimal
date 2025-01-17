"""
Streamlitベースのチャットページ。
"""

import os
import logging
import re
import requests
from requests.exceptions import (
    HTTPError,
    Timeout,
    ConnectionError as RequestsConnectionError,
)
import streamlit as st
from azure.storage.blob import BlobClient
from azure.identity import DefaultAzureCredential
from azure.core.exceptions import AzureError
from azure.monitor.opentelemetry import configure_azure_monitor

logging.captureWarnings(True)
logging.basicConfig(level=os.getenv("LOGLEVEL", "INFO").upper())
# Azure SDKのログが冗長なため、ログレベルをWARNにする
# https://github.com/Azure/azure-sdk-for-python/issues/9422
logging.getLogger("azure").setLevel(os.environ.get("LOGLEVEL_AZURE", "WARN").upper())
logger = logging.getLogger(__name__)


def check_env_var(name: str) -> str:
    """
    環境変数が設定されているかをチェックし、値を返す。
    設定されていない場合は例外を返す。
    """
    value = os.getenv(name)
    if not value:
        raise ValueError(f"{name} is not set or empty")
    return value


chat_api_endpoint = check_env_var("CHAT_API_ENDPOINT")

st.set_page_config(
    page_title="物知りBot",
    menu_items=None,
)


@st.cache_resource(show_spinner=False)
def _configure_azure_monitor():
    """
    Azure Application Insightsで計装する。
    """
    configure_azure_monitor()


if os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING"):
    _configure_azure_monitor()


def get_blob(blob_url: str) -> bytes:
    """
    Azure Blobのデータを取得する。
    """
    if os.getenv("AZURE_WEBAPP_ENVIRONMENT") == "Development":
        azurite_account_key = check_env_var("AZURITE_ACCOUNT_KEY")
        client = BlobClient.from_blob_url(
            blob_url=blob_url,
            credential=azurite_account_key,
        )
    else:
        credential = DefaultAzureCredential()
        client = BlobClient.from_blob_url(blob_url=blob_url, credential=credential)

    download_stream = client.download_blob()
    blob_data = download_stream.readall()

    return blob_data


st.title("何でも聞いてください")

if "messages" not in st.session_state:
    st.session_state.messages = []

for message in st.session_state.messages:
    with st.chat_message(message["role"]):
        st.write(message["content"])

if "download" not in st.session_state:
    st.session_state.download = {}

if prompt := st.chat_input("ここに質問を入力"):
    with st.chat_message("user"):
        st.write(prompt)
    st.session_state.messages.append(
        {
            "role": "user",
            "content": prompt,
        }
    )

    try:
        stream = requests.post(
            chat_api_endpoint, json={"query": prompt}, stream=True, timeout=30
        )
        stream.raise_for_status()
        # streamに含まれるblob URL文字列を抜き出し、ダウンロードに備えたい。かつ、回答ではURLを非表示にしたい。
        # しかしStreamlitのwrite_streamを使うと、streamの終了(StopIteration)を補足できず、終了時にblob URL文字列を返せない。
        # よってstreamを順次表示せず、最後まで読み切って使う。
        response = "".join(
            chunk.decode(stream.encoding or "utf-8")
            for chunk in stream.iter_content(chunk_size=8192)
            if chunk
        )
        response_without_url = "".join(re.split(r"\[.*?\]", response))
        with st.chat_message("assistant"):
            st.write(response_without_url)
        st.session_state.messages.append(
            {
                "role": "assistant",
                "content": response_without_url,
            }
        )

        # 前の回答でダウンロード可能なファイルがあり、ダウンロードしない場合は残っているため、初期化する
        st.session_state.download = {}

        matches = re.findall(r"\[(.*?)\]", response)
        url = matches[0] if matches else None
        if url:
            st.session_state.download = {
                "url": url,
                "name": url.split("/")[-1],
            }

    except HTTPError as e:
        logger.error("API request failed(HTTP): %s", e)
        st.error(f"チャットAPIへの要求でHTTPエラーが起こりました: {str(e)}")
    except Timeout as e:
        logger.error("API request failed(Timeout): %s", e)
        st.error(
            "チャットAPIへの要求でタイムアウトしました。ネットワークを確認し、再実行してください"
        )
    except RequestsConnectionError as e:
        logger.error("API request failed(Connection): %s", e)
        st.error(
            "チャットAPIへの接続が失敗しました。ネットワークを確認し、再実行してください"
        )
    except Exception as e:
        logger.error("API request failed: %s", e)
        st.error(
            "チャットAPIへの要求で問題が起こりました。管理者にお問い合わせください"
        )

if st.session_state.download:
    if st.button("情報源のダウンロード"):
        try:
            st.download_button(
                label="ダウンロードの準備ができました。クリックしてください",
                data=get_blob(st.session_state.download["url"]),
                file_name=st.session_state.download["name"],
                mime="application/octet-stream",
            )
        except AzureError as e:
            logger.error("Failed to download: %s", e)
            st.error("ダウンロードに失敗しました。管理者にお問い合わせください")
        except Exception as e:
            logger.error("Failed to download: %s", e)
            st.error("ダウンロードに失敗しました。管理者にお問い合わせください")

        del st.session_state.download
