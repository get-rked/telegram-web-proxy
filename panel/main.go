package main

import (
  "crypto/subtle"
  "database/sql"
  "embed"
  "encoding/json"
  "log"
  "net/http"
  "os"
  "path/filepath"
  "time"
  _ "modernc.org/sqlite"
)

//go:embed web/*
var assets embed.FS

type application struct { db *sql.DB; user, password, config, profiles string }
type profile struct { Name string `json:"name"`; Backend string `json:"backend"`; CarrierMode string `json:"carrier_mode"` }
type profileDocument struct { Profiles []profile `json:"profiles"` }

func env(k, fallback string) string { if v:=os.Getenv(k); v!="" { return v }; return fallback }
func main() {
  dbPath:=env("PANEL_DB", "/var/lib/tproxy-panel/panel.db")
  if err:=os.MkdirAll(filepath.Dir(dbPath),0700); err!=nil { log.Fatal(err) }
  db,err:=sql.Open("sqlite",dbPath); if err!=nil { log.Fatal(err) }; defer db.Close(); db.SetMaxOpenConns(1)
  if _,err=db.Exec("PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS audit_log (id INTEGER PRIMARY KEY, event TEXT NOT NULL, created_at TEXT NOT NULL);"); err!=nil { log.Fatal(err) }
  a:=&application{db:db,user:env("PANEL_USER","admin"),password:os.Getenv("PANEL_PASSWORD"),config:env("TPROXY_CONFIG","/etc/tproxy-server/config.json"),profiles:env("TPROXY_PROFILES","/etc/tproxy-server/profiles.json")}
  if len(a.password)<16 { log.Fatal("PANEL_PASSWORD must contain at least 16 characters") }
  mux:=http.NewServeMux(); mux.HandleFunc("/healthz",a.health); mux.HandleFunc("/admin/api/status",a.auth(a.status)); mux.HandleFunc("/admin/api/profiles",a.auth(a.listProfiles)); mux.HandleFunc("/admin/app.js",a.auth(a.javascript)); mux.HandleFunc("/admin/",a.auth(a.index)); mux.HandleFunc("/admin",a.auth(a.index))
  s:=&http.Server{Addr:env("PANEL_ADDR",":8088"),Handler:headers(mux),ReadHeaderTimeout:5*time.Second,ReadTimeout:10*time.Second,WriteTimeout:15*time.Second,IdleTimeout:60*time.Second}
  log.Printf("panel listening on %s",s.Addr); log.Fatal(s.ListenAndServe())
}
func headers(next http.Handler) http.Handler { return http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){ w.Header().Set("X-Content-Type-Options","nosniff"); w.Header().Set("X-Frame-Options","DENY"); w.Header().Set("Referrer-Policy","no-referrer"); w.Header().Set("Content-Security-Policy","default-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'"); next.ServeHTTP(w,r) }) }
func (a *application) auth(next http.HandlerFunc) http.HandlerFunc { return func(w http.ResponseWriter,r *http.Request){ u,p,ok:=r.BasicAuth(); if !ok || subtle.ConstantTimeCompare([]byte(u),[]byte(a.user))!=1 || subtle.ConstantTimeCompare([]byte(p),[]byte(a.password))!=1 { w.Header().Set("WWW-Authenticate", `Basic realm="Telegram Web Proxy"`); http.Error(w,"authentication required",http.StatusUnauthorized); return }; next(w,r) } }
func (a *application) health(w http.ResponseWriter,r *http.Request){ if a.db.Ping()!=nil { http.Error(w,"database unavailable",503); return }; w.WriteHeader(204) }
func (a *application) status(w http.ResponseWriter,r *http.Request){ if r.Method!="GET" { http.Error(w,"method not allowed",405); return }; var c map[string]any; b,e:=os.ReadFile(a.config); if e!=nil || json.Unmarshal(b,&c)!=nil { http.Error(w,"proxy config unavailable or invalid",503); return }; out:=map[string]any{"hostname":c["public_hostname"],"relay":c["listen"],"base_path":c["base_path"],"database":"connected"}; a.audit("status.view"); jsonResponse(w,out) }
func (a *application) listProfiles(w http.ResponseWriter,r *http.Request){ if r.Method!="GET" { http.Error(w,"method not allowed",405); return }; b,e:=os.ReadFile(a.profiles); if e!=nil { http.Error(w,"profiles unavailable",503); return }; var d profileDocument; if json.Unmarshal(b,&d)!=nil { http.Error(w,"profiles file invalid",503); return }; a.audit("profiles.view"); jsonResponse(w,map[string]any{"count":len(d.Profiles),"profiles":d.Profiles}) }
func (a *application) index(w http.ResponseWriter,r *http.Request){ b,e:=assets.ReadFile("web/index.html"); if e!=nil { http.Error(w,"UI unavailable",500); return }; w.Header().Set("Content-Type","text/html; charset=utf-8"); _,_=w.Write(b) }
func (a *application) javascript(w http.ResponseWriter,r *http.Request){ b,e:=assets.ReadFile("web/app.js"); if e!=nil { http.Error(w,"UI unavailable",500); return }; w.Header().Set("Content-Type","text/javascript; charset=utf-8"); _,_=w.Write(b) }
func (a *application) audit(event string){ if _,e:=a.db.Exec("INSERT INTO audit_log(event,created_at) VALUES(?,?)",event,time.Now().UTC().Format(time.RFC3339)); e!=nil { log.Printf("audit insert failed: %v",e) } }
func jsonResponse(w http.ResponseWriter,v any){ w.Header().Set("Content-Type","application/json; charset=utf-8"); _=json.NewEncoder(w).Encode(v) }
