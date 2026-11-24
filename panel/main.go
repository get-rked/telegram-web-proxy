package main

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"strconv"
	"sync"
	"time"

	"github.com/skip2/go-qrcode"
	_ "modernc.org/sqlite"
)

//go:embed web/*
var assets embed.FS

type authFailure struct { Count int; WindowStart time.Time; BlockedUntil time.Time }

type panelAuthConfig struct {
	BasePath     string `json:"base_path"`
	Username     string `json:"username"`
	PasswordSalt string `json:"password_salt"`
	PasswordHash string `json:"password_hash"`
}

type application struct {
	db       *sql.DB
	user     string
	basePath string
	passwordSalt []byte
	passwordHash []byte
	sessions map[string]time.Time
	sessionMu sync.Mutex
	config   string
	profiles string
	mtproxySecret string
	mu       sync.Mutex
	monitorClient *http.Client
	backupRoot string
	authLog *log.Logger
	trustProxy bool
	authMu sync.Mutex
	authFailures map[string]authFailure
	banDir string
}

type profile struct {
	Name        string `json:"name"`
	Secret      string `json:"secret"`
	Backend     string `json:"backend"`
	CarrierMode string `json:"carrier_mode"`
}

type profileDocument struct {
	Profiles []profile `json:"profiles"`
}

type profileView struct {
	Name        string `json:"name"`
	CarrierMode string `json:"carrier_mode"`
}

type profileRequest struct {
	Name string `json:"name"`
}

var profileNamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9 _.-]{0,63}$`)

func env(k, fallback string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return fallback
}

func main() {
	dbPath := env("PANEL_DB", "/var/lib/tproxy-panel/panel.db")
	if err := os.MkdirAll(filepath.Dir(dbPath), 0700); err != nil {
		log.Fatal(err)
	}
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	if _, err = db.Exec("PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS audit_log (id INTEGER PRIMARY KEY, event TEXT NOT NULL, created_at TEXT NOT NULL);"); err != nil {
		log.Fatal(err)
	}

	authConfigPath := env("PANEL_AUTH_FILE", "/etc/tproxy-config/panel-auth.json")
	authData, err := os.ReadFile(authConfigPath)
	if err != nil { log.Fatalf("cannot read panel auth config: %v", err) }
	var authConfig panelAuthConfig
	if err := json.Unmarshal(authData, &authConfig); err != nil { log.Fatalf("invalid panel auth config: %v", err) }
	if !regexp.MustCompile("^/panel-[A-Za-z0-9_-]{20,80}$").MatchString(authConfig.BasePath) || authConfig.Username == "" {
		log.Fatal("panel auth config has invalid base path or username")
	}
	passwordSalt, err := hex.DecodeString(authConfig.PasswordSalt)
	if err != nil || len(passwordSalt) != 32 { log.Fatal("panel auth config has invalid password salt") }
	passwordHash, err := hex.DecodeString(authConfig.PasswordHash)
	if err != nil || len(passwordHash) != 32 { log.Fatal("panel auth config has invalid password hash") }

	authLogPath := env("PANEL_AUTH_LOG", "/var/log/tproxy-panel/auth.log")
	if err := os.MkdirAll(filepath.Dir(authLogPath), 0750); err != nil { log.Fatal(err) }
	authFile, err := os.OpenFile(authLogPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil { log.Fatal(err) }
	defer authFile.Close()

	a := &application{
		db:       db,
		user:     authConfig.Username,
		basePath: authConfig.BasePath,
		passwordSalt: passwordSalt,
		passwordHash: passwordHash,
		sessions: make(map[string]time.Time),
		config:   env("TPROXY_CONFIG", "/etc/tproxy-server/config.json"),
		profiles: env("TPROXY_PROFILES", "/etc/tproxy-server/profiles.json"),
		mtproxySecret: env("MTPROXY_SECRET_FILE", "/run/secrets/mtproxy_secret"),
		monitorClient: &http.Client{Timeout: 3*time.Second},
		authLog: log.New(authFile, "", log.LstdFlags),
		banDir: env("PANEL_BANLIST_DIR", "/var/log/tproxy-panel/banlist"),
		trustProxy: env("PANEL_TRUST_PROXY", "false") == "true",
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", a.health)
	mux.HandleFunc("/api/session", a.sessionStatus)
	mux.HandleFunc("/api/login", a.login)
	mux.HandleFunc("/api/logout", a.auth(a.logout))
	mux.HandleFunc("/api/status", a.auth(a.status))
	mux.HandleFunc("/api/profiles", a.auth(a.profilesAPI))
	mux.HandleFunc("/api/profiles/", a.auth(a.profileItemAPI))
	mux.HandleFunc("/api/diagnostics", a.auth(a.diagnostics))
	mux.HandleFunc("/api/metrics", a.auth(a.metrics))
	mux.HandleFunc("/api/backups", a.auth(a.backupsAPI))
	mux.HandleFunc("/api/backups/", a.auth(a.backupItemAPI))
	mux.HandleFunc("/app.js", a.javascript)
	mux.HandleFunc("/", a.index)

	s := &http.Server{
		Addr:              env("PANEL_ADDR", ":8088"),
		Handler:           headers(mux),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	log.Printf("panel listening on %s", s.Addr)
	log.Fatal(s.ListenAndServe())
}

func headers(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
		next.ServeHTTP(w, r)
	})
}

func (a *application) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ip := a.clientIP(r)
		if a.isFail2banBanned(ip) || a.authIsBlocked(ip) {
			w.Header().Set("Retry-After", "900")
			http.Error(w, "too many authentication attempts", http.StatusTooManyRequests)
			return
		}
		cookie, err := r.Cookie("tproxy_session")
		if err != nil || !a.sessionValid(cookie.Value) {
			http.Error(w, "authentication required", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

func (a *application) sessionValid(token string) bool {
	a.sessionMu.Lock()
	defer a.sessionMu.Unlock()
	expires, ok := a.sessions[token]
	if !ok { return false }
	if time.Now().After(expires) { delete(a.sessions, token); return false }
	return true
}

func (a *application) sessionStatus(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodGet { http.Error(w, "method not allowed", 405); return }
	cookie, err := r.Cookie("tproxy_session")
	jsonResponse(w, map[string]bool{"authenticated": err == nil && a.sessionValid(cookie.Value)})
}

func (a *application) login(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost { http.Error(w, "method not allowed", 405); return }
	if !a.sameOriginMutation(w, r) { return }
	ip := a.clientIP(r)
	if a.isFail2banBanned(ip) || a.authIsBlocked(ip) {
		w.Header().Set("Retry-After", "900")
		http.Error(w, "too many authentication attempts", 429)
		return
	}
	var input struct { Username string `json:"username"`; Password string `json:"password"` }
	if err := decodeRequest(w, r, &input); err != nil { http.Error(w, "invalid credentials", 400); return }
	hashInput := append(append([]byte(nil), a.passwordSalt...), []byte(input.Password)...)
	hash := sha256.Sum256(hashInput)
	valid := subtle.ConstantTimeCompare([]byte(input.Username), []byte(a.user)) == 1 &&
		subtle.ConstantTimeCompare(hash[:], a.passwordHash) == 1
	if !valid {
		a.recordAuthFailure(ip)
		if a.authLog != nil { a.authLog.Printf("auth_failed ip=%s", ip) }
		http.Error(w, "Неверный логин или пароль", 401)
		return
	}
	a.clearAuthFailures(ip)
	tokenBytes := make([]byte, 32)
	if _, err := rand.Read(tokenBytes); err != nil { http.Error(w, "session creation failed", 500); return }
	token := hex.EncodeToString(tokenBytes)
	a.sessionMu.Lock()
	a.sessions[token] = time.Now().Add(12*time.Hour)
	a.sessionMu.Unlock()
	http.SetCookie(w, &http.Cookie{Name:"tproxy_session", Value:token, Path:a.basePath+"/", HttpOnly:true, Secure:true, SameSite:http.SameSiteStrictMode, MaxAge:12*60*60})
	jsonResponse(w, map[string]bool{"authenticated":true})
}

func (a *application) logout(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost { http.Error(w, "method not allowed", 405); return }
	if !a.sameOriginMutation(w, r) { return }
	cookie, err := r.Cookie("tproxy_session")
	if err == nil { a.sessionMu.Lock(); delete(a.sessions, cookie.Value); a.sessionMu.Unlock() }
	http.SetCookie(w, &http.Cookie{Name:"tproxy_session", Value:"", Path:a.basePath+"/", HttpOnly:true, Secure:true, SameSite:http.SameSiteStrictMode, MaxAge:-1})
	w.WriteHeader(http.StatusNoContent)
}

func (a *application) isFail2banBanned(ip string) bool {
	parsed := net.ParseIP(ip)
	if parsed == nil || a.banDir == "" { return false }
	jails, err := os.ReadDir(a.banDir)
	if err != nil { return false }
	for _, jail := range jails {
		if !jail.IsDir() { continue }
		info, statErr := os.Lstat(filepath.Join(a.banDir, jail.Name(), parsed.String()))
		if statErr == nil && info.Mode().IsRegular() && time.Since(info.ModTime()) < 7*24*time.Hour { return true }
	}
	return false
}

func (a *application) authIsBlocked(ip string) bool {
	a.authMu.Lock(); defer a.authMu.Unlock()
	state := a.authFailures[ip]
	return time.Now().Before(state.BlockedUntil)
}

func (a *application) clearAuthFailures(ip string) {
	a.authMu.Lock(); defer a.authMu.Unlock()
	delete(a.authFailures, ip)
}

func (a *application) recordAuthFailure(ip string) {
	a.authMu.Lock(); defer a.authMu.Unlock()
	if a.authFailures == nil { a.authFailures = make(map[string]authFailure) }
	now := time.Now()
	if len(a.authFailures) >= 10000 {
		for key, item := range a.authFailures {
			if (!item.BlockedUntil.IsZero() && now.After(item.BlockedUntil)) || (item.BlockedUntil.IsZero() && now.Sub(item.WindowStart) > 10*time.Minute) { delete(a.authFailures, key) }
		}
		if len(a.authFailures) >= 10000 { return }
	}
	state := a.authFailures[ip]
	if state.WindowStart.IsZero() || now.Sub(state.WindowStart) > 10*time.Minute { state = authFailure{WindowStart: now} }
	state.Count++
	if state.Count >= 10 { state.BlockedUntil = now.Add(15*time.Minute) }
	a.authFailures[ip] = state
}

func (a *application) clientIP(r *http.Request) string {
	if a.trustProxy {
		if candidate := net.ParseIP(strings.TrimSpace(r.Header.Get("X-Real-IP"))); candidate != nil { return candidate.String() }
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil { if ip := net.ParseIP(host); ip != nil { return ip.String() } }
	if ip := net.ParseIP(r.RemoteAddr); ip != nil { return ip.String() }
	return "unknown"
}

func (a *application) health(w http.ResponseWriter, r *http.Request) {
	if a.db.Ping() != nil {
		http.Error(w, "database unavailable", 503)
		return
	}
	w.WriteHeader(204)
}

func (a *application) status(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", 405)
		return
	}
	var c map[string]any
	b, e := os.ReadFile(a.config)
	if e != nil || json.Unmarshal(b, &c) != nil {
		http.Error(w, "proxy config unavailable or invalid", 503)
		return
	}
	out := map[string]any{"hostname": c["public_hostname"], "relay": c["listen"], "base_path": c["base_path"], "database": "connected"}
	a.audit("status.view")
	jsonResponse(w, out)
}

func (a *application) profilesAPI(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		a.listProfiles(w)
	case http.MethodPost:
		if !a.sameOriginMutation(w, r) {
			return
		}
		a.createProfile(w, r)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}


func (a *application) backupsAPI(w http.ResponseWriter,r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		items,err:=a.listBackups();if err!=nil{http.Error(w,"backup list unavailable",500);return};jsonResponse(w,map[string]any{"backups":items})
	case http.MethodPost:
		if !a.sameOriginMutation(w,r){return}
		item,err:=a.createBackup();if err!=nil{http.Error(w,"backup creation failed",500);return}
		a.audit("backup.create:"+item.ID);jsonResponse(w,item)
	default: http.Error(w,"method not allowed",405)
	}
}

func (a *application) backupItemAPI(w http.ResponseWriter,r *http.Request) {
	parts:=strings.Split(strings.TrimPrefix(r.URL.Path,"/admin/api/backups/"),"/")
	if len(parts)==1 && r.Method==http.MethodGet {
		if !backupIDPattern.MatchString(parts[0]){http.Error(w,"invalid backup id",400);return}
		file,err:=os.Open(filepath.Join(a.backupDir(),parts[0]+".tar.gz"));if err!=nil{http.NotFound(w,r);return};defer file.Close()
		w.Header().Set("Content-Type","application/gzip")
		w.Header().Set("Content-Disposition",fmt.Sprintf("attachment; filename=%q",parts[0]+".tar.gz"))
		_,_=io.Copy(w,file);return
	}
	if len(parts)==2 && parts[1]=="restore" && r.Method==http.MethodPost {
		if !a.sameOriginMutation(w,r){return}
		if err:=a.restoreBackup(parts[0]);err!=nil{http.Error(w,"backup validation or restore failed; check panel logs",400);return}
		a.audit("backup.restore:"+parts[0]);jsonResponse(w,map[string]string{"status":"restored","note":"Relay will validate the restored configuration; MTProxy will reload the synchronized secret list."});return
	}
	http.Error(w,"not found",404)
}

func (a *application) profileItemAPI(w http.ResponseWriter, r *http.Request) {
	path := strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/profiles/"), "/")
	parts := strings.Split(path, "/")
	if len(parts) < 1 || len(parts) > 2 || parts[0] == "" {
		http.Error(w, "invalid profile path", http.StatusBadRequest)
		return
	}
	name, err := url.PathUnescape(parts[0])
	if err != nil || strings.Contains(name, "/") {
		http.Error(w, "invalid profile name", http.StatusBadRequest)
		return
	}
	if len(parts) == 2 {
		switch parts[1] {
		case "config":
			if r.Method != http.MethodGet { http.Error(w, "method not allowed", 405); return }
			a.profileConfig(w, r, name)
			return
		case "qr":
			if r.Method != http.MethodGet { http.Error(w, "method not allowed", 405); return }
			a.profileQR(w, r, name)
			return
		default:
			http.NotFound(w, r)
			return
		}
	}
	if r.Method != http.MethodDelete {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !a.sameOriginMutation(w, r) { return }
	a.deleteProfile(w, r, name)
}

func (a *application) profileConfig(w http.ResponseWriter, r *http.Request, name string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	doc, err := a.readProfiles()
	if err != nil { http.Error(w, "profiles unavailable or invalid", http.StatusServiceUnavailable); return }
	index := findProfile(doc.Profiles, name)
	if index < 0 { http.NotFound(w, r); return }
	var cfg struct { PublicHostname string `json:"public_hostname"` }
	data, err := os.ReadFile(a.config)
	if err != nil || json.Unmarshal(data, &cfg) != nil || strings.TrimSpace(cfg.PublicHostname) == "" {
		http.Error(w, "public proxy hostname is not configured", http.StatusServiceUnavailable)
		return
	}
	values := url.Values{}
	values.Set("server", cfg.PublicHostname)
	values.Set("port", "443")
	values.Set("secret", doc.Profiles[index].Secret)
	link := "https://t.me/proxy?" + values.Encode()
	w.Header().Set("Cache-Control", "no-store")
	a.audit("profile.config.view:" + name)
	jsonResponse(w, map[string]any{
		"name": name, "hostname": cfg.PublicHostname, "port": 443,
		"carrier_mode": doc.Profiles[index].CarrierMode,
		"secret": doc.Profiles[index].Secret, "link": link,
	})
}

func (a *application) profileQR(w http.ResponseWriter, r *http.Request, name string) {
	a.mu.Lock()
	doc, err := a.readProfiles()
	if err != nil { a.mu.Unlock(); http.Error(w, "profiles unavailable or invalid", http.StatusServiceUnavailable); return }
	index := findProfile(doc.Profiles, name)
	if index < 0 { a.mu.Unlock(); http.NotFound(w, r); return }
	var cfg struct { PublicHostname string `json:"public_hostname"` }
	data, readErr := os.ReadFile(a.config)
	a.mu.Unlock()
	if readErr != nil || json.Unmarshal(data, &cfg) != nil || strings.TrimSpace(cfg.PublicHostname) == "" {
		http.Error(w, "public proxy hostname is not configured", http.StatusServiceUnavailable); return
	}
	values := url.Values{}
	values.Set("server", cfg.PublicHostname)
	values.Set("port", "443")
	values.Set("secret", doc.Profiles[index].Secret)
	qr, err := qrcode.New("https://t.me/proxy?"+values.Encode(), qrcode.Medium)
	if err != nil { http.Error(w, "could not create QR code", 500); return }
	png, err := qr.PNG(320)
	if err != nil { http.Error(w, "could not create QR code", 500); return }
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "image/png")
	_, _ = w.Write(png)
	a.audit("profile.qr.view:" + name)
}

func (a *application) sameOriginMutation(w http.ResponseWriter, r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" || r.Header.Get("X-TProxy-Request") != "1" {
		http.Error(w, "same-origin request required", http.StatusForbidden)
		return false
	}
	parsed, err := url.Parse(origin)
	if err != nil || (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.Host == "" || !strings.EqualFold(parsed.Host, r.Host) {
		http.Error(w, "origin mismatch", http.StatusForbidden)
		return false
	}
	return true
}

func (a *application) listProfiles(w http.ResponseWriter) {
	a.mu.Lock()
	defer a.mu.Unlock()
	doc, err := a.readProfiles()
	if err != nil {
		http.Error(w, "profiles unavailable or invalid", http.StatusServiceUnavailable)
		return
	}
	views := make([]profileView, 0, len(doc.Profiles))
	for _, p := range doc.Profiles {
		views = append(views, viewOf(p))
	}
	a.audit("profiles.view")
	jsonResponse(w, map[string]any{"count": len(views), "profiles": views})
}

func (a *application) createProfile(w http.ResponseWriter, r *http.Request) {
	var input profileRequest
	if err := decodeRequest(w, r, &input); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if err := validateProfileName(input.Name); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	a.mu.Lock()
	defer a.mu.Unlock()
	doc, err := a.readProfiles()
	if err != nil {
		http.Error(w, "profiles unavailable or invalid", http.StatusServiceUnavailable)
		return
	}
	if len(doc.Profiles) >= 32 {
		http.Error(w, "profile limit reached", http.StatusConflict)
		return
	}
	if hasName(doc.Profiles, input.Name) {
		http.Error(w, "profile name already exists", http.StatusConflict)
		return
	}
	secret, err := newSecret()
	if err != nil {
		http.Error(w, "could not generate profile secret", http.StatusInternalServerError)
		return
	}
	doc.Profiles = append(doc.Profiles, profile{Name: input.Name, Secret: secret, Backend: "127.0.0.1:2398", CarrierMode: "https"})
	if err := a.writeProfiles(doc); err != nil {
		http.Error(w, "could not save profiles", http.StatusInternalServerError)
		return
	}
	a.audit("profile.create:" + input.Name)
	// The generated client secret is returned only once, on creation.
	jsonResponse(w, map[string]any{"profile": viewOf(doc.Profiles[len(doc.Profiles)-1]), "secret": secret})
}

func (a *application) deleteProfile(w http.ResponseWriter, r *http.Request, name string) {
	if name == "default" {
		http.Error(w, "default profile cannot be deleted", http.StatusConflict)
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	doc, err := a.readProfiles()
	if err != nil {
		http.Error(w, "profiles unavailable or invalid", http.StatusServiceUnavailable)
		return
	}
	index := findProfile(doc.Profiles, name)
	if index < 0 {
		http.NotFound(w, r)
		return
	}
	doc.Profiles = append(doc.Profiles[:index], doc.Profiles[index+1:]...)
	if err := a.writeProfiles(doc); err != nil {
		http.Error(w, "could not save profiles", http.StatusInternalServerError)
		return
	}
	a.audit("profile.delete:" + name)
	w.WriteHeader(http.StatusNoContent)
}

func decodeRequest(w http.ResponseWriter, r *http.Request, dst any) error {
	r.Body = http.MaxBytesReader(w, r.Body, 16*1024)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(dst); err != nil {
		return fmt.Errorf("invalid JSON request: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return errors.New("request must contain one JSON object")
	}
	return nil
}

func validateProfileName(name string) error {
	if !profileNamePattern.MatchString(name) || strings.TrimSpace(name) != name {
		return errors.New("name must be 1-64 characters and use letters, digits, spaces, dot, underscore or hyphen")
	}
	return nil
}

func (a *application) readProfiles() (profileDocument, error) {
	var doc profileDocument
	data, err := os.ReadFile(a.profiles)
	if err != nil {
		return doc, err
	}
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&doc); err != nil {
		return doc, err
	}
	if len(doc.Profiles) == 0 || len(doc.Profiles) > 32 {
		return doc, errors.New("profile count out of range")
	}
	seenNames := make(map[string]bool)
	seenSecrets := make(map[string]bool)
	for _, p := range doc.Profiles {
		if err := validateProfileName(p.Name); err != nil { return doc, err }
		if p.Backend == "" { p.Backend = "127.0.0.1:2398" }
		if p.CarrierMode == "" { p.CarrierMode = "https" }
		host, port, backendErr := net.SplitHostPort(p.Backend)
		portNumber, portErr := strconv.Atoi(port)
		if backendErr != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() || portErr != nil || portNumber < 1 || portNumber > 65535 {
			return doc, errors.New("invalid internal backend")
		}
		switch p.CarrierMode { case "https", "https-lanes", "websocket", "websocket-lanes": default: return doc, errors.New("unsupported carrier_mode") }
		canonicalSecret := strings.TrimPrefix(strings.ToLower(p.Secret), "dd")
		secret, err := hex.DecodeString(canonicalSecret)
		if err != nil || len(secret) != 16 {
			return doc, errors.New("profile secret must be 16 bytes of hex")
		}
		p.Secret = "dd" + canonicalSecret
		if seenNames[p.Name] || seenSecrets[canonicalSecret] {
			return doc, errors.New("duplicate profile name or secret")
		}
		seenNames[p.Name] = true
		seenSecrets[canonicalSecret] = true
	}
	if !seenNames["default"] {
		return doc, errors.New("default profile is required")
	}
	return doc, nil
}

func (a *application) writeProfiles(doc profileDocument) error {
	data, err := json.MarshalIndent(doc, "", "  ")
	if err != nil { return err }
	data = append(data, '\n')
	if err := backupFile(a.profiles); err != nil { return err }
	if err := pruneFileBackups(a.profiles, 20); err != nil { return err }
	original, err := os.ReadFile(a.profiles)
	if err != nil { return err }
	if err := writeAtomicFile(a.profiles, data, 0600); err != nil { return err }
	if err := a.syncMTProxySecrets(doc); err != nil {
		if rollbackErr := writeAtomicFile(a.profiles, original, 0600); rollbackErr != nil {
			return fmt.Errorf("MTProxy secret sync failed (%v) and profiles rollback failed (%v)", err, rollbackErr)
		}
		return fmt.Errorf("MTProxy secret sync failed; profiles rolled back: %w", err)
	}
	return nil
}

func (a *application) syncMTProxySecrets(doc profileDocument) error {
	if a.mtproxySecret == "" { return nil }
	var values []string
	seen := make(map[string]bool, len(doc.Profiles))
	for _, item := range doc.Profiles {
		value := strings.TrimPrefix(strings.ToLower(item.Secret), "dd")
		decoded, err := hex.DecodeString(value)
		if err != nil || len(decoded) != 16 { return errors.New("invalid profile secret; refusing MTProxy sync") }
		if seen[value] { return errors.New("duplicate profile secret; refusing MTProxy sync") }
		seen[value] = true
		values = append(values, value)
	}
	return writeAtomicFile(a.mtproxySecret, []byte(strings.Join(values, "\n")+"\n"), 0600)
}

func writeAtomicFile(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".atomic-*.tmp")
	if err != nil { return err }
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err = tmp.Write(data); err != nil { _ = tmp.Close(); return err }
	if err = tmp.Sync(); err != nil { _ = tmp.Close(); return err }
	if err = tmp.Chmod(mode); err != nil { _ = tmp.Close(); return err }
	if err = tmp.Close(); err != nil { return err }
	if err = os.Rename(tmpName, path); err != nil { return err }
	if directory, openErr := os.Open(dir); openErr == nil { _ = directory.Sync(); _ = directory.Close() }
	return nil
}

func backupFile(path string) error {
	source, err := os.Open(path)
	if err != nil {
		return err
	}
	defer source.Close()
	info, err := source.Stat()
	if err != nil {
		return err
	}
	stamp := time.Now().UTC().Format("20060102T150405.000000000Z")
	target := path + ".backup-" + stamp
	destination, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, info.Mode().Perm())
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(destination, source)
	syncErr := destination.Sync()
	closeErr := destination.Close()
	if copyErr != nil {
		return copyErr
	}
	if syncErr != nil {
		return syncErr
	}
	return closeErr
}

func newSecret() (string, error) {
	value := make([]byte, 16)
	if _, err := rand.Read(value); err != nil { return "", err }
	return "dd" + hex.EncodeToString(value), nil
}

func viewOf(p profile) profileView {
	return profileView{Name: p.Name, CarrierMode: p.CarrierMode}
}

func hasName(profiles []profile, name string) bool { return findProfile(profiles, name) >= 0 }
func findProfile(profiles []profile, name string) int {
	for i := range profiles {
		if profiles[i].Name == name {
			return i
		}
	}
	return -1
}

func (a *application) index(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	b, e := assets.ReadFile("web/index.html")
	if e != nil {
		http.Error(w, "UI unavailable", 500)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write(b)
}

func (a *application) javascript(w http.ResponseWriter, r *http.Request) {
	b, e := assets.ReadFile("web/app.js")
	if e != nil {
		http.Error(w, "UI unavailable", 500)
		return
	}
	w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
	_, _ = w.Write(b)
}

func (a *application) audit(event string) {
	if _, e := a.db.Exec("INSERT INTO audit_log(event,created_at) VALUES(?,?)", event, time.Now().UTC().Format(time.RFC3339)); e != nil {
		log.Printf("audit insert failed: %v", e)
	}
}

func jsonResponse(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(v)
}
