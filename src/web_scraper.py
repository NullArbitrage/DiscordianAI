"""Generic web scraping utilities for URL content extraction.

This module provides robust, production-ready web scraping functionality
using requests + BeautifulSoup. Designed for Docker environments and
production deployment with comprehensive error handling and logging.
"""

import asyncio
import ipaddress
import logging
import random
import re
import socket
import time
from typing import Any
from urllib.parse import urlparse

from bs4 import BeautifulSoup
import requests

# Configuration constants
DEFAULT_TIMEOUT = 15  # Generous timeout for slow sites
MAX_CONTENT_LENGTH = 50000  # ~12-15k tokens worth of content
MAX_DOWNLOAD_SIZE = 1000000  # 1MB raw HTML download limit
REQUEST_RETRIES = 2
MIN_DELAY_BETWEEN_REQUESTS = 1.0  # Respectful delay between requests
MAX_DELAY_BETWEEN_REQUESTS = 3.0  # Maximum random delay
TRUNCATION_LIMIT = 8000
MIN_TEXT_LENGTH = 100
MIN_PARA_LENGTH = 50
MAX_HEADING_LENGTH = 200
MIN_PARTS_FOR_KEY_SECTIONS = 2
MIN_TOTAL_LENGTH_FOR_BODY = 200
CHUNK_SIZE = 8192

# Production-ready headers to avoid blocking
DEFAULT_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    ),
    "Accept": (
        "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8"
    ),
    "Accept-Language": "en-US,en;q=0.9",
    "Accept-Encoding": "gzip, deflate, br",
    "DNT": "1",
    "Connection": "keep-alive",
    "Upgrade-Insecure-Requests": "1",
    "Sec-Fetch-Dest": "document",
    "Sec-Fetch-Mode": "navigate",
    "Sec-Fetch-Site": "none",
    "Cache-Control": "max-age=0",
}


class WebScrapingError(Exception):
    """Base exception for web scraping errors."""


class ContentExtractionError(WebScrapingError):
    """Exception raised when content extraction fails."""


def _add_respectful_delay() -> None:
    """Add a small random delay between requests to be respectful to servers."""
    delay = random.uniform(MIN_DELAY_BETWEEN_REQUESTS, MAX_DELAY_BETWEEN_REQUESTS)
    time.sleep(delay)


def _fetch_attempt(
    url: str,
    session: Any,
    headers: dict[str, str],
    _attempt: int,
) -> tuple[str | None, str | None]:
    """Attempt to fetch URL content with timeout and error handling.

    Args:
        url: URL to fetch
        session: Request session for connection pooling
        headers: HTTP headers for the request
        _attempt: Attempt number for retry tracking

    Returns:
        Tuple[str|None, str|None]: (content, error_message)
    """
    _add_respectful_delay()
    try:
        response = session.get(
            url, headers=headers, timeout=DEFAULT_TIMEOUT, stream=True
        )
        except TimeoutError:
            logger.warning("Scrape timed out for URL: %s", url)
            return None

        if not html_content:
            return None

        soup = BeautifulSoup(html_content, "html.parser")
        content = _extract_content(soup)
        if not content:
            return None

        return _process_final_content(content, max_content_length, url, logger)

    except Exception:
        logger.exception("Unexpected error during scraping: %s", url)
        return None


def _validate_url(url: str, logger: logging.Logger) -> bool:
    """Validate URL format."""
    parsed_url = urlparse(url)
    if not parsed_url.scheme or not parsed_url.netloc:
        logger.error("Invalid URL format: %s", url)
        return False
    return True


_STOP_RETRY = object()


def _fetch_content_with_retries(url: str, timeout: int, logger: logging.Logger) -> str | None:
    """Perform HTTP request with retries."""
    session = requests.Session()
    session.headers.update(DEFAULT_HEADERS)
    try:
        for attempt in range(REQUEST_RETRIES + 1):
            result = _fetch_attempt_with_retry_logic(session, url, attempt, timeout, logger)
            if result is _STOP_RETRY:
                return None
            if result is not None:
                return result
            if attempt < REQUEST_RETRIES:
                time.sleep(2**attempt)
    finally:
        session.close()
    return None


def _fetch_attempt_with_retry_logic(
    session: requests.Session, url: str, attempt: int, timeout: int, logger: logging.Logger
) -> str | None:
    """Perform a single fetch attempt with error handling for the retry loop."""
    try:
        return _fetch_attempt(session, url, attempt, timeout, logger)
    except requests.exceptions.RequestException as e:
        if attempt == REQUEST_RETRIES or isinstance(e, requests.exceptions.HTTPError):
            _log_fetch_error(e, url, attempt, logger)
            return _STOP_RETRY
        # Let the loop handle the sleep for non-fatal errors
        return None


def _fetch_attempt(
    session: requests.Session, url: str, attempt: int, timeout: int, logger: logging.Logger
) -> str | None:
    """Perform a single fetch attempt."""
    logger.debug("HTTP attempt %d for: %s", attempt + 1, url)
    response = session.get(url, timeout=timeout, allow_redirects=True, stream=True)
    try:
        response.raise_for_status()

        if "text/html" not in response.headers.get("content-type", "").lower():
            return _STOP_RETRY

        try:
            if int(response.headers.get("content-length", 0)) > MAX_DOWNLOAD_SIZE:
                return _STOP_RETRY
        except (TypeError, ValueError):
            return _STOP_RETRY

        content = bytearray()
        for chunk in response.iter_content(chunk_size=CHUNK_SIZE):
            content.extend(chunk)
            if len(content) > MAX_DOWNLOAD_SIZE:
                break
        return bytes(content).decode("utf-8", errors="ignore")
    finally:
        response.close()


def _log_fetch_error(e: Exception, url: str, attempt: int, logger: logging.Logger) -> None:
    """Log fetch errors with appropriate detail."""
    if isinstance(e, requests.exceptions.HTTPError):
        status = e.response.status_code if e.response else "unknown"
        logger.error("HTTP %s for %s", status, url)
    else:
        logger.warning("Attempt %d failed for %s: %s", attempt + 1, url, str(e))


def _process_final_content(content: str, max_length: int, url: str, logger: logging.Logger) -> str:
    """Clean and truncate extracted content."""
    clean = re.sub(r"\s+", " ", content).strip()
    original_len = len(clean)
    if original_len > max_length:
        clean = clean[:max_length] + "\n\n[Content truncated due to length]"
    logger.info("Scraped %d chars from %s", original_len, url)
    return clean


async def _resolve_hostname(hostname: str) -> list[tuple[Any, ...]]:
    """Resolve hostnames off the main event loop."""
    return await asyncio.to_thread(
        socket.getaddrinfo,
        hostname,
        None,
        socket.AF_UNSPEC,
        socket.SOCK_STREAM,
        socket.IPPROTO_TCP,
    )


async def is_safe_url(url: str) -> bool:
    """Check if a URL is safe to scrape (prevents SSRF)."""
    try:
        parsed = urlparse(url)
        hostname = parsed.hostname
        if not (parsed.scheme in ["http", "https"] and parsed.netloc and hostname):
            return False

        addr_info = await _resolve_hostname(hostname)
        if not addr_info:
            return False

        for _family, _, _, _, sockaddr in addr_info:
            ip_obj = ipaddress.ip_address(sockaddr[0])
            # ip.is_global filters non-public ranges
            if not ip_obj.is_global:
                return False
    except (ValueError, socket.gaierror, TypeError, OSError):
        return False
    else:
        return True


async def is_scrapable_url(url: str) -> bool:
    """Check if a URL is suitable for web scraping based on extension and safety.

    Args:
        url: URL to check

    Returns:
        True if URL appears to be scrapable and safe
    """
    if not await is_safe_url(url):
        return False

    try:
        parsed = urlparse(url)
        path = parsed.path.lower()
        skip_extensions = [
            ".pdf",
            ".doc",
            ".docx",
            ".xls",
            ".xlsx",
            ".zip",
            ".tar",
            ".gz",
            ".rar",
            ".7z",
            ".jpg",
            ".jpeg",
            ".png",
            ".gif",
            ".svg",
            ".webp",
            ".mp4",
            ".avi",
            ".mov",
            ".mp3",
            ".wav",
            ".flac",
            ".exe",
            ".dmg",
            ".deb",
            ".rpm",
        ]
        return not any(path.endswith(ext) for ext in skip_extensions)
    except (ValueError, TypeError):
        return False
