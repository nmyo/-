import os, zipfile, io, json, sqlite3, threading, time, contextlib, redis
import fitz  # PyMuPDF
from fastapi import FastAPI, Response, HTTPException, Query, Form, Cookie, Depends
from fastapi.responses import HTMLResponse, FileResponse, RedirectResponse
from starlette.middleware.base import BaseHTTPMiddleware
import uvicorn

app = FastAPI()
BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# --- 1. 基础配置 ---
ADMIN_PASS = "123456" 
COOKIE_NAME = "pk_auth"
SYNC_LOCK = threading.Lock()

# --- 2. Redis 缓存引擎 ---
try:
    rd = redis.Redis(host='localhost', port=6379, db=1, socket_timeout=2)
    rd.ping()
    HAS_REDIS = True
except:
    HAS_REDIS = False

class SecurityMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        response = await call_next(request)
        response.headers["X-Frame-Options"] = "DENY"
        return response
app.add_middleware(SecurityMiddleware)

# --- 3. 数据库与路径配置 ---
CONFIG_FILE = os.path.join(BASE_DIR, "settings.json")
if not os.path.exists(CONFIG_FILE):
    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump({"library_path": "./my_comics", "port": 8000}, f, indent=4)

with open(CONFIG_FILE, "r", encoding="utf-8") as f:
    config = json.load(f)

LIB_PATH = os.path.abspath(config.get("library_path", "./my_comics"))
DB_PATH = os.path.join(BASE_DIR, "library.db")

@contextlib.contextmanager
def get_db_conn():
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    try: yield conn
    finally: conn.close()

def init_db():
    with get_db_conn() as conn:
        conn.execute("PRAGMA journal_mode=WAL;") # 提高并发读写性能
        conn.execute('''CREATE TABLE IF NOT EXISTS books 
                       (id INTEGER PRIMARY KEY AUTOINCREMENT, 
                        title TEXT, rel_path TEXT UNIQUE, is_dir INTEGER, add_time INTEGER)''')
        # 索引是解决卡顿的关键
        conn.execute("CREATE INDEX IF NOT EXISTS idx_rel_path ON books(rel_path);")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_title ON books(title);")
        conn.commit()

init_db()

# --- 4. 业务逻辑 ---
def safe_join(base, rel):
    full_path = os.path.abspath(os.path.join(base, rel.lstrip("/")))
    if not full_path.startswith(os.path.abspath(base)): raise HTTPException(403)
    return full_path

def sync_all():
    if not SYNC_LOCK.acquire(blocking=False): return
    try:
        with get_db_conn() as conn:
            existing = {row['rel_path'] for row in conn.execute("SELECT rel_path FROM books").fetchall()}
            found, to_insert, now = set(), [], int(time.time())
            exts = ('.cbz', '.cbr', '.pdf', '.epub', '.zip', '.rar')
            for root, dirs, files in os.walk(LIB_PATH):
                for f in files:
                    if f.lower().endswith(exts):
                        rel = os.path.relpath(os.path.join(root, f), LIB_PATH).replace("\\", "/")
                        found.add(rel)
                        if rel not in existing: to_insert.append((f, rel, 0, now))
                if any(f.lower().endswith(('.jpg','.png','.webp')) for f in files):
                    rel = os.path.relpath(root, LIB_PATH).replace("\\", "/")
                    if rel != ".":
                        found.add(rel)
                        if rel not in existing: to_insert.append((os.path.basename(root), rel, 1, now))
            if to_del := list(existing - found):
                conn.executemany("DELETE FROM books WHERE rel_path = ?", [(p,) for p in to_del])
            if to_insert:
                conn.executemany("INSERT INTO books (title, rel_path, is_dir, add_time) VALUES (?, ?, ?, ?)", to_insert)
            conn.commit()
            if HAS_REDIS: rd.flushdb()
    finally: SYNC_LOCK.release()

# --- 5. API 接口 ---
@app.get("/api/books")
async def get_books(q: str = "", page: int = 1, size: int = 24):
    offset = (page - 1) * size
    with get_db_conn() as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM books WHERE title LIKE ? ORDER BY add_time DESC LIMIT ? OFFSET ?", (f'%{q}%', size, offset)).fetchall()]

@app.get("/api/book_info/{book_id:path}")
async def get_info(book_id: str):
    with get_db_conn() as conn:
        book = conn.execute("SELECT * FROM books WHERE rel_path = ?", (book_id,)).fetchone()
    if not book: raise HTTPException(404)
    path = safe_join(LIB_PATH, book['rel_path'])
    try:
        if book['is_dir']:
            return {"total_pages": len([f for f in os.scandir(path) if f.name.lower().endswith(('.jpg','.png','.webp'))])}
        ext = os.path.splitext(path)[1].lower()
        if ext in ['.zip', '.cbz']:
            with zipfile.ZipFile(path, 'r') as z:
                return {"total_pages": len([i for i in z.namelist() if i.lower().endswith(('.jpg','.jpeg','.png','.webp'))])}
        elif ext in ['.pdf', '.epub']:
            with fitz.open(path) as doc: return {"total_pages": len(doc)}
    except: return {"total_pages": 0}

@app.get("/api/image/{book_id:path}/{page}")
async def get_image(book_id: str, page: int):
    cache_key = f"img:{book_id}:{page}"
    if HAS_REDIS:
        cached = rd.get(cache_key)
        if cached: return Response(content=cached, media_type="image/jpeg")

    with get_db_conn() as conn:
        book = conn.execute("SELECT * FROM books WHERE rel_path = ?", (book_id,)).fetchone()
    if not book: raise HTTPException(404)
    path = safe_join(LIB_PATH, book['rel_path'])
    
    try:
        data = None
        if book['is_dir']:
            imgs = sorted([f.name for f in os.scandir(path) if f.name.lower().endswith(('.jpg','.png','.webp'))])
            with open(os.path.join(path, imgs[page]), 'rb') as f: data = f.read()
        else:
            ext = os.path.splitext(path)[1].lower()
            if ext in ['.zip', '.cbz']:
                with zipfile.ZipFile(path, 'r') as z:
                    imgs = sorted([i for i in z.namelist() if i.lower().endswith(('.jpg','.jpeg','.png','.webp'))])
                    data = z.read(imgs[page])
            elif ext in ['.pdf', '.epub']:
                with fitz.open(path) as doc:
                    zoom = 0.6 if page == 0 else 1.8
                    data = doc[page].get_pixmap(matrix=fitz.Matrix(zoom, zoom)).tobytes("jpg")
        
        if data:
            if HAS_REDIS: rd.setex(cache_key, 3600, data)
            return Response(content=data, media_type="image/jpeg")
    except: pass
    raise HTTPException(404)

@app.get("/api/stats")
async def get_stats(pk_auth: str = Cookie(None)):
    if pk_auth != ADMIN_PASS: raise HTTPException(401)
    with get_db_conn() as conn:
        return {"total": conn.execute("SELECT count(*) FROM books").fetchone()[0], "path": LIB_PATH}

@app.post("/api/sync")
async def api_sync(pk_auth: str = Cookie(None)):
    if pk_auth != ADMIN_PASS: raise HTTPException(401)
    threading.Thread(target=sync_all).start()
    return {"status": "started"}

@app.post("/login")
async def do_login(password: str = Form(...)):
    if password == ADMIN_PASS:
        resp = RedirectResponse(url="/admin", status_code=303)
        resp.set_cookie(key=COOKIE_NAME, value=ADMIN_PASS, httponly=True, max_age=86400*30)
        return resp
    return HTMLResponse("<script>alert('Error'); history.back();</script>")

@app.get("/")
async def index(): return FileResponse(os.path.join(BASE_DIR, "index.html"))
@app.get("/reader")
async def reader(): return FileResponse(os.path.join(BASE_DIR, "reader.html"))
@app.get("/admin")
async def admin_page(): return FileResponse(os.path.join(BASE_DIR, "admin.html"))

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=config.get("port", 8000))