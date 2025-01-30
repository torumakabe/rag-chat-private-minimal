"""
Azure AI Searchのインデックスを作成する。

使用方法: python create_index.py
"""

import os
import sys
from azure.identity import DefaultAzureCredential
from azure.search.documents.indexes import SearchIndexClient
from azure.search.documents.indexes.models import (
    SearchField,
    SearchFieldDataType,
    VectorSearch,
    HnswAlgorithmConfiguration,
    VectorSearchProfile,
    SearchIndex,
)

sys.path.append(
    os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', 'app', 'backend'))
)

from helpers.load_azd_env import load_azd_env


def check_env_var(name: str) -> str:
    """
    環境変数が設定されているかを確認し、値を返す。
    設定されていない場合は例外を返す。
    """
    value = os.getenv(name)
    if not value:
        raise ValueError(f"{name} is not set or empty")
    return value


load_azd_env()

search_service_name = check_env_var("AZURE_SEARCH_SERVICE_NAME")
search_endpoint = f"https://{search_service_name}.search.windows.net"
search_index_name = check_env_var("AZURE_SEARCH_INDEX_NAME")

credential = DefaultAzureCredential()

index_client = SearchIndexClient(endpoint=search_endpoint, credential=credential)

fields = [
    SearchField(name="parent_id", type=SearchFieldDataType.String),
    SearchField(
        name="title", type=SearchFieldDataType.String, analyzer_name="ja.microsoft"
    ),
    SearchField(name="url", type=SearchFieldDataType.String),
    SearchField(
        name="chunk_id",
        type=SearchFieldDataType.String,
        key=True,
        sortable=True,
        filterable=True,
        facetable=True,
        analyzer_name="keyword",
    ),
    SearchField(
        name="chunk",
        type=SearchFieldDataType.String,
        sortable=False,
        filterable=False,
        facetable=False,
        analyzer_name="ja.microsoft",
    ),
    SearchField(
        name="text_vector",
        type=SearchFieldDataType.Collection(SearchFieldDataType.Single),
        hidden=False,
        searchable=True,
        filterable=False,
        sortable=False,
        facetable=False,
        vector_search_dimensions=1536,
        vector_search_profile_name="myHnswProfile",
    ),
]

vector_search = VectorSearch(
    algorithms=[
        HnswAlgorithmConfiguration(name="myHnsw"),
    ],
    profiles=[
        VectorSearchProfile(
            name="myHnswProfile",
            algorithm_configuration_name="myHnsw",
        )
    ],
)

index = SearchIndex(name=search_index_name, fields=fields, vector_search=vector_search)
result = index_client.create_or_update_index(index)
print(f"{result.name} created")
