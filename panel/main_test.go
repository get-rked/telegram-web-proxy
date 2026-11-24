package main

import (
 "database/sql"
 "net/http"
 "net/http/httptest"
 "os"
 "path/filepath"
 "strings"
 "testing"
)

func testApp(t *testing.T) *application {
 t.Helper()
 dir:=t.TempDir()
 db,err:=sql.Open("sqlite",filepath.Join(dir,"test.db")); if err!=nil { t.Fatal(err) }
 t.Cleanup(func(){ _=db.Close() })
 if _,err=db.Exec("CREATE TABLE audit_log (id INTEGER PRIMARY KEY, event TEXT NOT NULL, created_at TEXT NOT NULL)"); err!=nil { t.Fatal(err) }
 config:=filepath.Join(dir,"config.json")
 if err=os.WriteFile(config,[]byte(`{"public_hostname":"proxy.example.com","listen":"127.0.0.1:8080","admin_listen":"127.0.0.1:8081","token_key_file":"/private/token.key"}`),0600); err!=nil { t.Fatal(err) }
 profiles:=filepath.Join(dir,"profiles.json")
 if err=os.WriteFile(profiles,[]byte(`{"profiles":[{"name":"default","secret":"must-not-leak","backend":"127.0.0.1:2398","carrier_mode":"https"}]}`),0600); err!=nil { t.Fatal(err) }
 return &application{db:db,user:"admin",password:"a-long-test-password",config:config,profiles:profiles}
}

func TestStatusRequiresAuthentication(t *testing.T) {
 a:=testApp(t); mux:=http.NewServeMux(); mux.HandleFunc("/status",a.auth(a.status))
 response:=httptest.NewRecorder(); mux.ServeHTTP(response,httptest.NewRequest(http.MethodGet,"/status",nil))
 if response.Code!=http.StatusUnauthorized { t.Fatalf("status=%d, want 401",response.Code) }
}

func TestStatusDoesNotExposeTokenKeyPath(t *testing.T) {
 a:=testApp(t); request:=httptest.NewRequest(http.MethodGet,"/status",nil); request.SetBasicAuth("admin","a-long-test-password")
 response:=httptest.NewRecorder(); a.auth(a.status)(response,request)
 if response.Code!=http.StatusOK { t.Fatalf("status=%d body=%s",response.Code,response.Body.String()) }
 if strings.Contains(response.Body.String(),"token.key") { t.Fatal("status response leaked token key path") }
}

func TestProfilesDoNotExposeSecrets(t *testing.T) {
 a:=testApp(t); request:=httptest.NewRequest(http.MethodGet,"/profiles",nil); request.SetBasicAuth("admin","a-long-test-password")
 response:=httptest.NewRecorder(); a.auth(a.listProfiles)(response,request)
 if response.Code!=http.StatusOK { t.Fatalf("status=%d body=%s",response.Code,response.Body.String()) }
 if strings.Contains(response.Body.String(),"must-not-leak") || strings.Contains(response.Body.String(),"secret") { t.Fatalf("profile response leaked secret: %s",response.Body.String()) }
}

func TestProfilesRejectNonGet(t *testing.T) {
 a:=testApp(t); request:=httptest.NewRequest(http.MethodPost,"/profiles",nil); request.SetBasicAuth("admin","a-long-test-password")
 response:=httptest.NewRecorder(); a.auth(a.listProfiles)(response,request)
 if response.Code!=http.StatusMethodNotAllowed { t.Fatalf("status=%d, want 405",response.Code) }
}
