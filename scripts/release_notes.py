#!/usr/bin/env python3
"""从 CHANGELOG 抽出发布说明，并在末尾追加统一下载区块。

默认只取当前版本一段；传 --since 上一个已发布版本号时，会把之间积累的
所有版本合并成一份（分类归拢、逐行去重），适合攒了多版一起发的场景——
否则应用内「检查更新」的弹窗只能看到最新一个版本的改动，中间版本的内容全被吞掉。

国内用户直连 GitHub 下载很慢，所以每个 Release 都给出 Gitee 镜像入口。
"""

import argparse
import re
import sys
from pathlib import Path

GITEE_REPO = "https://gitee.com/liudengxing233/ink-paper"
GITHUB_REPO = "https://github.com/liudengxing/InkPaper"

# 分类展示顺序；CHANGELOG 里出现顺序之外的分类排在最后。
CATEGORY_ORDER = ["新增", "变更", "优化", "修复", "移除"]

# 「缺陷修复不展开」的统一占位行，合并多版本时去重并固定放到「修复」末尾。
FIX_BOILERPLATE = "修复已知问题，提升软件稳定性，优化软件运行效率。"


def download_block(version: str) -> str:
    tag = f"v{version}"
    return "\n".join(
        [
            "---",
            "",
            "### 下载",
            "",
            "| 源 | 地址 |",
            "| --- | --- |",
            f"| 国内（推荐，快） | [Gitee 发行版 {tag}]({GITEE_REPO}/releases/tag/{tag}) |",
            f"| 海外 | [GitHub Releases {tag}]({GITHUB_REPO}/releases/tag/{tag}) |",
            "",
            f"APK 直链（Gitee，国内推荐）：",
            f"`{GITEE_REPO}/releases/download/{tag}/InkPaper-{tag}-android.apk`",
            "",
            "两个源的 APK 完全相同（已核对 SHA-256 一致）；AAB 只随 GitHub Release 提供，",
            "供 Google Play 上架用。应用内「检查更新」只走 Gitee，国内无需访问 GitHub。",
        ]
    )


def parse_version(text: str) -> tuple[int, ...]:
    return tuple(int(part) for part in text.split("."))


def parse_sections(changelog: str) -> dict[str, str]:
    """按文件顺序（新版本在前）抽出 `## [x.y.z]` 各段的正文。"""
    sections: dict[str, str] = {}
    for match in re.finditer(
        r"^## \[(\d+\.\d+\.\d+)\][^\n]*\n(?P<body>.*?)(?=^## \[|\Z)",
        changelog,
        re.M | re.S,
    ):
        sections[match.group(1)] = match.group("body").strip()
    return sections


def split_categories(body: str) -> list[tuple[str, list[str]]]:
    """把一个版本的正文拆成 [(分类, [条目…])]，保留出现顺序。

    分类外的散行（如内部维护版本的一句话说明）归入「其他」。
    """
    result: list[tuple[str, list[str]]] = []
    current_category = "其他"
    current_items: list[str] = []

    def flush() -> None:
        if current_items:
            result.append((current_category, list(current_items)))
            current_items.clear()

    for line in body.splitlines():
        stripped = line.strip()
        # 版本之间的 `---` 分隔线会跟着正文一起被切进来，别当成条目
        if re.fullmatch(r"[-*_]{3,}", stripped):
            continue
        heading = re.fullmatch(r"###\s+(.+)", stripped)
        if heading:
            flush()
            current_category = heading.group(1).strip()
            continue
        if stripped:
            item = stripped[2:] if stripped.startswith("- ") else stripped
            current_items.append(item)
    flush()
    return result


def merged_body(
    version_text: str, sections: dict[str, str], since: str
) -> str:
    """合并 since 之后的所有版本段落：分类归拢、跨版本逐行去重。"""
    versions = [v for v in sections if parse_version(v) > parse_version(since)]
    # 文件里新版本在前，反转后从旧到新遍历，保证同版本内条目顺序稳定。
    versions.sort(key=parse_version, reverse=True)

    categories: dict[str, list[str]] = {}
    seen: set[str] = set()
    boilerplate_seen = False
    for version in versions:
        for category, items in split_categories(sections[version]):
            bucket = categories.setdefault(category, [])
            for item in items:
                if item == FIX_BOILERPLATE:
                    boilerplate_seen = True
                    continue
                if item in seen:
                    continue
                seen.add(item)
                bucket.append(item)
    if boilerplate_seen:
        categories.setdefault("修复", []).append(FIX_BOILERPLATE)

    if not any(categories.values()):
        return f"InkPaper {version_text}"

    order = {name: index for index, name in enumerate(CATEGORY_ORDER)}
    names = sorted(
        categories,
        key=lambda name: (order.get(name, len(CATEGORY_ORDER)), name),
    )

    lines: list[str] = []
    for name in names:
        lines.append(f"### {name}")
        lines.append("")
        lines.extend(f"- {item}" for item in categories[name])
        lines.append("")
    return "\n".join(lines).strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("changelog", help="CHANGELOG.md 路径")
    parser.add_argument("version", help="本次发布的版本号，如 1.1.113")
    parser.add_argument(
        "--since",
        help="上一个已发布版本的版本号（不带 v）；传入后合并期间所有版本",
    )
    args = parser.parse_args()

    changelog = Path(args.changelog).read_text(encoding="utf-8")
    sections = parse_sections(changelog)

    if args.version not in sections:
        print(f"Release notes for {args.version} were not found.", file=sys.stderr)
        return 1

    if args.since:
        in_range = [
            version
            for version in sections
            if parse_version(version) > parse_version(args.since)
        ]
        if not in_range:
            # since 不比当前版本旧时退回单版本说明，别静默发空内容。
            print(
                f"No changelog sections newer than {args.since}; "
                "falling back to single-version notes.",
                file=sys.stderr,
            )
            args.since = None

    if args.since:
        body = merged_body(args.version, sections, args.since)
    else:
        body = sections[args.version] or f"InkPaper {args.version}"

    print(body)
    print()
    print(download_block(args.version))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
