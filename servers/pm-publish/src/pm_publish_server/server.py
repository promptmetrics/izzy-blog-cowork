"""MCP server for publishing markdown blog posts to the PromptMetrics admin API."""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

import frontmatter
import httpx
from fastmcp import FastMCP
from slugify import slugify

BASE_URL = os.getenv("PM_BASE_URL", "https://pm-backend-784948600682.us-central1.run.app/api/v1")

mcp = FastMCP("pm-publish")


def _truncate(text: str, max_len: int) -> str:
    if not text or len(text) <= max_len:
        return text or ""
    truncated = text[: max_len - 3]
    last_space = truncated.rfind(" ")
    if last_space > 0:
        truncated = truncated[:last_space]
    return truncated + "..."


def _extract_h1(body: str) -> str | None:
    match = re.search(r"^#\s+(.+)$", body, re.MULTILINE)
    return match.group(1).strip() if match else None


def _assemble_payload(file_path: str) -> dict:
    path = Path(file_path)
    if not path.exists():
        raise FileNotFoundError(f"Markdown file not found: {file_path}")

    post = frontmatter.load(path)
    body = post.content
    metadata = post.metadata

    title = metadata.get("title") or _extract_h1(body) or "Untitled"
    slug = metadata.get("slug") or slugify(title, lowercase=True)
    category = metadata.get("category") or "Engineering"
    description = _truncate(metadata.get("description") or "", 150)
    featured_image_url = metadata.get("coverImage") or metadata.get("ogImage") or ""
    featured_image_alt = _truncate(metadata.get("coverImageAlt") or "", 100)
    author_name = metadata.get("author") or ""

    return {
        "title": title,
        "slug": slug,
        "markdown": path.read_text(encoding="utf-8"),
        "category": category,
        "meta_description": description,
        "featured_image_url": featured_image_url,
        "featured_image_alt": featured_image_alt,
        "author_name": author_name,
    }


async def _get_jwt_token() -> str:
    email = os.getenv("PM_ADMIN_EMAIL")
    password = os.getenv("PM_ADMIN_PASSWORD")

    if not email or not password:
        raise ValueError("PM_ADMIN_EMAIL and PM_ADMIN_PASSWORD environment variables are required.")

    async with httpx.AsyncClient() as client:
        response = await client.post(
            f"{BASE_URL}/user/sign-in",
            json={"email": email, "password": password},
            headers={"Content-Type": "application/json"},
        )

    data = response.json() if response.status_code != 204 else {}
    token = data.get("data", {}).get("token") if isinstance(data, dict) else None

    if response.status_code != 200 or not token:
        raise RuntimeError(f"PM login failed: {data.get('error') or data.get('message') or response.status_code}")

    return token


@mcp.tool()
async def publish_post(markdown_path: str, slug: str | None = None) -> dict:
    """Publish a markdown blog post to the PromptMetrics website.

    Args:
        markdown_path: Absolute path to the markdown file to publish.
        slug: Optional slug override. If omitted, derived from frontmatter or title.
    """
    payload = _assemble_payload(markdown_path)
    if slug:
        payload["slug"] = slug

    jwt = os.getenv("PM_ADMIN_JWT") or await _get_jwt_token()

    async with httpx.AsyncClient() as client:
        response = await client.post(
            f"{BASE_URL}/admin/post/from-markdown",
            json=payload,
            headers={"Content-Type": "application/json", "Authorization": f"Bearer {jwt}"},
        )

    data = response.json() if response.status_code != 204 else {}

    if response.status_code == 201:
        post = data.get("data", {}) if isinstance(data, dict) else {}
        return {
            "success": True,
            "message": data.get("message") or "Post created",
            "post_url": post.get("editUrl") or post.get("url") or "",
            "read_time_minutes": post.get("read_time_minutes"),
            "warnings": data.get("warnings", []),
        }

    if response.status_code == 401:
        raise RuntimeError(f"PM publish auth failed: {data.get('error') or 'Invalid token'}")
    if response.status_code == 403:
        raise RuntimeError(f"PM publish forbidden: {data.get('error') or 'Admin required'}")
    if response.status_code == 400:
        raise RuntimeError(f"PM publish validation error: {data.get('error') or 'Bad request'}")

    raise RuntimeError(f"PM publish failed ({response.status_code}): {data.get('error') or response.text}")


def main() -> None:
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
