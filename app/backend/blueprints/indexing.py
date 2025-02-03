"""
Azure Functions BlobトリガーでAzure AI SearchにRAG用インデックスを登録する。
Blobの内容をDocument Intelligenceでレイアウト分析し、Markdownにする。
MarkdownはLangChainのスプリッターでチャンクに分割し、Azure AI Searchへ登録する。
"""

import logging
import os
import re
import base64
import openai
import azure.functions as func
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from azure.search.documents import SearchClient
from azure.ai.documentintelligence import DocumentIntelligenceClient
from azure.ai.documentintelligence.models import (
    AnalyzeDocumentRequest,
    AnalyzeResult,
)
from langchain.text_splitter import (
    MarkdownHeaderTextSplitter,
    RecursiveCharacterTextSplitter,
)
from helpers.load_azd_env import load_azd_env

logger = logging.getLogger(__name__)
logger.setLevel(level=os.environ.get("LOGLEVEL", "INFO").upper())


def check_env_var(name: str) -> str:
    """
    環境変数が設定されているかをチェックし、値を返す。
    設定されていない場合は例外を返す。
    """
    value = os.getenv(name)
    if not value:
        raise ValueError(f"{name} is not set or empty")
    return value


if os.getenv("AZURE_FUNCTIONS_ENVIRONMENT") == "Development":
    load_azd_env()

credential = DefaultAzureCredential()

aoai_token_provider = get_bearer_token_provider(
    credential, "https://cognitiveservices.azure.com/.default"
)


azure_openai_endpoint = check_env_var("AZURE_OPENAI_ENDPOINT")
azure_openai_api_version = check_env_var("AZURE_OPENAI_API_VERSION")
azure_openai_embedding_model = check_env_var("AZURE_OPENAI_EMBEDDING_MODEL")
search_service_name = check_env_var("AZURE_SEARCH_SERVICE_NAME")
search_index_name = check_env_var("AZURE_SEARCH_INDEX_NAME")
doc_intelligence_endpoint = check_env_var("AZURE_DOC_INTELLIGENCE_ENDPOINT")
rag_blob_container_name = check_env_var("RAG_BLOB_CONTAINER_NAME")

bp_indexing = func.Blueprint()


@bp_indexing.blob_trigger(
    arg_name="blob",
    path=f"{rag_blob_container_name}/{{name}}",
    connection="AzureWebJobsStorage",
)
def indexing(blob: func.InputStream):
    """
    Blobトリガーでドキュメントを処理し、Azure AI Searchにインデックスを作成する。
    """
    logger.info("Blob trigger function processed blob. Name: %s", blob.name)

    if blob.name is None:
        logger.info("Blob name is None. Skipped")
        return

    try:
        blob_content = blob.read()

        document_intelligence_client = DocumentIntelligenceClient(
            endpoint=doc_intelligence_endpoint, credential=credential
        )
        poller = document_intelligence_client.begin_analyze_document(
            "prebuilt-layout", AnalyzeDocumentRequest(bytes_source=blob_content)
        )
        di_result: AnalyzeResult = poller.result()

        headers_to_split_on = [
            ("#", "Header 1"),
            ("##", "Header 2"),
            ("###", "Header 3"),
        ]
        markdown_splitter = MarkdownHeaderTextSplitter(
            headers_to_split_on=headers_to_split_on
        )

        docs_string = di_result.content
        markdown_chunks = markdown_splitter.split_text(docs_string)

        recursive_splitter = RecursiveCharacterTextSplitter(
            chunk_size=2000, chunk_overlap=100
        )

        final_chunks = recursive_splitter.split_documents(markdown_chunks)

        openai_client = openai.AzureOpenAI(
            api_version=azure_openai_api_version,
            azure_endpoint=azure_openai_endpoint,
            azure_ad_token_provider=aoai_token_provider,
        )

        search_client = SearchClient(
            endpoint=f"https://{search_service_name}.search.windows.net",
            index_name=search_index_name,
            credential=credential,
        )

        for i, split in enumerate(final_chunks):
            response = openai_client.embeddings.create(
                input=split.page_content, model=azure_openai_embedding_model
            )
            embeddings = response.data[0].embedding

            filename_ascii = re.sub("[^0-9a-zA-Z_-]", "_", blob.name)
            filename_hash = base64.b16encode(blob.name.encode("utf-8")).decode("ascii")
            filename_converted = f"file-{filename_ascii}-{filename_hash}"
            filename_base = blob.name.split("/")[-1]

            document = {
                "parent_id": filename_converted,
                "title": filename_base,
                "url": blob.uri,
                "chunk_id": f"{filename_converted}{i}",
                "chunk": split.page_content,
                "text_vector": embeddings,
            }

            result = search_client.upload_documents(documents=[document])
            if result[0].succeeded:
                logger.info("Document successfully indexed in Azure AI Search.")
            else:
                logger.error(
                    "Failed to index document in Azure AI Search: %s",
                    result[0].error_message,
                )
    except Exception as e:
        logger.error("An error occurred during processing: %s", str(e))
        raise
