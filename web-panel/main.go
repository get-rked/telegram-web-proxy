package main

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
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

	_ "github.com/mattn/go-sqlite3"
	"golang.org/x/crypto/argon2"
)

//go:embed templates/*.html
var htmlFiles embed.FS

type App struct {
	db        *sql.DB
	base      string
	script    string
	backupDir string
	qrFile    string
	configDir string
	mu        sync.Mutex
	failures  map[string][]time.Time
	authSem   chan struct{}
}

var nameRE = regexp.MustCompile("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")

func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func randomToken(size int) (string, error) {
	data := make([]byte, size)
	if _, err := rand.Read(data); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(data), nil
}

func passwordHash(password string, salt []byte) []byte {
	return argon2.IDKey([]byte(password), salt, 3, 64*1024, 2, 32)
}

func (a *App) init() error {
	path := env("PANEL_DB", "/opt/telegram-web-proxy/data/panel/panel.db")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	db, err := sql.Open("sqlite3", path+"?_busy_timeout=5000&_journal_mode=WAL&_foreign_keys=on")
	if err != nil {
		return err
	}
	a.db = db
	db.SetMaxOpenConns(1)

	statements := []string{
		"CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
		"CREATE TABLE IF NOT EXISTS users (username TEXT PRIMARY KEY, salt BLOB NOT NULL, password_hash BLOB NOT NULL)",
		"CREATE TABLE IF NOT EXISTS sessions (token_hash TEXT PRIMARY KEY, username TEXT NOT NULL, csrf TEXT NOT NULL, expires_at INTEGER NOT NULL)",
		"CREATE INDEX IF NOT EXISTS sessions_expiry ON sessions(expires_at)",
	}
	for _, statement := range statements {
		if _, err := db.Exec(statement); err != nil {
			return err
		}
	}

	var users int
	if err := db.QueryRow("SELECT COUNT(*) FROM users").Scan(&users); err != nil {
		return err
	}
	if users == 0 {
		base, err := randomToken(24)
		if err != nil {
			return err
		}
		loginSuffix, err := randomToken(6)
		if err != nil {
			return err
		}
		password, err := randomToken(24)
		if err != nil {
			return err
		}
		username := "admin-" + loginSuffix
		salt := make([]byte, 16)
		if _, err := rand.Read(salt); err != nil {
			return err
		}
		if _, err := db.Exec("INSERT INTO settings(key,value) VALUES('base_path',?)", base); err != nil {
			return err
		}
		if _, err := db.Exec("INSERT INTO users(username,salt,password_hash) VALUES(?,?,?)", username, salt, passwordHash(password, salt)); err != nil {
			return err
		}

		credentialsPath := filepath.Join(filepath.Dir(path), "panel-credentials.txt")
		_ = os.Remove(credentialsPath)
		credentials := fmt.Sprintf("URL_PATH=/%s/\nLOGIN=%s\nPASSWORD=%s\n", base, username, password)
		file, err := os.OpenFile(credentialsPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			return err
		}
		if _, err := file.WriteString(credentials); err != nil {
			_ = file.Close()
			return err
		}
		if err := file.Close(); err != nil {
			return err
		}
		a.base = base
		log.Printf("ADMIN_BOOTSTRAP credentials_file=%s", credentialsPath)
	} else {
		if err := db.QueryRow("SELECT value FROM settings WHERE key='base_path'").Scan(&a.base); err != nil {
			return err
		}
	}

	_, _ = db.Exec("DELETE FROM sessions WHERE expires_at < ?", time.Now().Unix())
	return os.Chmod(path, 0600)
}

func (a *App) remoteIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	if host == "127.0.0.1" || host == "::1" {
		candidate := r.Header.Get("X-Real-IP")
		if candidate == "" {
			candidate = strings.TrimSpace(strings.Split(r.Header.Get("X-Forwarded-For"), ",")[0])
		}
		if ip := net.ParseIP(candidate); ip != nil {
			return ip.String()
		}
	}
	return host
}

func (a *App) blocked(r *http.Request) bool {
	ip := a.remoteIP(r)
	a.mu.Lock()
	defer a.mu.Unlock()

	now := time.Now()
	kept := a.failures[ip][:0]
	for _, attempt := range a.failures[ip] {
		if now.Sub(attempt) < 10*time.Minute {
			kept = append(kept, attempt)
		}
	}
	a.failures[ip] = kept
	return len(kept) >= 8
}

func (a *App) badLogin(r *http.Request) {
	ip := a.remoteIP(r)
	log.Printf("[AUTH_FAIL] remote=%s", ip)
	a.mu.Lock()
	a.failures[ip] = append(a.failures[ip], time.Now())
	a.mu.Unlock()
}

func (a *App) session(r *http.Request) (string, string, bool) {
	cookie, err := r.Cookie("tproxy_panel")
	if err != nil {
		return "", "", false
	}
	sum := sha256.Sum256([]byte(cookie.Value))
	var username, csrf string
	var expires int64
	err = a.db.QueryRow("SELECT username,csrf,expires_at FROM sessions WHERE token_hash=?", hex.EncodeToString(sum[:])).Scan(&username, &csrf, &expires)
	return username, csrf, err == nil && expires > time.Now().Unix()
}

func (a *App) setCookie(w http.ResponseWriter, value string, expires time.Time) {
	http.SetCookie(w, &http.Cookie{
		Name: "tproxy_panel", Value: value, Path: "/" + a.base + "/",
		HttpOnly: true, Secure: true, SameSite: http.SameSiteStrictMode,
		Expires: expires, MaxAge: int(time.Until(expires).Seconds()),
	})
}

func (a *App) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		_, csrf, ok := a.session(r)
		if !ok {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead && r.Header.Get("X-CSRF-Token") != csrf {
			http.Error(w, "csrf validation failed", http.StatusForbidden)
			return
		}
		w.Header().Set("X-CSRF-Token", csrf)
		next(w, r)
	}
}

func jsonOut(w http.ResponseWriter, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(value)
}

func errOut(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": message})
}

func (a *App) command(ctx context.Context, args ...string) (string, error) {
	if a.script == "" {
		return "", fmt.Errorf("installer script is not configured")
	}
	cmd := exec.CommandContext(ctx, a.script, args...)
	cmd.Env = append(os.Environ(), "NO_COLOR=1", "TERM=dumb")
	output, err := cmd.CombinedOutput()
	if len(output) > 64*1024 {
		output = output[len(output)-64*1024:]
	}
	if err != nil {
		return string(output), fmt.Errorf("installer operation failed: %w", err)
	}
	return string(output), nil
}

func (a *App) login(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		page, err := htmlFiles.ReadFile("templates/login.html")
		if err != nil {
			http.Error(w, "login template unavailable", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write(page)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if a.blocked(r) {
		http.Error(w, "too many attempts", http.StatusTooManyRequests)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "invalid form", http.StatusBadRequest)
		return
	}

	var salt, stored []byte
	err := a.db.QueryRow("SELECT salt,password_hash FROM users WHERE username=?", r.FormValue("username")).Scan(&salt, &stored)
	select {
	case a.authSem <- struct{}{}:
		defer func() { <-a.authSem }()
	case <-r.Context().Done():
		return
	}
	calculated := passwordHash(r.FormValue("password"), salt)
	if err != nil || !hmac.Equal(calculated, stored) {
		a.badLogin(r)
		http.Error(w, "Неверный логин или пароль", http.StatusUnauthorized)
		return
	}

	token, err := randomToken(32)
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	csrf, err := randomToken(24)
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	sum := sha256.Sum256([]byte(token))
	expires := time.Now().Add(12 * time.Hour)
	if _, err := a.db.Exec("INSERT INTO sessions(token_hash,username,csrf,expires_at) VALUES(?,?,?,?)", hex.EncodeToString(sum[:]), r.FormValue("username"), csrf, expires.Unix()); err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	a.setCookie(w, token, expires)
	http.Redirect(w, r, "/"+a.base+"/", http.StatusSeeOther)
}

func (a *App) logout(w http.ResponseWriter, r *http.Request) {
	if cookie, err := r.Cookie("tproxy_panel"); err == nil {
		sum := sha256.Sum256([]byte(cookie.Value))
		_, _ = a.db.Exec("DELETE FROM sessions WHERE token_hash=?", hex.EncodeToString(sum[:]))
	}
	a.setCookie(w, "", time.Unix(1, 0))
	http.Redirect(w, r, "/"+a.base+"/login", http.StatusSeeOther)
}

func (a *App) home(w http.ResponseWriter, r *http.Request) {
	if _, _, ok := a.session(r); !ok {
		http.Redirect(w, r, "/"+a.base+"/login", http.StatusSeeOther)
		return
	}
	page, err := htmlFiles.ReadFile("templates/dashboard.html")
	if err != nil {
		http.Error(w, "dashboard template unavailable", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write(page)
}

func (a *App) profiles(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 25*time.Second)
	defer cancel()

	if r.Method == http.MethodGet {
		output, err := a.command(ctx, "profile", "list")
		if err != nil {
			errOut(w, http.StatusInternalServerError, "Не удалось получить список профилей")
			return
		}
		items := []map[string]string{}
		for _, line := range strings.Split(output, "\n") {
			fields := strings.Fields(line)
			if len(fields) >= 3 && fields[0] != "ИМЯ" {
				items = append(items, map[string]string{
					"name": fields[0], "carrier_mode": fields[1], "backend": fields[2],
				})
			}
		}
		jsonOut(w, items)
		return
	}

	if r.Method == http.MethodPost {
		var body struct{ Name string }
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body) != nil || !nameRE.MatchString(body.Name) {
			errOut(w, http.StatusBadRequest, "Некорректное имя профиля")
			return
		}
		if _, err := a.command(ctx, "profile", "add", body.Name, "--generate"); err != nil {
			errOut(w, http.StatusConflict, "Не удалось создать профиль")
			return
		}
		jsonOut(w, map[string]string{"status": "created"})
		return
	}
	http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
}

func (a *App) profileAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	name := strings.TrimPrefix(r.URL.Path, "/"+a.base+"/api/profiles/")
	if !nameRE.MatchString(name) {
		errOut(w, http.StatusBadRequest, "Некорректное имя профиля")
		return
	}
	var body struct{ Action string }
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body) != nil {
		errOut(w, http.StatusBadRequest, "Некорректный запрос")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 35*time.Second)
	defer cancel()
	var args []string
	switch body.Action {
	case "delete":
		args = []string{"profile", "delete", name, "--yes"}
	case "backup":
		args = []string{"profile", "backup", name}
	default:
		errOut(w, http.StatusBadRequest, "Неизвестная операция")
		return
	}
	if _, err := a.command(ctx, args...); err != nil {
		errOut(w, http.StatusConflict, "Операция не выполнена")
		return
	}
	jsonOut(w, map[string]string{"status": "ok"})
}


func (a *App) profileImport(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 102<<20)
	if err := r.ParseMultipartForm(10 << 20); err != nil {
		errOut(w, http.StatusBadRequest, "Не удалось прочитать архив или превышен лимит 100 МБ")
		return
	}
	if r.MultipartForm != nil {
		defer r.MultipartForm.RemoveAll()
	}
	file, header, err := r.FormFile("archive")
	if err != nil || header.Size > 100<<20 {
		errOut(w, http.StatusBadRequest, "Выберите архив профиля размером до 100 МБ")
		return
	}
	defer file.Close()

	target := r.FormValue("target")
	name := r.FormValue("name")
	entry := r.FormValue("entry")
	args := []string{}
	if target == "default" {
		args = append(args, "--replace-default")
	} else if target == "new" && nameRE.MatchString(name) {
		args = append(args, "--name", name)
	} else {
		errOut(w, http.StatusBadRequest, "Укажите корректный тип импорта и имя профиля")
		return
	}
	if entry != "" && !regexp.MustCompile("^(profiles|opt/telegram-web-proxy/config/proxy/profiles)/[A-Za-z0-9][A-Za-z0-9_-]{0,63}/profile\\.json$").MatchString(entry) {
		errOut(w, http.StatusBadRequest, "Некорректный путь профиля внутри архива")
		return
	}

	importDir := filepath.Join(a.backupDir, "imports")
	if err := os.MkdirAll(importDir, 0700); err != nil {
		errOut(w, http.StatusInternalServerError, "Не удалось подготовить временную директорию")
		return
	}
	temp, err := os.CreateTemp(importDir, "profile-import-*.tar.gz")
	if err != nil {
		errOut(w, http.StatusInternalServerError, "Не удалось сохранить загруженный архив")
		return
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	written, copyErr := io.Copy(temp, io.LimitReader(file, (100<<20)+1))
	closeErr := temp.Close()
	if copyErr != nil || closeErr != nil || written > 100<<20 {
		errOut(w, http.StatusBadRequest, "Не удалось сохранить архив или превышен лимит 10 МБ")
		return
	}
	if err := os.Chmod(tempPath, 0600); err != nil {
		errOut(w, http.StatusInternalServerError, "Не удалось защитить временный архив")
		return
	}
	args = append([]string{"profile", "import", tempPath}, args...)
	if entry != "" {
		args = append(args, "--entry", entry)
	}
	args = append(args, "--yes")

	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Minute)
	defer cancel()
	if _, err := a.command(ctx, args...); err != nil {
		errOut(w, http.StatusConflict, "Импорт не выполнен: проверьте архив, имя и выбранный профиль")
		return
	}
	jsonOut(w, map[string]string{"status": "imported"})
}

func (a *App) profileBackupDownload(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/"+a.base+"/api/profile-backups/")
	pattern := regexp.MustCompile("^trpoxy-profile-backup-[A-Za-z0-9_-]+-[0-9]{8}-[0-9]{6}\\.tar\\.gz$")
	if !pattern.MatchString(name) || filepath.Base(name) != name {
		http.NotFound(w, r)
		return
	}
	path := filepath.Join(a.backupDir, "profile-backups", name)
	if _, err := os.Stat(path); err != nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "application/gzip")
	w.Header().Set("Content-Disposition", "attachment; filename=\""+name+"\"")
	http.ServeFile(w, r, path)
}

func redactConfig(value any) any {
	switch item := value.(type) {
	case map[string]any:
		for key, child := range item {
			lower := strings.ToLower(key)
			if strings.Contains(lower, "secret") || strings.Contains(lower, "password") || strings.Contains(lower, "token") {
				item[key] = "[REDACTED]"
			} else {
				item[key] = redactConfig(child)
			}
		}
		return item
	case []any:
		for i, child := range item {
			item[i] = redactConfig(child)
		}
		return item
	default:
		return value
	}
}

func (a *App) configuration(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	result := map[string]any{}
	for _, name := range []string{"config.json", "profiles.json"} {
		raw, err := os.ReadFile(filepath.Join(a.configDir, name))
		if err != nil {
			errOut(w, http.StatusInternalServerError, "Не удалось прочитать конфигурацию")
			return
		}
		var value any
		if json.Unmarshal(raw, &value) != nil {
			errOut(w, http.StatusInternalServerError, "Конфигурация содержит некорректный JSON")
			return
		}
		result[name] = redactConfig(value)
	}
	jsonOut(w, result)
}

func (a *App) diagnostics(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 50*time.Second)
	defer cancel()
	output, err := a.command(ctx, "diagnostics")
	status := "ok"
	if err != nil {
		status = "warning"
	}
	jsonOut(w, map[string]string{"status": status, "output": output})
}

func (a *App) backups(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		full, _ := filepath.Glob(filepath.Join(a.backupDir, "tproxy-backup-*.tar.gz"))
		profiles, _ := filepath.Glob(filepath.Join(a.backupDir, "profile-backups", "*.tar.gz"))
		items := []map[string]any{}
		for _, group := range []struct{ files []string; kind string }{{full, "full"}, {profiles, "profile"}} {
			sort.Sort(sort.Reverse(sort.StringSlice(group.files)))
			for _, file := range group.files {
				if stat, err := os.Stat(file); err == nil {
					items = append(items, map[string]any{"name": filepath.Base(file), "size": stat.Size(), "modified": stat.ModTime(), "kind": group.kind})
				}
			}
		}
		jsonOut(w, items)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var body struct {
		Action string
		Name   string
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body) != nil {
		errOut(w, http.StatusBadRequest, "Некорректный запрос")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Minute)
	defer cancel()
	if body.Action == "create" {
		output, err := a.command(ctx, "backup")
		if err != nil {
			errOut(w, http.StatusInternalServerError, "Не удалось создать резервную копию")
			return
		}
		jsonOut(w, map[string]string{"status": "created", "message": output})
		return
	}
	if body.Action == "restore" {
		if !regexp.MustCompile("^tproxy-backup-[0-9]{8}-[0-9]{6}\\.tar\\.gz$").MatchString(body.Name) {
			errOut(w, http.StatusBadRequest, "Некорректное имя архива")
			return
		}
		files, _ := filepath.Glob(filepath.Join(a.backupDir, "tproxy-backup-*.tar.gz"))
		sort.Sort(sort.Reverse(sort.StringSlice(files)))
		index := 0
		for i, file := range files {
			if filepath.Base(file) == body.Name {
				index = i + 1
				break
			}
		}
		if index == 0 {
			errOut(w, http.StatusNotFound, "Архив не найден")
			return
		}
		if _, err := a.command(ctx, "restore", strconv.Itoa(index), "--yes"); err != nil {
			errOut(w, http.StatusInternalServerError, "Восстановление не выполнено")
			return
		}
		jsonOut(w, map[string]string{"status": "restored"})
		if flusher, ok := w.(http.Flusher); ok {
			flusher.Flush()
		}
		go func() {
			time.Sleep(2 * time.Second)
			restartCtx, stop := context.WithTimeout(context.Background(), 20*time.Second)
			defer stop()
			_ = exec.CommandContext(restartCtx, "systemctl", "restart", "tproxy-panel.service").Run()
		}()
		return
	}
	errOut(w, http.StatusBadRequest, "Неизвестная операция")
}

func (a *App) qr(w http.ResponseWriter, r *http.Request) {
	file, err := os.Open(a.qrFile)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer file.Close()
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = io.Copy(w, file)
}

func (a *App) routes() http.Handler {
	mux := http.NewServeMux()
	prefix := "/" + a.base
	mux.HandleFunc(prefix+"/login", a.login)
	mux.HandleFunc(prefix+"/logout", a.auth(a.logout))
	mux.HandleFunc(prefix+"/", a.home)
	mux.HandleFunc(prefix+"/api/profiles", a.auth(a.profiles))
	mux.HandleFunc(prefix+"/api/profiles/import", a.auth(a.profileImport))
	mux.HandleFunc(prefix+"/api/profiles/", a.auth(a.profileAction))
	mux.HandleFunc(prefix+"/api/profile-backups/", a.auth(a.profileBackupDownload))
	mux.HandleFunc(prefix+"/api/config", a.auth(a.configuration))
	mux.HandleFunc(prefix+"/api/diagnostics", a.auth(a.diagnostics))
	mux.HandleFunc(prefix+"/api/backups", a.auth(a.backups))
	mux.HandleFunc(prefix+"/api/qr", a.auth(a.qr))

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'")
		w.Header().Set("Cache-Control", "no-store")
		mux.ServeHTTP(w, r)
	})
}

func main() {
	a := &App{
		script:    env("PANEL_SCRIPT", "/opt/telegram-web-proxy/tgweb-install.sh"),
		backupDir: env("PANEL_BACKUP_DIR", "/opt/telegram-web-proxy/backups"),
		qrFile:    env("PANEL_QR", "/opt/telegram-web-proxy/qr/proxy-qr.png"),
		configDir: env("PANEL_CONFIG_DIR", "/opt/telegram-web-proxy/config/proxy"),
		failures:  map[string][]time.Time{},
		authSem:   make(chan struct{}, 2),
	}
	if err := a.init(); err != nil {
		log.Fatal(err)
	}
	if len(os.Args) > 1 && os.Args[1] == "-print-basepath" {
		fmt.Println(a.base)
		return
	}
	server := &http.Server{
		Addr: env("PANEL_LISTEN", "127.0.0.1:18765"), Handler: a.routes(),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second,
		WriteTimeout: 180 * time.Second, IdleTimeout: 60 * time.Second,
		MaxHeaderBytes: 1 << 20,
	}
	log.Printf("admin panel listening on %s", server.Addr)
	log.Fatal(server.ListenAndServe())
}
