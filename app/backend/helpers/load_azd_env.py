"""
Azure Developer CLI(azd)環境ファイルを読み込み、環境変数として設定する。
"""

import json
import logging
import os
import subprocess
from dotenv import load_dotenv

logger = logging.getLogger(__name__)
logger.setLevel(level=os.environ.get("LOGLEVEL", "INFO").upper())


def load_azd_env():
    """azd環境ファイルのパスを取得し、python-dotenvで読み込む"""
    try:
        result = subprocess.run(
            ["azd", "env", "list", "-o", "json"],
            capture_output=True,
            text=True,
            check=True,
        )
    except subprocess.CalledProcessError as e:
        logger.error("Error loading azd env: %s", e)
        raise RuntimeError("Error loading azd env") from e

    try:
        env_json = json.loads(result.stdout)
    except json.JSONDecodeError as e:
        logger.error("Error parsing JSON output: %s", e)
        raise ValueError("Error parsing JSON output") from e

    env_file_path = None
    for entry in env_json:
        if entry.get("IsDefault"):
            env_file_path = entry.get("DotEnvPath")
            break

    if not env_file_path:
        logger.error("No default azd env file found")
        raise FileNotFoundError("No default azd env file found")

    loading_mode = os.getenv("LOADING_MODE_FOR_AZD_ENV_VARS", "no-override")
    if loading_mode == "no-override":
        logger.info(
            "Loading azd env from %s, but not overriding existing environment variables",
            env_file_path,
        )
        load_dotenv(env_file_path, override=False)
    else:
        logger.info(
            "Loading azd env from %s, which may override existing environment variables",
            env_file_path,
        )
        load_dotenv(env_file_path, override=True)
