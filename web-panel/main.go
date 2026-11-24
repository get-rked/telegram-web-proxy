package main

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	_ "github.com/mattn/go-sqlite3"
	"golang.org/x/crypto/argon2"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type App struct {
	db                                         *sql.DB
	base, script, backupDir, qrFile, configDir string
	mu                                         sync.Mutex
	failures                                   map[string][]time.Time
	authSem                                    chan struct{}
}

var nameRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`)

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
func random(n int) (string, error) {
	b := make([]byte, n)
	if _, e := rand.Read(b); e != nil {
		return "", e
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}
func derive(p string, s []byte) []byte { return argon2.IDKey([]byte(p), s, 3, 64*1024, 2, 32) }
func (a *App) init() error {
	if e := os.MkdirAll(filepath.Dir(env("PANEL_DB", "/opt/telegram-web-proxy/data/panel/panel.db")), 0700); e != nil {
		return e
	}
	path := env("PANEL_DB", "/opt/telegram-web-proxy/data/panel/panel.db")
	db, e := sql.Open("sqlite3", path+"?_busy_timeout=5000&_journal_mode=WAL&_foreign_keys=on")
	if e != nil {
		return e
	}
	a.db = db
	db.SetMaxOpenConns(1)
	_, e = db.Exec("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY,value TEXT NOT NULL); CREATE TABLE IF NOT EXISTS users (username TEXT PRIMARY KEY,salt BLOB NOT NULL,hash BLOB NOT NULL); CREATE TABLE IF NOT EXISTS sessions (token_hash TEXT PRIMARY KEY,username TEXT NOT NULL,csrf TEXT NOT NULL,expires INTEGER NOT NULL);")
	if e != nil {
		return e
	}
	var n int
	if e = db.QueryRow("SELECT COUNT(*) FROM users").Scan(&n); e != nil {
		return e
	}
	if n == 0 {
		a.base, e = random(24)
		if e != nil {
			return e
		}
		u, e := random(6)
		if e != nil {
			return e
		}
		p, e := random(24)
		if e != nil {
			return e
		}
		login := "admin-" + u
		salt := make([]byte, 16)
		if _, e = rand.Read(salt); e != nil {
			return e
		}
		if _, e = db.Exec("INSERT INTO settings VALUES('base_path',?)", a.base); e != nil {
			return e
		}
		if _, e = db.Exec("INSERT INTO users VALUES(?,?,?)", login, salt, derive(p, salt)); e != nil {
			return e
		}
		cred := fmt.Sprintf("URL_PATH=/%s/\nLOGIN=%s\nPASSWORD=%s\n", a.base, login, p)
		credPath := filepath.Join(filepath.Dir(path), "panel-credentials.txt")
		_ = os.Remove(credPath)
		f, e := os.OpenFile(credPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if e == nil {
			_, e = f.WriteString(cred)
			ce := f.Close()
			if e == nil {
				e = ce
			}
		}
		if e != nil && !os.IsExist(e) {
			return e
		}
		log.Printf("ADMIN_BOOTSTRAP credentials_file=%s", credPath)
	} else {
		if e = db.QueryRow("SELECT value FROM settings WHERE key='base_path'").Scan(&a.base); e != nil {
			return e
		}
	}
	_, _ = db.Exec("DELETE FROM sessions WHERE expires < ?", time.Now().Unix())
	return os.Chmod(path, 0600)
}
func (a *App) remote(r *http.Request) string {
	h, _, e := net.SplitHostPort(r.RemoteAddr)
	if e != nil {
		h = r.RemoteAddr
	}
	if h == "127.0.0.1" || h == "::1" {
		candidate := r.Header.Get("X-Real-IP")
		if candidate == "" {
			candidate = strings.TrimSpace(strings.Split(r.Header.Get("X-Forwarded-For"), ",")[0])
		}
		if ip := net.ParseIP(candidate); ip != nil {
			return ip.String()
		}
	}
	return h
}
func (a *App) blocked(r *http.Request) bool {
	h := a.remote(r)
	a.mu.Lock()
	defer a.mu.Unlock()
	now := time.Now()
	v := a.failures[h][:0]
	for _, t := range a.failures[h] {
		if now.Sub(t) < 10*time.Minute {
			v = append(v, t)
		}
	}
	a.failures[h] = v
	return len(v) >= 8
}
func (a *App) badLogin(r *http.Request) {
	h := a.remote(r)
	log.Printf("[AUTH_FAIL] remote=%s", h)
	a.mu.Lock()
	defer a.mu.Unlock()
	a.failures[h] = append(a.failures[h], time.Now())
}
func (a *App) session(r *http.Request) (string, string, bool) {
	c, e := r.Cookie("tproxy_panel")
	if e != nil {
		return "", "", false
	}
	s := sha256.Sum256([]byte(c.Value))
	var u, csrf string
	var exp int64
	e = a.db.QueryRow("SELECT username,csrf,expires FROM sessions WHERE token_hash=?", hex.EncodeToString(s[:])).Scan(&u, &csrf, &exp)
	return u, csrf, e == nil && exp > time.Now().Unix()
}
func (a *App) cookie(w http.ResponseWriter, v string, exp time.Time) {
	http.SetCookie(w, &http.Cookie{Name: "tproxy_panel", Value: v, Path: "/" + a.base + "/", HttpOnly: true, Secure: true, SameSite: http.SameSiteStrictMode, Expires: exp, MaxAge: int(time.Until(exp).Seconds())})
}
func (a *App) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		_, csrf, ok := a.session(r)
		if !ok {
			http.Error(w, "unauthorized", 401)
			return
		}
		if r.Method != "GET" && r.Method != "HEAD" && r.Header.Get("X-CSRF-Token") != csrf {
			http.Error(w, "csrf failed", 403)
			return
		}
		w.Header().Set("X-CSRF-Token", csrf)
		next(w, r)
	}
}
func jsonOut(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(v)
}
func errOut(w http.ResponseWriter, n int, s string) {
	w.WriteHeader(n)
	jsonOut(w, map[string]string{"error": s})
}
func (a *App) cmd(ctx context.Context, args ...string) (string, error) {
	c := exec.CommandContext(ctx, a.script, args...)
	c.Env = append(os.Environ(), "NO_COLOR=1", "TERM=dumb")
	b, e := c.CombinedOutput()
	if len(b) > 65536 {
		b = b[len(b)-65536:]
	}
	if e != nil {
		return string(b), e
	}
	return string(b), nil
}
func (a *App) login(w http.ResponseWriter, r *http.Request) {
	if r.Method == "GET" {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		io.WriteString(w, loginHTML)
		return
	}
	if r.Method != "POST" {
		http.Error(w, "method not allowed", 405)
		return
	}
	if a.blocked(r) {
		http.Error(w, "too many attempts", 429)
		return
	}
	_ = r.ParseForm()
	var salt, hash []byte
	e := a.db.QueryRow("SELECT salt,hash FROM users WHERE username=?", r.FormValue("username")).Scan(&salt, &hash)
	select {
	case a.authSem <- struct{}{}:
		defer func() { <-a.authSem }()
	case <-r.Context().Done():
		return
	}
	got := derive(r.FormValue("password"), salt)
	if e != nil || !hmac.Equal(got, hash) {
		a.badLogin(r)
		http.Error(w, "Неверный логин или пароль", 401)
		return
	}
	token, e := random(32)
	if e != nil {
		http.Error(w, "internal error", 500)
		return
	}
	csrf, e := random(24)
	if e != nil {
		http.Error(w, "internal error", 500)
		return
	}
	sum := sha256.Sum256([]byte(token))
	exp := time.Now().Add(12 * time.Hour)
	_, e = a.db.Exec("INSERT INTO sessions VALUES(?,?,?,?)", hex.EncodeToString(sum[:]), r.FormValue("username"), csrf, exp.Unix())
	if e != nil {
		http.Error(w, "internal error", 500)
		return
	}
	a.cookie(w, token, exp)
	http.Redirect(w, r, "/"+a.base+"/", 303)
}
func (a *App) logout(w http.ResponseWriter, r *http.Request) {
	if c, e := r.Cookie("tproxy_panel"); e == nil {
		s := sha256.Sum256([]byte(c.Value))
		_, _ = a.db.Exec("DELETE FROM sessions WHERE token_hash=?", hex.EncodeToString(s[:]))
	}
	a.cookie(w, "", time.Unix(1, 0))
	http.Redirect(w, r, "/"+a.base+"/login", 303)
}
func (a *App) home(w http.ResponseWriter, r *http.Request) {
	if _, _, ok := a.session(r); !ok {
		http.Redirect(w, r, "/"+a.base+"/login", 303)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	io.WriteString(w, dashboardHTML)
}
func (a *App) profiles(w http.ResponseWriter, r *http.Request) {
	ctx, c := context.WithTimeout(r.Context(), 25*time.Second)
	defer c()
	if r.Method == "GET" {
		out, e := a.cmd(ctx, "profile", "list")
		if e != nil {
			errOut(w, 500, "Не удалось получить профили")
			return
		}
		items := []map[string]string{}
		for _, line := range strings.Split(out, "\n") {
			f := strings.Fields(line)
			if len(f) >= 3 && f[0] != "ИМЯ" {
				items = append(items, map[string]string{"name": f[0], "carrier_mode": f[1], "backend": f[2]})
			}
		}
		jsonOut(w, items)
		return
	}
	if r.Method == "POST" {
		var b struct{ Name string }
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&b) != nil || !nameRE.MatchString(b.Name) {
			errOut(w, 400, "Некорректное имя профиля")
			return
		}
		if _, e := a.cmd(ctx, "profile", "add", b.Name, "--generate"); e != nil {
			errOut(w, 409, "Не удалось создать профиль")
			return
		}
		jsonOut(w, map[string]string{"status": "created"})
		return
	}
	http.Error(w, "method not allowed", 405)
}
func (a *App) profileAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, "method not allowed", 405)
		return
	}
	name := strings.TrimPrefix(r.URL.Path, "/"+a.base+"/api/profiles/")
	if !nameRE.MatchString(name) {
		errOut(w, 400, "Некорректное имя")
		return
	}
	var b struct{ Action string }
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&b) != nil {
		errOut(w, 400, "Некорректный запрос")
		return
	}
	ctx, c := context.WithTimeout(r.Context(), 35*time.Second)
	defer c()
	var args []string
	switch b.Action {
	case "delete":
		args = []string{"profile", "delete", name, "--yes"}
	case "backup":
		args = []string{"profile", "backup", name}
	default:
		errOut(w, 400, "Неизвестная операция")
		return
	}
	if _, e := a.cmd(ctx, args...); e != nil {
		errOut(w, 409, "Операция не выполнена")
		return
	}
	jsonOut(w, map[string]string{"status": "ok"})
}
func (a *App) configuration(w http.ResponseWriter, r *http.Request) {
	if r.Method != "GET" {
		http.Error(w, "method not allowed", 405)
		return
	}
	out := map[string]any{}
	for _, name := range []string{"config.json", "profiles.json"} {
		raw, e := os.ReadFile(filepath.Join(a.configDir, name))
		if e != nil {
			errOut(w, 500, "Не удалось прочитать конфигурацию")
			return
		}
		var value any
		if json.Unmarshal(raw, &value) != nil {
			errOut(w, 500, "Конфигурация содержит некорректный JSON")
			return
		}
		out[name] = redactConfig(value)
	}
	jsonOut(w, out)
}
func redactConfig(v any) any {
	switch x := v.(type) {
	case map[string]any:
		for k, value := range x {
			lk := strings.ToLower(k)
			if strings.Contains(lk, "secret") || strings.Contains(lk, "password") || strings.Contains(lk, "token") {
				x[k] = "[REDACTED]"
			} else {
				x[k] = redactConfig(value)
			}
		}
		return x
	case []any:
		for i, value := range x {
			x[i] = redactConfig(value)
		}
		return x
	default:
		return v
	}
}
func (a *App) diagnostics(w http.ResponseWriter, r *http.Request) {
	ctx, c := context.WithTimeout(r.Context(), 50*time.Second)
	defer c()
	out, e := a.cmd(ctx, "diagnostics")
	status := "ok"
	if e != nil {
		status = "warning"
	}
	jsonOut(w, map[string]string{"status": status, "output": out})
}
func (a *App) backups(w http.ResponseWriter, r *http.Request) {
	if r.Method == "GET" {
		files, _ := filepath.Glob(filepath.Join(a.backupDir, "tproxy-backup-*.tar.gz"))
		sort.Sort(sort.Reverse(sort.StringSlice(files)))
		out := []map[string]any{}
		for _, f := range files {
			if s, e := os.Stat(f); e == nil {
				out = append(out, map[string]any{"name": filepath.Base(f), "size": s.Size(), "modified": s.ModTime()})
			}
		}
		jsonOut(w, out)
		return
	}
	if r.Method != "POST" {
		http.Error(w, "method not allowed", 405)
		return
	}
	var b struct {
		Action string
		Name   string
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&b) != nil {
		errOut(w, 400, "Некорректный запрос")
		return
	}
	ctx, c := context.WithTimeout(r.Context(), 3*time.Minute)
	defer c()
	if b.Action == "create" {
		out, e := a.cmd(ctx, "backup")
		if e != nil {
			errOut(w, 500, "Не удалось создать архив")
			return
		}
		jsonOut(w, map[string]string{"status": "created", "message": out})
		return
	}
	if b.Action == "restore" {
		if !regexp.MustCompile(`^tproxy-backup-[0-9]{8}-[0-9]{6}.tar.gz$`).MatchString(b.Name) {
			errOut(w, 400, "Некорректное имя архива")
			return
		}
		files, _ := filepath.Glob(filepath.Join(a.backups, "tproxy-backup-*.tar.gz"))
		sort.Sort(sort.Reverse(sort.StringSlice(files)))
		idx := 0
		for i, f := range files {
			if filepath.Base(f) == b.Name {
				idx = i + 1
			}
		}
		if idx == 0 {
			errOut(w, 404, "Архив не найден")
			return
		}
		if _, e := a.cmd(ctx, "restore", strconv.Itoa(idx), "--yes"); e != nil {
			errOut(w, 500, "Восстановление не выполнено")
			return
		}
		jsonOut(w, map[string]string{"status": "restored"})
		if flusher, ok := w.(http.Flusher); ok {
			flusher.Flush()
		}
		go func() {
			time.Sleep(2 * time.Second)
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			_ = exec.CommandContext(ctx, "systemctl", "restart", "tproxy-panel.service").Run()
		}()
		return
	}
	errOut(w, 400, "Неизвестная операция")
}
func (a *App) qr(w http.ResponseWriter, r *http.Request) {
	f, e := os.Open(a.qrFile)
	if e != nil {
		http.NotFound(w, r)
		return
	}
	defer f.Close()
	w.Header().Set("Content-Type", "image/png")
	io.Copy(w, f)
}
func (a *App) routes() http.Handler {
	m := http.NewServeMux()
	p := "/" + a.base
	m.HandleFunc(p+"/login", a.login)
	m.HandleFunc(p+"/logout", a.auth(a.logout))
	m.HandleFunc(p+"/", a.home)
	m.HandleFunc(p+"/api/profiles", a.auth(a.profiles))
	m.HandleFunc(p+"/api/profiles/", a.auth(a.profileAction))
	m.HandleFunc(p+"/api/diagnostics", a.auth(a.diagnostics))
	m.HandleFunc(p+"/api/config", a.auth(a.configuration))
	m.HandleFunc(p+"/api/backups", a.auth(a.backups))
	m.HandleFunc(p+"/api/qr", a.auth(a.qr))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'")
		w.Header().Set("Cache-Control", "no-store")
		m.ServeHTTP(w, r)
	})
}
func main() {
	a := &App{script: env("PANEL_SCRIPT", "/opt/telegram-web-proxy/tgweb-install.sh"), backupDir: env("PANEL_BACKUP_DIR", "/opt/telegram-web-proxy/backups"), qrFile: env("PANEL_QR", "/opt/telegram-web-proxy/qr/proxy-qr.png"), configDir: env("PANEL_CONFIG_DIR", "/opt/telegram-web-proxy/config/proxy"), failures: map[string][]time.Time{}, authSem: make(chan struct{}, 2)}
	if e := a.init(); e != nil {
		log.Fatal(e)
	}
	if len(os.Args) > 1 && os.Args[1] == "-print-basepath" {
		fmt.Println(a.base)
		return
	}
	s := &http.Server{Addr: env("PANEL_LISTEN", "127.0.0.1:18765"), Handler: a.routes(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 180 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 1 << 20}
	log.Printf("admin panel listening on %s", s.Addr)
	log.Fatal(s.ListenAndServe())
}

const loginHTML = `<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>TPROXY · Вход</title><style>*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;background:radial-gradient(circle at 15% 15%,#203c5c,#0b1220 55%);font:15px system-ui;color:#e8eef8}.box{width:min(420px,calc(100% - 32px));padding:38px;border:1px solid #ffffff20;border-radius:24px;background:#101c2bdc;box-shadow:0 24px 80px #0008}.brand{color:#82b8ff;font-weight:900;letter-spacing:.2em}.box h1{font-size:28px;margin:24px 0 8px}.muted{color:#9eafc5;margin-bottom:28px}label{display:block;margin:16px 0 7px}input{width:100%;padding:14px;border-radius:12px;border:1px solid #33465e;background:#0b1523;color:white;font:inherit}button{width:100%;margin-top:24px;padding:14px;border:0;border-radius:12px;background:linear-gradient(110deg,#4c8cff,#63d4c3);font-weight:800;color:#071321}</style><body><form class="box" method="post"><div class="brand">TPROXY / CONTROL</div><h1>Вход в панель</h1><div class="muted">Защищённое управление прокси</div><label>Логин</label><input name="username" autocomplete="username" required><label>Пароль</label><input type="password" name="password" autocomplete="current-password" required><button>Войти →</button></form></body></html>`

const dashboardHTML = `<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>TPROXY · Управление</title><style>:root{color-scheme:dark;--bg:#0b1220;--panel:#111d2d;--line:#26374d;--muted:#8fa2ba;--text:#edf4ff;--blue:#73a9ff;--mint:#65d8c1}*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 80% 0%,#172d48 0,transparent 34%),var(--bg);color:var(--text);font:14px system-ui}.shell{max-width:1200px;margin:auto;padding:28px}.top{display:flex;justify-content:space-between;margin-bottom:28px}.brand{font-weight:900;letter-spacing:.17em;color:var(--blue)}small,.meta,.sub{color:var(--muted)}.hero,.card{border:1px solid var(--line);border-radius:20px;background:#111d2d;padding:24px;margin-bottom:18px}.hero{background:linear-gradient(120deg,#182b43,#101a29)}.eyebrow{color:var(--mint);letter-spacing:.2em;font-size:11px;font-weight:800}.hero h1{font-size:34px;margin:12px 0}.grid{display:grid;grid-template-columns:1fr 1fr;gap:18px}.wide{grid-column:1/-1}.card h2{font-size:17px;margin:0 0 16px}.row{display:flex;justify-content:space-between;align-items:center;gap:12px;padding:13px 0;border-bottom:1px solid #ffffff12}.row:last-child{border:0}.meta{font-size:12px;margin-top:5px}.actions,.toolbar,.formline{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:12px}button,select,input{font:inherit;border-radius:9px;padding:10px;background:#0b1523;color:#edf4ff;border:1px solid var(--line)}button{cursor:pointer;background:#1b3552;border-color:#3b587a}button.primary{background:linear-gradient(110deg,#4c8cff,#63cdbd);border:0;color:#071321;font-weight:800}button.danger{background:#3a202a;color:#ffc5c8}pre{white-space:pre-wrap;max-height:420px;overflow:auto;background:#09111d;border:1px solid var(--line);padding:15px;border-radius:12px;color:#b9c9dc;font:12px monospace}.qr{max-width:210px;background:white;padding:10px;border-radius:12px}.logout{color:#b8c8dc;text-decoration:none;border:1px solid var(--line);padding:10px 14px;border-radius:10px}@media(max-width:760px){.shell{padding:16px}.grid{grid-template-columns:1fr}.wide{grid-column:auto}.row{align-items:flex-start;flex-direction:column}.hero h1{font-size:27px}}</style></head><body><main class="shell"><header class="top"><div class="brand">TPROXY <small><br>ADMIN CONSOLE · SECURE ACCESS</small></div><a class="logout" href="#" onclick="logout()">Выйти ↗</a></header><section class="hero"><div class="eyebrow">CONTROL CENTER</div><h1>Управление прокси</h1><div class="sub">Профили, диагностика и резервные копии</div></section><div class="grid"><section class="card"><h2>Система</h2><p>● Панель авторизована</p><div class="meta">Внутренний сервис доступен только через reverse proxy.</div></section><section class="card"><h2>Быстрые действия</h2><div class="toolbar"><button class="primary" onclick="backup()">＋ Создать резервную копию</button><button onclick="loadAll()">↻ Обновить</button></div></section><section class="card wide"><h2>Профили</h2><div class="formline"><input id="newName" placeholder="Имя профиля" maxlength="64"><button class="primary" onclick="add()">Создать профиль</button></div><div id="profiles">Загрузка…</div></section><section class="card wide"><h2>Конфигурация</h2><button onclick="loadConfig()">Показать конфигурацию (секреты скрыты)</button><pre id="config">Нажмите «Показать конфигурацию».</pre></section><section class="card wide"><h2>Диагностика</h2><button onclick="diagnostics()">Запустить проверку</button><pre id="diag">Нажмите «Запустить проверку».</pre></section><section class="card wide"><h2>Резервные копии</h2><div class="toolbar"><button onclick="backup()" class="primary">Создать копию</button><button onclick="loadBackups()">Обновить список</button></div><div id="backups">Загрузка…</div></section><section class="card"><h2>QR подключения</h2><img class="qr" src="api/qr" alt="QR-код прокси"></section></div></main><script>
let csrf='';
const base=location.pathname.replace(/\/$/,'');
async function api(path,opts={}){opts.credentials='same-origin';opts.headers=Object.assign({'Content-Type':'application/json','X-CSRF-Token':csrf},opts.headers||{});let r=await fetch(path,opts);csrf=r.headers.get('X-CSRF-Token')||csrf;if(r.status===401){location.href='login';throw Error('Сессия завершена')}let d=await r.json().catch(()=>({}));if(!r.ok)throw Error(d.error||'Ошибка запроса');return d}
function esc(s){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
function show(e){alert(e.message||String(e))}
async function loadProfiles(){try{let p=await api(base+'/api/profiles');document.querySelector('#profiles').innerHTML=p.map(x=>'<div class="row"><div><b>'+esc(x.name)+'</b><div class="meta">'+esc(x.carrier_mode)+' · '+esc(x.backend)+'</div></div><div class="actions">'+(x.name==='default'?'':'<button class="danger" onclick="removeProfile(\''+esc(x.name)+'\')">Удалить</button>')+'</div></div>').join('')||'Профили не найдены'}catch(e){show(e)}}
async function add(){try{await api(base+'/api/profiles',{method:'POST',body:JSON.stringify({Name:document.querySelector('#newName').value.trim()})});document.querySelector('#newName').value='';loadProfiles()}catch(e){show(e)}}
async function removeProfile(n){if(!confirm('Удалить профиль '+n+'?'))return;try{await api(base+'/api/profiles/'+encodeURIComponent(n),{method:'POST',body:JSON.stringify({Action:'delete'})});loadProfiles()}catch(e){show(e)}}
async function loadConfig(){try{let c=await api(base+'/api/config');document.querySelector('#config').textContent=JSON.stringify(c,null,2)}catch(e){document.querySelector('#config').textContent=e.message}}
async function diagnostics(){try{let d=await api(base+'/api/diagnostics');document.querySelector('#diag').textContent=d.output}catch(e){document.querySelector('#diag').textContent=e.message}}
async function loadBackups(){try{let b=await api(base+'/api/backups');document.querySelector('#backups').innerHTML=b.map(x=>'<div class="row"><div><b>'+esc(x.name)+'</b><div class="meta">'+(x.size/1048576).toFixed(2)+' MB · '+new Date(x.modified).toLocaleString()+'</div></div><button onclick="restore(\''+esc(x.name)+'\')">Восстановить</button></div>').join('')||'Архивов пока нет'}catch(e){show(e)}}
async function backup(){if(!confirm('Создать полную резервную копию?'))return;try{await api(base+'/api/backups',{method:'POST',body:JSON.stringify({Action:'create'})});loadBackups()}catch(e){show(e)}}
async function restore(n){if(!confirm('ВНИМАНИЕ: восстановление заменит текущую конфигурацию. Продолжить?'))return;try{await api(base+'/api/backups',{method:'POST',body:JSON.stringify({Action:'restore',Name:n})});alert('Восстановление завершено');loadAll()}catch(e){show(e)}}
async function logout(){try{await api(base+'/logout',{method:'POST',body:'{}'})}catch(e){location.href='login'}}
function loadAll(){loadProfiles().then(loadBackups)}loadAll();
</script></body></html>`
