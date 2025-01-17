"""
Azure AI Searchのインデックスを作成する。

使用方法: python create_index.py <search_service_name> <index_name>
引数:
    search_service_name: Azure AI Searchのサービス名
    index_name: 作成するインデックスの名前
"""

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

if len(sys.argv) != 3:
    print("Usage: python create_index.py <search_service_name> <index_name>")
    sys.exit(1)

search_service_name = sys.argv[1]
search_endpoint = f"https://{search_service_name}.search.windows.net"
index_name = sys.argv[2]

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

index = SearchIndex(name=index_name, fields=fields, vector_search=vector_search)
result = index_client.create_or_update_index(index)
print(f"{result.name} created")
