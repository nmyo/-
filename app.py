import sqlite3
import re
import os
import requests
import math
from flask import Flask, render_template_string, request, jsonify, Response
from urllib.parse import urljoin, quote, unquote, urlparse
from werkzeug.middleware.proxy_fix import ProxyFix
import logging
from datetime import datetime

app = Flask(__name__)

# 配置应用以安全地运行在反向代理后面
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_prefix=1)

# 应用安全配置
app.config.update(
    SECRET_KEY=os.environ.get('SECRET_KEY', 'dev-secret-key-change-in-production'),
    SESSION_COOKIE_SECURE=True,  # 在HTTPS环境下才发送cookie
    SESSION_COOKIE_HTTPONLY=True,  # 防止XSS攻击
    SESSION_COOKIE_SAMESITE='Lax',  # 防止CSRF攻击
    PERMANENT_SESSION_LIFETIME=3600  # 会话过期时间（秒）
)

# 数据库配置
DB_COVERS = "JavD.db"
DB_LINKS = "M3U8.db"
PER_PAGE = 30  # 每页显示数量

# 安全日志配置
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# --- MissAV 伪装配置 ---
HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
    'Referer': 'https://missav.ai/',
}

def validate_url(url):
    """验证URL的安全性"""
    if not url:
        return False
    try:
        parsed = urlparse(url)
        # 只允许HTTP和HTTPS协议
        if parsed.scheme not in ['http', 'https']:
            return False
        # 不允许IP地址直接访问（防止SSRF）
        if re.match(r'^\d+\.\d+\.\d+\.\d+', parsed.hostname):
            return False
        # 不允许内部IP段（防止SSRF）
        if parsed.hostname and parsed.hostname.startswith(('10.', '172.', '192.')):
            return False
        return True
    except Exception:
        return False


def get_pure_code(raw):
    if not raw: return ""
    match = re.search(r'([A-Za-z]{2,10})[-_]([0-9]{2,10})', raw)
    if match:
        return f"{match.group(1).upper()}-{match.group(2)}"
    return raw.strip().upper()

def add_security_headers(response):
    """为所有响应添加安全头"""
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['X-Frame-Options'] = 'DENY'  # 或者 'SAMEORIGIN' 如果需要嵌入
    response.headers['X-XSS-Protection'] = '1; mode=block'
    response.headers['Strict-Transport-Security'] = 'max-age=31536000; includeSubDomains'
    response.headers['Referrer-Policy'] = 'no-referrer-when-downgrade'
    response.headers['Content-Security-Policy'] = (
        "default-src 'self'; "
        "script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; "
        "style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; "
        "img-src 'self' data: https:; "
        "font-src 'self' https://cdn.jsdelivr.net; "
        "connect-src 'self'; "
        "frame-ancestors 'none';"
    )
    return response


def format_video_title(title):
    """格式化视频标题，处理后缀替换和大写转换"""
    if not title:
        return ""
    
    # 将整个标题转为大写
    formatted_title = title.upper()
    
    # 替换特定后缀
    formatted_title = re.sub(r'_ORIGINAL$', '', formatted_title)  # 删除 _ORIGINAL 后缀
    formatted_title = re.sub(r'_UNCENSORED-LEAK$', '_无码', formatted_title)  # 将 _UNCENSORED-LEAK 替换为 _无码
    formatted_title = re.sub(r'_CHINESE-SUBTITLE$', '_中文字幕', formatted_title)  # 将 _CHINESE-SUBTITLE 替换为 _中文字幕
    
    return formatted_title

# --- 前端界面 ---
HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="zh">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>JavD Pro - 瀑布流版</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>
        body { background: #080808; color: #eee; font-family: system-ui; }
        .search-bar { background: rgba(20, 20, 20, 0.95); padding: 15px 0; border-bottom: 2px solid #ff0050; position: sticky; top:0; z-index:100; backdrop-filter: blur(10px); }
        
        /* 瀑布流自适应布局 */
        .waterfall { column-count: 2; column-gap: 15px; }
        @media (min-width: 768px) { .waterfall { column-count: 3; } }
        @media (min-width: 992px) { .waterfall { column-count: 5; } }
        
        .card-item { break-inside: avoid; margin-bottom: 15px; background: #121212; border: 1px solid #222; border-radius: 10px; overflow: hidden; transition: 0.3s; }
        .card-item:hover { border-color: #ff0050; transform: translateY(-5px); }
        
        .img-container { position: relative; cursor: zoom-in; }
        .card-img-top { width: 100%; height: auto; display: block; min-height: 100px; background: #1a1a1a; object-fit: cover; box-shadow: 0 4px 8px rgba(0,0,0,0.3); transition: transform 0.3s ease; }
        .card-img-top:hover { transform: scale(1.02); }
        
        .info-box { padding: 10px; cursor: pointer; }
        
        /* 图片放大模态层 */
        #imgOverlay { display:none; position:fixed; top:0; left:0; width:100%; height:100%; background:rgba(0,0,0,0.9); z-index:2000; justify-content:center; align-items:center; cursor: zoom-out; }
        #imgOverlay img { max-width: 95%; max-height: 95%; border-radius: 5px; box-shadow: 0 0 20px rgba(0,0,0,0.5); }

        #player-box { width: 100%; height: 450px; background: #000; display: none; margin-bottom: 20px; }
        .source-item { background: #1a1a1a; border: 1px solid #333; padding: 12px; margin-bottom: 10px; border-radius: 8px; cursor: pointer; }
        .source-item:hover { background: #ff0050; color: #fff; }
        
        .pagination .page-link { background: #1a1a1a; border-color: #333; color: #ccc; }
        .pagination .active .page-link { background: #ff0050; border-color: #ff0050; }
    </style>
</head>
<body>

<div class="search-bar">
    <div class="container d-flex justify-content-between align-items-center">
        <h4 class="mb-0 fw-bold" onclick="window.location.href='/'" style="cursor:pointer">🎬 JAV<span style="color:#ff0050">D</span></h4>
        <form class="d-flex w-50" action="/">
            <input name="q" class="form-control bg-dark text-white border-0 me-2 shadow-none" placeholder="输入番号..." value="{{query}}">
            <button class="btn btn-danger px-4">搜索</button>
        </form>
    </div>
</div>

<div class="container mt-4 pb-5">
    <div class="waterfall">
        {% for item in items %}
        <div class="card-item">
            <div class="img-container" onclick="zoomImg(this.querySelector('img').src)">
                <img src="{{ item['video_jacket_img'] }}" class="card-img-top" loading="lazy">
            </div>
            <div class="info-box" onclick="searchLinks('{{ item['code'] }}')">
                <div style="color:#ff0050; font-weight:bold;">{{ item['code'] }}</div>
                <div class="small text-white-50">{{ item['video_title'] }}</div>
            </div>
        </div>
        {% endfor %}
    </div>

    {% if total_pages > 1 %}
    <nav class="mt-5">
        <ul class="pagination justify-content-center">
            <li class="page-item {{ 'disabled' if current_page <= 1 }}">
                <a class="page-link" href="?q={{query}}&p={{current_page - 1}}">上一页</a>
            </li>
            <li class="page-item"><span class="page-link text-white">{{current_page}} / {{total_pages}}</span></li>
            <li class="page-item {{ 'disabled' if current_page >= total_pages }}">
                <a class="page-link" href="?q={{query}}&p={{current_page + 1}}">下一页</a>
            </li>
        </ul>
    </nav>
    {% endif %}
</div>

<div id="imgOverlay" onclick="this.style.display='none'">
    <img id="overlayImg" src="">
</div>

<div class="modal fade" id="playModal" tabindex="-1">
    <div class="modal-dialog modal-xl modal-dialog-centered">
        <div class="modal-content bg-dark border-secondary">
            <div class="modal-header border-secondary text-white">
                <h6 class="modal-title">视频源选择</h6>
                <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal"></button>
            </div>
            <div class="modal-body">
                <div id="player-box"></div>
                <div id="links-list"></div>
            </div>
        </div>
    </div>
</div>

<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/hls.js@latest"></script>
<script src="https://cdn.jsdelivr.net/npm/artplayer/dist/artplayer.js"></script>

<script>
    let art = null;
    let playModalInst = null;

    document.addEventListener('DOMContentLoaded', () => {
        playModalInst = new bootstrap.Modal(document.getElementById('playModal'));
        document.getElementById('playModal').addEventListener('hidden.bs.modal', stopPlayer);
    });

    function zoomImg(src) {
        const overlay = document.getElementById('imgOverlay');
        document.getElementById('overlayImg').src = src;
        overlay.style.display = 'flex';
    }

    function stopPlayer() { 
        if(art) { art.destroy(true); art = null; } 
        document.getElementById('player-box').style.display = 'none';
    }

    async function searchLinks(code) {
        document.getElementById('links-list').innerHTML = '<div class="text-center p-4">正在解析线路...</div>';
        playModalInst.show();
        stopPlayer();

        try {
            const r = await fetch(`/get_links?code=${encodeURIComponent(code)}`);
            const j = await r.json();
            if(j.data && j.data.length > 0) {
                document.getElementById('links-list').innerHTML = j.data.map(v => `
                    <div class="source-item" onclick="play('${v.url}')">▶ ${v.name}</div>
                `).join('');
            } else {
                document.getElementById('links-list').innerHTML = '<div class="text-center p-4 text-muted">未找到可用 M3U8 资源</div>';
            }
        } catch(e) { 
            document.getElementById('links-list').innerHTML = '<div class="text-center p-4 text-danger">请求出错</div>';
        }
    }

    function play(url) {
        document.getElementById('player-box').style.display = 'block';
        if(art) art.destroy();
        
        art = new Artplayer({
            container: '#player-box',
            url: `/proxy_m3u8?url=${encodeURIComponent(url)}`,
            autoplay: true,
            fullscreen: true,
            playbackRate: true,
            type: 'm3u8',
            customType: {
                m3u8: (video, url) => {
                    if (Hls.isSupported()) {
                        const hls = new Hls();
                        hls.loadSource(url);
                        hls.attachMedia(video);
                    } else { video.src = url; }
                }
            }
        });
    }
</script>
</body>
</html>
"""

@app.route('/')
def index():
    query = request.args.get('q', '').strip()
    page = request.args.get('p', 1, type=int)
    offset = (page - 1) * PER_PAGE
    
    items = []
    total_pages = 0
    
    if os.path.exists(DB_COVERS):
        conn = sqlite3.connect(DB_COVERS)
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()
        
        if query:
            count_sql = "SELECT COUNT(*) FROM code_details WHERE code LIKE ?"
            data_sql = "SELECT code, video_title, video_jacket_img FROM code_details WHERE code LIKE ? LIMIT ? OFFSET ?"
            params = (f"%{query}%", PER_PAGE, offset)
            total_count = cursor.execute(count_sql, (f"%{query}%",)).fetchone()[0]
        else:
            count_sql = "SELECT COUNT(*) FROM code_details"
            data_sql = "SELECT code, video_title, video_jacket_img FROM code_details ORDER BY rowid DESC LIMIT ? OFFSET ?"
            params = (PER_PAGE, offset)
            total_count = cursor.execute(count_sql).fetchone()[0]
            
        items = [dict(r) for r in cursor.execute(data_sql, params).fetchall()]
        
        # 格式化视频标题
        for item in items:
            item['video_title'] = format_video_title(item['video_title'])
            
        total_pages = math.ceil(total_count / PER_PAGE)
        conn.close()
        
    return render_template_string(HTML_TEMPLATE, items=items, query=query, current_page=page, total_pages=total_pages)

@app.route('/get_links')
def get_links():
    code = request.args.get('code', '')
    if not os.path.exists(DB_LINKS): return jsonify({"data": []})
    
    c = sqlite3.connect(DB_LINKS); c.row_factory = sqlite3.Row
    search_code = get_pure_code(code)
    # 模糊匹配番号或纯番号
    res = c.execute("SELECT title, m3u8_url FROM video_links WHERE title LIKE ? OR title LIKE ? LIMIT 10", (f"%{code}%", f"%{search_code}%")).fetchall()
    data = [{"name": format_video_title(r['title']), "url": r['m3u8_url']} for r in res]; c.close()
    return jsonify({"success": True, "data": data})

@app.route('/proxy_m3u8')
def proxy_m3u8():
    target_url = request.args.get('url')
    
    # 验证URL安全性
    if not target_url or not validate_url(target_url):
        logger.warning(f"Invalid URL requested: {target_url}")
        return "Invalid URL", 400
    
    try:
        # 添加请求限制和超时设置
        r = requests.get(target_url, headers=HEADERS, timeout=(5, 10), allow_redirects=True, stream=True)
        
        # 检查响应内容类型
        content_type = r.headers.get('Content-Type', '')
        if 'application/vnd.apple.mpegurl' not in content_type and 'audio/x-mpegurl' not in content_type and 'text/plain' not in content_type:
            logger.warning(f"Invalid content type for m3u8: {content_type}")
            return "Invalid content type", 400
        
        # 限制响应大小
        content_length = r.headers.get('Content-Length')
        if content_length and int(content_length) > 1024 * 1024:  # 1MB limit
            logger.warning(f"M3U8 file too large: {content_length} bytes")
            return "File too large", 413
            
        content = r.text[:1024*1024]  # Limit reading to 1MB
        lines = content.splitlines()
        new_lines = []
        for line in lines:
            line = line.strip()
            if line and not line.startswith('#'):
                full_path = urljoin(target_url, line)
                # Re-validate generated URLs
                if validate_url(full_path):
                    if '.m3u8' in line.lower():
                        new_lines.append(f"/proxy_m3u8?url={quote(full_path)}")
                    else:
                        new_lines.append(f"/proxy_ts?url={quote(full_path)}")
                else:
                    logger.warning(f"Blocked unsafe URL in playlist: {full_path}")
                    new_lines.append("# Blocked unsafe URL")
            else:
                new_lines.append(line)
        return Response("\n".join(new_lines), mimetype='application/vnd.apple.mpegurl')
    except requests.exceptions.RequestException as e:
        logger.error(f"Request error in proxy_m3u8: {str(e)}")
        return "Request failed", 502
    except Exception as e:
        logger.error(f"Server error in proxy_m3u8: {str(e)}")
        return "M3U8 Proxy Error", 500

@app.route('/proxy_ts')
def proxy_ts():
    target_url = unquote(request.args.get('url'))
    
    # 验证URL安全性
    if not target_url or not validate_url(target_url):
        logger.warning(f"Invalid URL requested: {target_url}")
        return "Invalid URL", 400
    
    try:
        # 对TS文件进行更严格的限制，因为它们可能很大
        resp = requests.get(target_url, headers=HEADERS, stream=True, timeout=(5, 30))
        
        # 检查内容类型确保是视频相关类型
        content_type = resp.headers.get('Content-Type', '').lower()
        if not any(ct in content_type for ct in ['video', 'mpeg', 'binary']):
            logger.warning(f"Invalid content type for ts: {content_type}")
            return "Invalid content type", 400
        
        # 检查内容长度，限制单个TS文件大小
        content_length = resp.headers.get('Content-Length')
        if content_length and int(content_length) > 50 * 1024 * 1024:  # 50MB limit
            logger.warning(f"TS file too large: {content_length} bytes")
            return "File too large", 413
        
        def generate():
            chunk_size = 1024 * 1024  # 1MB chunks
            downloaded = 0
            max_size = 50 * 1024 * 1024  # 50MB limit
            
            for chunk in resp.iter_content(chunk_size=chunk_size):
                if chunk:  # filter out keep-alive chunks
                    downloaded += len(chunk)
                    if downloaded > max_size:
                        logger.warning(f"TS download exceeded size limit: {downloaded} bytes")
                        break
                    yield chunk
        
        return Response(generate(), status=resp.status_code, content_type=resp.headers.get('Content-Type'))
    except requests.exceptions.RequestException as e:
        logger.error(f"Request error in proxy_ts: {str(e)}")
        return "Request failed", 502
    except Exception as e:
        logger.error(f"Server error in proxy_ts: {str(e)}")
        return "TS Proxy Error", 500

# 应用安全头到所有响应
@app.after_request
def after_request(response):
    response = add_security_headers(response)
    return response

@app.errorhandler(404)
def not_found(error):
    logger.warning(f"404 error: {request.url}")
    return jsonify({"error": "Resource not found"}), 404

@app.errorhandler(500)
def internal_error(error):
    logger.error(f"Internal server error: {str(error)}")
    return jsonify({"error": "Internal server error"}), 500

@app.route('/health')
def health_check():
    """健康检查端点"""
    return jsonify({"status": "healthy", "timestamp": datetime.utcnow().isoformat()}), 200

if __name__ == '__main__':
    # 在生产环境中不使用此方式启动
    print("Development server not recommended for production!")
    app.run(host='0.0.0.0', port=5000, debug=False)