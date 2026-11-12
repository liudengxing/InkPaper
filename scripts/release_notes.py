#!/usr/bin/env python3
"""从 CHANGELOG 抽出某一版的说明，并在末尾追加统一下载区块。

国内用户直连 GitHub 下载很慢，所以每个 Release 都给出 Gitee 镜像入口。
"""

import re
import sys
from pathlib import Path

GITEE_REPO = "https://gitee.com/liudengxing233/ink-paper"
GITHUB_REPO = "https://github.com/liudengxing/InkPaper"


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
            "两个源的安装包完全相同（已核对 SHA-256 一致）。应用内「检查更新」也优先走 Gitee，",
            "Gitee 不可用时自动回落到 GitHub。",
        ]
    )


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: release_notes.py CHANGELOG.md VERSION", file=sys.stderr)
        return 2

    version_text = sys.argv[2]
    changelog = Path(sys.argv[1]).read_text(encoding="utf-8")
    match = re.search(
        rf"^## \[{re.escape(version_text)}\][^\n]*\n(?P<body>.*?)(?=^## \[|\Z)",
        changelog,
        re.M | re.S,
    )
    if not match:
        print(f"Release notes for {version_text} were not found.", file=sys.stderr)
        return 1

    body = match.group("body").strip()
    if not body:
        body = f"InkPaper {version_text}"
    print(body)
    print()
    print(download_block(version_text))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
