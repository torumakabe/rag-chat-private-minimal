"""
Azure Functions HTTPトリガーでチャット機能を提供する。
質問の内容に関連する文章をAzure AI Searchで検索する。
質問と検索結果を元に、LLMで回答を作る。
"""

import logging
import os
import json
import asyncio
import openai
import azure.functions as func
from azurefunctions.extensions.http.fastapi import Request, StreamingResponse
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from azure.search.documents import SearchClient
from azure.search.documents.models import VectorizedQuery
from helpers.load_azd_env import load_azd_env

logger = logging.getLogger(__name__)
logger.setLevel(level=os.environ.get("LOGLEVEL", "INFO").upper())


def check_env_var(name: str) -> str:
    """
    環境変数が設定されているかを確認し、値を返す。
    設定されていない場合は例外を返す。
    """
    value = os.getenv(name)
    if not value:
        raise ValueError(f"{name} is not set or empty")
    return value


async def stream_processor(response):
    """
    OpenAI Chat Completion APIからのストリームを順次処理する。
    """
    async for chunk in response:
        if len(chunk.choices) > 0:
            delta = chunk.choices[0].delta
            if delta.content:
                await asyncio.sleep(0.01)
                yield delta.content


if os.getenv("AZURE_FUNCTIONS_ENVIRONMENT") == "Development":
    load_azd_env()

credential = DefaultAzureCredential()

aoai_token_provider = get_bearer_token_provider(
    credential, "https://cognitiveservices.azure.com/.default"
)

azure_openai_endpoint = check_env_var("AZURE_OPENAI_ENDPOINT")
azure_openai_api_version = check_env_var("AZURE_OPENAI_API_VERSION")
azure_openai_generative_model = check_env_var("AZURE_OPENAI_GENERATIVE_MODEL")
azure_openai_embedding_model = check_env_var("AZURE_OPENAI_EMBEDDING_MODEL")
search_service_name = check_env_var("AZURE_SEARCH_SERVICE_NAME")
search_index_name = check_env_var("AZURE_SEARCH_INDEX_NAME")

GROUNDED_PROMPT = """
あなたは、提供された情報を基に、ユーザーの調査を支援するAIアシスタントです。
以下の指示に従って回答してください。

質問に答える際は、下記の情報源に記載されている情報を使ってください。
下記の情報源を使用せずに独自の回答を生成しないでください。
情報源に情報が不足している場合は、「わかりません」と答えてください。
回答が複数のポイントに分かれる場合は、箇条書きを使用してください。
回答が1行の場合は、箇条書きを使わないでください。
回答が3文を超える場合は、要約してください。
回答の末尾に、改行してから、最も関連性の高い情報源のファイル名とURLを加えてください。
ファイル名は'情報源: <ファイル名>'と整形して下さい。
URLは文字列'[<URL>]'と整形して下さい。文字列'URL: 'は不要です。
'['と']'を使うのはURLの整形だけにしてください。

以上です。

質問: {query}
情報源:\n{sources}
"""

bp_chat = func.Blueprint()


@bp_chat.route(route="chat", methods=[func.HttpMethod.POST])
async def chat(req: Request) -> StreamingResponse:
    """
    チャットエンドポイントへのHTTP POSTリクエストを処理する。
    """
    logger.info("Python HTTP trigger function processed a request.")

    try:
        req_body = await req.body()
        req_body_json = json.loads(req_body)
    except ValueError:
        return StreamingResponse(
            iter(["Please provide a JSON body"]),
            media_type="text/event-stream",
            status_code=400,
        )

    query = req_body_json.get("query")
    if not query:
        return StreamingResponse(
            iter(["質問を入力してください"]),
            media_type="text/event-stream",
            status_code=400,
        )

    try:
        openai_embedding_client = openai.AzureOpenAI(
            api_version=azure_openai_api_version,
            azure_endpoint=azure_openai_endpoint,
            azure_ad_token_provider=aoai_token_provider,
        )

        response = openai_embedding_client.embeddings.create(
            input=query, model=azure_openai_embedding_model
        )

        vector_query = VectorizedQuery(
            kind="vector",
            fields="text_vector",
            vector=response.data[0].embedding,
            k_nearest_neighbors=3,
        )

        search_client = SearchClient(
            endpoint=f"https://{search_service_name}.search.windows.net",
            index_name=search_index_name,
            credential=credential,
        )

        search_results = search_client.search(
            search_text=query,
            vector_queries=[vector_query],
            select=["title", "chunk", "url"],
            top=5,
        )

        sources_formatted = "=================\n".join(
            [
                f'ファイル名: {document["title"]}, 内容: {document["chunk"]}, URL: {document["url"]}'
                for document in search_results
            ]
        )

        openai_chat_client = openai.AsyncAzureOpenAI(
            api_version=azure_openai_api_version,
            azure_endpoint=azure_openai_endpoint,
            azure_ad_token_provider=aoai_token_provider,
        )

        response = await openai_chat_client.chat.completions.create(
            messages=[
                {
                    "role": "user",
                    "content": GROUNDED_PROMPT.format(
                        query=query, sources=sources_formatted
                    ),
                }
            ],
            model=azure_openai_generative_model,
            stream=True,
        )

        return StreamingResponse(
            stream_processor(response), media_type="text/event-stream"
        )

    except Exception as e:
        logger.error("Error processing request: %s", e)
        return StreamingResponse(
            stream_processor(
                "内部サーバーエラーが発生しました。管理者に連絡してください"
            ),
            media_type="text/event-stream",
            status_code=500,
        )
