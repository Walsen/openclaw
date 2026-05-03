"""
AgentCore Memory — optional cloud persistence layer for cross-session memory.

openclaw's native memory (Markdown + SQLite) continues to work within the
container lifecycle.  This module provides the *optional* AgentCore Memory
integration that persists summaries to AWS so they survive container teardown.

Requirements: 6.1, 6.2, 6.3, 6.4, 6.5, 6.6, 6.7
"""

import logging
import os
import sys
import time
from typing import Optional

import boto3

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

logger = logging.getLogger(__name__)

MEMORY_STORE_ID = os.environ.get("MEMORY_STORE_ID", "default")


def _memory_client():
    """Factory for the bedrock-agentcore-memory boto3 client."""
    return boto3.client(
        "bedrock-agentcore-memory",
        region_name=os.environ.get("AWS_REGION", "us-east-1"),
    )


def _namespace(tenant_id: str) -> str:
    """Return the Memory namespace for a tenant."""
    return f"tenant_{tenant_id}"


async def load_memory_on_session_start(tenant_id: str) -> Optional[str]:
    """Retrieve historical memory summaries for *tenant_id* at session start."""
    try:
        client = _memory_client()
        response = client.retrieve_memories(
            memoryId=MEMORY_STORE_ID,
            namespace=_namespace(tenant_id),
            maxResults=10,
        )
        summaries = [m["content"] for m in response.get("memories", [])]
        return "\n".join(summaries) if summaries else None
    except Exception as e:
        logger.warning(
            "AgentCore Memory read failed, degrading gracefully tenant_id=%s error=%s",
            tenant_id,
            e,
        )
        return None


async def save_memory_on_session_end(tenant_id: str, session_summary: str) -> None:
    """Persist *session_summary* to the tenant's Memory namespace after a session."""
    try:
        from safety import check_memory_safety

        check_memory_safety(session_summary, tenant_id)
    except Exception as safety_err:
        logger.error(
            "Memory write blocked — safety violation tenant_id=%s error=%s",
            tenant_id,
            safety_err,
        )
        return

    try:
        client = _memory_client()
        client.store_memory(
            memoryId=MEMORY_STORE_ID,
            namespace=_namespace(tenant_id),
            content=session_summary,
            metadata={"tenant_id": tenant_id, "timestamp": time.time()},
        )
        logger.info(
            "AgentCore Memory write success tenant_id=%s namespace=%s",
            tenant_id,
            _namespace(tenant_id),
        )
    except Exception as e:
        logger.error(
            "AgentCore Memory write failed tenant_id=%s error=%s",
            tenant_id,
            e,
        )


async def clear_tenant_memory(tenant_id: str) -> bool:
    """Clear all memory entries for *tenant_id*."""
    try:
        client = _memory_client()
        client.delete_memories(
            memoryId=MEMORY_STORE_ID,
            namespace=_namespace(tenant_id),
        )
        logger.info(
            "AgentCore Memory cleared tenant_id=%s namespace=%s",
            tenant_id,
            _namespace(tenant_id),
        )
        return True
    except Exception as e:
        logger.error(
            "AgentCore Memory clear failed tenant_id=%s error=%s",
            tenant_id,
            e,
        )
        return False
