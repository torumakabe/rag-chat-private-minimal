"""
バックエンド用Azure Functionsアプリケーションのエントリーポイント。
"""

import logging
import os
import azure.functions as func
from azure.monitor.opentelemetry import configure_azure_monitor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.instrumentation.openai import OpenAIInstrumentor
from blueprints.chat import bp_chat
from blueprints.indexing import bp_indexing

logging.captureWarnings(True)
logging.basicConfig(level=os.getenv("LOGLEVEL", "INFO").upper())
# Azure SDKのログが冗長なため、ログレベルをWARNにする
# https://github.com/Azure/azure-sdk-for-python/issues/9422
logging.getLogger("azure").setLevel(os.environ.get("LOGLEVEL_AZURE", "WARN").upper())
logger = logging.getLogger(__name__)


def _configure_azure_monitor():
    """
    Azure Application Insightsで計装する。
    OpenAI向け計装も行う。HTTPXはOpenAI SDKが使用している。
    """
    configure_azure_monitor()
    HTTPXClientInstrumentor().instrument()
    OpenAIInstrumentor().instrument()


if os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING"):
    _configure_azure_monitor()

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

app.register_functions(bp_chat)
app.register_functions(bp_indexing)
