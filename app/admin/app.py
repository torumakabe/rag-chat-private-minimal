"""
Streamlitベースの管理者用ページ。

機能:
- RAGインデックスに登録するファイルをAzure Blobにアップロードする。
"""

import os
import logging
import streamlit as st
from azure.storage.blob import BlobServiceClient
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
    環境変数が設定されているかを確認し、値を返す。
    設定されていない場合は例外を返す。
    """
    value = os.getenv(name)
    if not value:
        raise ValueError(f"{name} is not set or empty")
    return value


st.set_page_config(
    page_title="管理",
    menu_items=None,
)

st.title("管理")
st.header("ドキュメントストアへのアップロード")


@st.cache_resource(show_spinner=False)
def _configure_azure_monitor():
    """
    Azure Application Insightsで計装する。
    """
    configure_azure_monitor()


if os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING"):
    _configure_azure_monitor()


def get_blob_service_client():
    """
    Azure Blobのサービスクライアントを取得する。
    """
    if os.getenv("AZURE_WEBAPP_ENVIRONMENT") == "Development":
        azurite_account_key = check_env_var("AZURITE_ACCOUNT_KEY")
        account_url = "http://127.0.0.1:10000/devstoreaccount1/"
        client = BlobServiceClient(
            account_url=account_url,
            credential=azurite_account_key,
        )
    else:
        account_name = check_env_var("AZURE_STORAGE_ACCOUNT_NAME")
        account_url = f"https://{account_name}.blob.core.windows.net/"
        credential = DefaultAzureCredential()
        client = BlobServiceClient(account_url=account_url, credential=credential)

    return client


uploaded_file = st.file_uploader(
    "ファイルを選択してください", type=["pdf", "docx", "xlsx", "pptx", "html"]
)

if uploaded_file is not None:
    try:
        blob_service_client = get_blob_service_client()
        container_name = check_env_var("RAG_BLOB_CONTAINER_NAME")
        blob_client = blob_service_client.get_blob_client(
            container=container_name, blob=uploaded_file.name
        )
        blob_client.upload_blob(uploaded_file, overwrite=True)
        st.success("ファイルのアップロードに成功しました。")
    except AzureError as e:
        logger.error("Failed to upload blob: %s", str(e))
        st.error(f"ファイルのアップロードに失敗しました: {str(e)}")
    except ValueError as e:
        logger.error("Failed to get some value: %s", str(e))
        st.error(
            f"アプリケーション設定に不備があります。管理者に連絡してください: {str(e)}"
        )
    except Exception as e:
        logger.error("Failed to upload: %s", str(e))
        st.error(f"予期しないエラーが発生しました。管理者に連絡してください: {str(e)}")
