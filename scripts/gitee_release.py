#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在 Gitee 镜像仓创建 Release 并补传附件。

为什么需要它：GitHub Actions 的机房到 Gitee 只有约 10 KB/s 的上传带宽，
50 MB 的 APK 要跑一个多小时，所以 CI 里的 `publish_gitee.sh` 只负责代码、
tag 和 Release 本体，安装包一律由发版机器补传。

用法（令牌按「环境变量 → .git/gitee_token → ~/.gitee_token」顺序自动查找）：

    python3 scripts/gitee_release.py --tag v1.1.85 \\
        --notes-from-github --apk-from-github

    # 刚打完 tag，CI 还在构建：--wait 会等到 APK 出现再下载上传
    python3 scripts/gitee_release.py --tag v1.1.85 \\
        --notes-from-github --apk-from-github --wait

    # 已把 APK 下到本地时
    python3 scripts/gitee_release.py --tag v1.1.85 \\
        --dist ./dist --assets InkPaper-v1.1.85-android.apk

- 该 tag 已有 Release 则复用，不重复创建
- 同名附件已存在则跳过（可重复执行）
- --apk-from-github 走 --mirror 前缀下载，国内直连 GitHub 基本拉不动
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

GITEE_API = 'https://gitee.com/api/v5'
GITHUB_API = 'https://api.github.com'
DEFAULT_MIRROR = 'https://ghfast.top'


def _request(url, *, method='GET', headers=None, data=None, timeout=120):
    req = urllib.request.Request(url, data=data, method=method)
    for key, value in (headers or {}).items():
        req.add_header(key, value)
    req.add_header('User-Agent', 'inkpaper-release')
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def gitee_api(path, token, *, method='GET', body=None, owner, repo):
    url = GITEE_API + path
    if body is None:
        sep = '&' if '?' in path else '?'
        url += sep + 'access_token=' + urllib.parse.quote(token)
        headers = {}
    else:
        headers = {
            'Content-Type': 'application/json;charset=UTF-8',
            'Authorization': 'token ' + token,
        }
        body = json.dumps(body).encode('utf-8')
    status, raw = _request(url, method=method, headers=headers, data=body)
    try:
        return status, json.loads(raw or b'{}')
    except json.JSONDecodeError:
        return status, raw.decode('utf-8', 'replace')


def gitee_upload(token, owner, repo, release_id, path):
    """multipart/form-data 手写上传（标准库没有 requests）。"""
    name = os.path.basename(path)
    boundary = '----InkPaperBoundary7f3a91'
    head = (
        '--{b}\r\n'
        'Content-Disposition: form-data; name="file"; filename="{name}"\r\n'
        'Content-Type: application/octet-stream\r\n\r\n'
    ).format(b=boundary, name=name).encode('utf-8')
    tail = ('\r\n--{b}--\r\n'.format(b=boundary)).encode('utf-8')
    with open(path, 'rb') as f:
        payload = head + f.read() + tail

    url = '{base}/repos/{o}/{r}/releases/{rid}/attach_files'.format(
        base=GITEE_API, o=owner, r=repo, rid=release_id
    )
    status, raw = _request(
        url,
        method='POST',
        headers={
            'Authorization': 'token ' + token,
            'Content-Type': 'multipart/form-data; boundary=' + boundary,
        },
        data=payload,
        timeout=900,
    )
    try:
        return status, json.loads(raw or b'{}')
    except json.JSONDecodeError:
        return status, raw.decode('utf-8', 'replace')


def _git_credential_token(repo_slug):
    """从 git 凭据管理器取 GitHub 令牌，避免匿名 60 次/小时的额度。"""
    owner = repo_slug.split('/')[0]
    try:
        proc = subprocess.run(
            ['git', 'credential', 'fill'],
            input='protocol=https\nhost=github.com\nusername=%s\n\n' % owner,
            capture_output=True,
            text=True,
            timeout=20,
        )
    except (OSError, subprocess.SubprocessError):
        return ''
    for line in proc.stdout.splitlines():
        if line.startswith('password='):
            return line[len('password='):].strip()
    return ''


def resolve_gitee_token(args):
    if args.token:
        return args.token, '--token'
    env = os.environ.get('GITEE_TOKEN', '').strip()
    if env:
        return env, '环境变量 GITEE_TOKEN'
    candidates = [args.token_file] if args.token_file else []
    candidates += [
        os.path.join('.git', 'gitee_token'),
        os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '.git', 'gitee_token'),
        os.path.expanduser(os.path.join('~', '.gitee_token')),
    ]
    for path in candidates:
        path = os.path.abspath(path)
        if os.path.isfile(path):
            with open(path, 'r', encoding='utf-8') as f:
                value = f.read().strip()
            if value:
                return value, path
    return '', ''


def resolve_github_token(args):
    if args.github_token:
        return args.github_token
    env = os.environ.get('GITHUB_TOKEN', '').strip()
    if env:
        return env
    return _git_credential_token(args.github_repo)


def github_release(tag, repo, token='', *, allow_missing=False):
    url = '{api}/repos/{repo}/releases/tags/{tag}'.format(
        api=GITHUB_API, repo=repo, tag=tag
    )
    headers = {'Authorization': 'Bearer ' + token} if token else {}
    status, raw = _request(url, headers=headers)
    if status == 404 and allow_missing:
        return None
    if status != 200:
        raise SystemExit(
            '读取 GitHub Release 失败（HTTP %s）：%s' % (status, raw[:300])
        )
    return json.loads(raw)


def wait_for_apk(tag, repo, token, timeout, interval):
    """等 GitHub Release 挂出 APK —— 发版后 CI 构建要二三十分钟。"""
    started = time.time()
    deadline = started + timeout
    attempt = 0
    while True:
        attempt += 1
        elapsed = int(time.time() - started)
        data = github_release(tag, repo, token, allow_missing=True)
        if data:
            apks = [
                a for a in (data.get('assets') or []) if a['name'].endswith('.apk')
            ]
            if apks:
                print(
                    '  [%d 分钟] Release 已挂出 %s（%.1f MB）'
                    % (elapsed // 60, apks[0]['name'], apks[0].get('size', 0) / 1024 / 1024)
                )
                return data
            print('  [%d 分钟] Release 已建，附件还没上传完' % (elapsed // 60))
        else:
            print('  [%d 分钟] 还没有 %s 的 Release' % (elapsed // 60, tag))
        if time.time() >= deadline:
            raise SystemExit(
                '等待超时（%d 分钟）。CI 可能失败或还没跑到 Android 构建，'
                '看看 https://github.com/%s/actions/workflows/release.yml'
                % (timeout // 60, repo)
            )
        time.sleep(interval)


def download(url, dest, expected_size=None):
    if os.path.exists(dest) and expected_size and os.path.getsize(dest) == expected_size:
        print('  已下载，跳过 %s' % os.path.basename(dest))
        return
    print('  下载 %s ...' % url)
    started = time.time()
    status, raw = _request(url, timeout=1800)
    if status != 200:
        raise SystemExit('下载失败（HTTP %s）：%s' % (status, url))
    with open(dest, 'wb') as f:
        f.write(raw)
    size = os.path.getsize(dest)
    print(
        '  -> %.1f MB，%d 秒'
        % (size / 1024 / 1024, max(1, int(time.time() - started)))
    )
    if expected_size and size != expected_size:
        raise SystemExit('大小不符：期望 %s，实际 %s' % (expected_size, size))


def main():
    parser = argparse.ArgumentParser(description='向 Gitee 镜像仓补传发布附件')
    parser.add_argument('--tag', required=True, help='如 v1.1.85')
    parser.add_argument('--name', default=None, help='Release 标题，默认 InkPaper <tag>')
    parser.add_argument('--token', default='', help='Gitee 令牌，默认自动查找')
    parser.add_argument('--token-file', default='', help='指定存令牌的文件')
    parser.add_argument('--owner', default='liudengxing233')
    parser.add_argument('--repo', default='ink-paper')
    parser.add_argument(
        '--github-repo',
        default='liudengxing/InkPaper',
        help='取发布说明与 APK 的 GitHub 仓库',
    )
    parser.add_argument('--github-token', default='', help='GitHub 令牌，默认自动查找')
    parser.add_argument(
        '--mirror',
        default=DEFAULT_MIRROR,
        help='GitHub 下载加速前缀，传空字符串表示直连',
    )
    parser.add_argument('--notes-from-github', action='store_true')
    parser.add_argument(
        '--apk-from-github',
        action='store_true',
        help='从 GitHub Release 拉 *.apk 后再上传',
    )
    parser.add_argument(
        '--wait',
        action='store_true',
        help='等 GitHub Release 挂出 APK 再继续（CI 还在构建时用）',
    )
    parser.add_argument('--wait-timeout', type=int, default=3600, help='等待上限，秒')
    parser.add_argument('--wait-interval', type=int, default=60, help='轮询间隔，秒')
    parser.add_argument('--dist', default='dist', help='本地附件目录')
    parser.add_argument('--assets', nargs='*', default=None, help='指定要上传的文件名')
    args = parser.parse_args()

    token, token_source = resolve_gitee_token(args)
    if not token:
        raise SystemExit(
            '缺少 Gitee 令牌。三种给法任选一种：\n'
            '  1. 环境变量 GITEE_TOKEN\n'
            '  2. 写入 .git/gitee_token（不会进版本库）\n'
            '  3. --token <令牌>'
        )

    tag = args.tag
    name = args.name or ('InkPaper ' + tag)
    notes = None
    gh = None
    gh_token = ''

    if args.wait or args.notes_from_github or args.apk_from_github:
        gh_token = resolve_github_token(args)
    if args.wait:
        print('等待 GitHub Release %s 的 APK（最长 %d 分钟，每 %d 秒查一次）'
              % (tag, args.wait_timeout // 60, args.wait_interval))
        gh = wait_for_apk(
            tag, args.github_repo, gh_token, args.wait_timeout, args.wait_interval
        )
    elif args.notes_from_github or args.apk_from_github:
        gh = github_release(tag, args.github_repo, gh_token)
        print('GitHub Release: %s' % tag)

    if args.notes_from_github:
        notes = gh.get('body') or ''
        print('  发布说明 %d 字' % len(notes))

    assets = list(args.assets or [])
    if args.apk_from_github:
        os.makedirs(args.dist, exist_ok=True)
        for asset in gh.get('assets') or []:
            if not asset['name'].endswith('.apk'):
                continue
            url = asset['browser_download_url']
            if args.mirror:
                url = '%s/%s' % (args.mirror.rstrip('/'), url)
            download(url, os.path.join(args.dist, asset['name']), asset.get('size'))
            assets.append(asset['name'])

    if not assets:
        print('没有指定要上传的附件，只同步 Release 信息')

    path = '/repos/{o}/{r}/releases/tags/{t}'.format(o=args.owner, r=args.repo, t=tag)
    status, detail = gitee_api(path, token, owner=args.owner, repo=args.repo)
    if status == 200 and isinstance(detail, dict) and detail.get('id'):
        release_id = detail['id']
        print('复用已有 Release id=%s（令牌来源：%s）' % (release_id, token_source))
    else:
        status, detail = gitee_api(
            '/repos/{o}/{r}/releases'.format(o=args.owner, r=args.repo),
            token,
            method='POST',
            owner=args.owner,
            repo=args.repo,
            body={
                'tag_name': tag,
                'name': name,
                'body': notes or '',
                'prerelease': False,
                'target_commitish': 'main',
            },
        )
        if status not in (200, 201):
            raise SystemExit('创建 Release 失败（HTTP %s）：%s' % (status, str(detail)[:500]))
        release_id = detail['id']
        print('创建 Release id=%s（令牌来源：%s）' % (release_id, token_source))

    if notes is not None:
        status, _ = gitee_api(
            '/repos/{o}/{r}/releases/{rid}'.format(o=args.owner, r=args.repo, rid=release_id),
            token,
            method='PATCH',
            owner=args.owner,
            repo=args.repo,
            # 必须同时带 tag_name 和 name，少一个 Gitee 就返回 400。
            body={'tag_name': tag, 'name': name, 'body': notes},
        )
        print('更新说明 status=%s' % status)

    status, detail = gitee_api(
        '/repos/{o}/{r}/releases/{rid}'.format(o=args.owner, r=args.repo, rid=release_id),
        token,
        owner=args.owner,
        repo=args.repo,
    )
    existing = {a.get('name') for a in (detail.get('assets') or [])} if status == 200 else set()

    failed = []
    for fn in assets:
        src = os.path.join(args.dist, fn)
        if not os.path.exists(src):
            print('跳过（文件不存在）%s' % src)
            failed.append(fn)
            continue
        if fn in existing:
            print('已存在，跳过 %s' % fn)
            continue
        size_mb = os.path.getsize(src) / 1024 / 1024
        print('上传 %s (%.1f MB) ...' % (fn, size_mb))
        started = time.time()
        status, res = gitee_upload(token, args.owner, args.repo, release_id, src)
        print(
            '  status=%s，%d 秒，%s'
            % (status, int(time.time() - started), str(res)[:300])
        )
        if status not in (200, 201):
            failed.append(fn)

    status, detail = gitee_api(path, token, owner=args.owner, repo=args.repo)
    print('\n== Gitee Release ==')
    print('tag : %s' % detail.get('tag_name'))
    print('name: %s' % detail.get('name'))
    if detail.get('html_url'):
        print('html: %s' % detail['html_url'])
    for asset in detail.get('assets') or []:
        print('  asset: %s -> %s' % (asset.get('name'), asset.get('browser_download_url')))

    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
