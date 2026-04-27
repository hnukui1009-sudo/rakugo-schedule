#!/usr/bin/env python3
import json
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import quote
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent.parent
VIDEOS_PATH = ROOT / "videos.json"
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0 Safari/537.36"
JST = timezone(timedelta(hours=9))
NOW = datetime.now(JST)
CUTOFF = NOW - timedelta(days=183)
MAX_VIDEOS = 10
SEARCHES = [
    ("落語", "views", "CAM%253D"),
    ("落語", "recent", "CAI%253D"),
    ("古典落語", "views", "CAM%253D"),
    ("古典落語", "recent", "CAI%253D"),
]
EXCLUDE_KEYWORDS = [
    "ノンクレジット",
    "オープニング映像",
    "TVer",
    "SHOWマン",
]


def fetch_text(url: str) -> str:
    request = Request(url, headers={"User-Agent": USER_AGENT})
    with urlopen(request, timeout=30) as response:
        return response.read().decode("utf-8", "ignore")


def extract_initial_data(html: str) -> dict:
    match = re.search(r"var ytInitialData = (.*?);</script>", html)
    if not match:
        raise RuntimeError("ytInitialData not found")
    return json.loads(match.group(1))


def walk_video_renderers(node, results):
    if isinstance(node, dict):
        renderer = node.get("videoRenderer")
        if renderer:
            results.append(renderer)
        for value in node.values():
            walk_video_renderers(value, results)
    elif isinstance(node, list):
        for value in node:
            walk_video_renderers(value, results)


def text_from_runs(node: dict) -> str:
    if not isinstance(node, dict):
        return ""
    if "simpleText" in node:
        return node["simpleText"]
    return "".join(run.get("text", "") for run in node.get("runs", []))


def parse_relative_published(text: str):
    match = re.search(r"(\d+)\s*(分|時間|日|週間|か月|年)前", text)
    if not match:
        return None

    amount = int(match.group(1))
    unit = match.group(2)
    if unit == "分":
        return NOW - timedelta(minutes=amount)
    if unit == "時間":
        return NOW - timedelta(hours=amount)
    if unit == "日":
        return NOW - timedelta(days=amount)
    if unit == "週間":
        return NOW - timedelta(weeks=amount)
    if unit == "か月":
        return NOW - timedelta(days=30 * amount)
    if unit == "年":
        return NOW - timedelta(days=365 * amount)
    return None


def parse_view_count(text: str) -> int:
    compact = text.replace(",", "").replace(" ", "")
    match = re.search(r"(\d+(?:\.\d+)?)\s*(億|万)?回視聴", compact)
    if not match:
        return 0

    value = float(match.group(1))
    unit = match.group(2)
    if unit == "億":
        value *= 100_000_000
    elif unit == "万":
        value *= 10_000
    return int(value)


def is_excluded(title: str) -> bool:
    return any(keyword in title for keyword in EXCLUDE_KEYWORDS)


def build_video_record(renderer: dict, query: str, sort_mode: str):
    video_id = renderer.get("videoId")
    if not video_id:
        return None

    title = text_from_runs(renderer.get("title", {})).strip()
    if not title or is_excluded(title):
        return None

    if renderer.get("upcomingEventData") or renderer.get("badges"):
        badge_text = " ".join(
            text_from_runs(badge.get("metadataBadgeRenderer", {}).get("label", {}))
            if isinstance(badge, dict)
            else ""
            for badge in renderer.get("badges", [])
        )
        if "LIVE" in badge_text.upper():
            return None

    view_text = text_from_runs(renderer.get("viewCountText", {}))
    published_text = text_from_runs(renderer.get("publishedTimeText", {}))
    published_at = parse_relative_published(published_text)

    if not view_text or not published_text or not published_at or published_at < CUTOFF:
        return None

    thumbnails = renderer.get("thumbnail", {}).get("thumbnails", [])
    channel_name = text_from_runs(renderer.get("ownerText", {}))
    duration_text = text_from_runs(renderer.get("lengthText", {}))

    return {
        "id": video_id,
        "title": title,
        "channelName": channel_name or "YouTube",
        "videoURL": f"https://www.youtube.com/watch?v={video_id}",
        "embedURL": f"https://www.youtube.com/embed/{video_id}",
        "thumbnailURL": thumbnails[-1]["url"] if thumbnails else "",
        "viewCount": parse_view_count(view_text),
        "viewCountText": view_text,
        "publishedText": published_text,
        "publishedApproxAt": published_at.isoformat(),
        "durationText": duration_text,
        "query": query,
        "sortMode": sort_mode,
    }


def collect_candidates():
    videos_by_id = {}

    for query, sort_mode, sp in SEARCHES:
        url = f"https://www.youtube.com/results?search_query={quote(query)}&sp={sp}"
        html = fetch_text(url)
        data = extract_initial_data(html)
        renderers = []
        walk_video_renderers(data, renderers)

        for renderer in renderers:
            record = build_video_record(renderer, query, sort_mode)
            if not record:
                continue

            current = videos_by_id.get(record["id"])
            if not current or record["viewCount"] > current["viewCount"]:
                videos_by_id[record["id"]] = record

    return sorted(
        videos_by_id.values(),
        key=lambda item: (-item["viewCount"], item["publishedApproxAt"], item["title"]),
    )


def main():
    candidates = collect_candidates()
    payload = {
        "updatedAt": NOW.isoformat(),
        "sourceName": "YouTube Search",
        "sourceURL": "https://www.youtube.com/results?search_query=%E8%90%BD%E8%AA%9E",
        "selectionNote": "「落語」「古典落語」の検索結果を人気順・新しい順で収集し、過去6か月以内の動画を視聴数順に並べています。",
        "videos": candidates[:MAX_VIDEOS],
    }
    VIDEOS_PATH.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"videos.json updated: {len(payload['videos'])} videos")


if __name__ == "__main__":
    main()
