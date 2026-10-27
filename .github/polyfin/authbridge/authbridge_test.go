package main

import (
 "context"
 "encoding/json"
 "errors"
 "net/http"
 "net/http/httptest"
 "strings"
 "testing"

 "github.com/moodiness/polyfin/internal/accounts"
)

type bridgeFakeAccounts struct {
 user accounts.User
 signed bool
}
func (f *bridgeFakeAccounts) User(_ context.Context, id accounts.ID) (accounts.User,error) {
 if f.user.ID != id { return accounts.User{}, errors.New("not found") }
 return f.user,nil
}
func (f *bridgeFakeAccounts) SignInDevice(_ context.Context,id accounts.ID,info accounts.DeviceInfo)(string,accounts.Device,error){
 if id!=f.user.ID || info.DeviceID!="browser-device-0001" { return "",accounts.Device{},errors.New("wrong identity or device") }
 f.signed=true
 return "fake-jellyfin-token",accounts.Device{},nil
}

func bridgeFixture(t *testing.T, status int, uid string) (*authentikBridge,*bridgeFakeAccounts,func()){
 t.Helper()
 userID,err:=accounts.ParseID("00000000-0000-4000-8000-000000000001")
 if err!=nil {t.Fatal(err)}
 store:=&bridgeFakeAccounts{user:accounts.User{ID:userID,Name:"viewer"}}
 outpost:=httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){
  if r.URL.Path!="/outpost.goauthentik.io/auth/nginx" {t.Errorf("unexpected outpost path %q",r.URL.Path)}
  if r.Header.Get("X-Original-URL")!="https://tv.smadja.dev/polyfin-sso/complete" {t.Error("not scoped to completion endpoint")}
  if r.Header.Get("Cookie")!="authentik=opaque-session" {t.Error("missing browser session")}
  if uid!="" { w.Header().Set("X-Authentik-Uid",uid) }
  w.WriteHeader(status)
 }))
 b:=&authentikBridge{store:store,serverID:"server-id",origin:"https://tv.smadja.dev",
  checkURL:outpost.URL+"/outpost.goauthentik.io/auth/nginx",
  startURL:"https://tv.smadja.dev/outpost.goauthentik.io/start?rd=https%3A%2F%2Ftv.smadja.dev%2Fpolyfin-sso%2Fcomplete",
  identities:map[string]accounts.ID{"known-uid":userID},client:outpost.Client()}
 return b,store,outpost.Close
}

func TestBridgeIdentityCannotBeSpoofedWithRequestHeaders(t *testing.T){
 b,accounts,closeOutpost:=bridgeFixture(t,http.StatusUnauthorized,"")
 defer closeOutpost()
 request:=httptest.NewRequest("POST","https://tv.smadja.dev/polyfin-sso/complete",strings.NewReader(`{"deviceId":"browser-device-0001"}`))
 request.Header.Set("Origin","https://tv.smadja.dev")
 request.Header.Set("Cookie","authentik=opaque-session")
 request.Header.Set("X-Authentik-Uid","known-uid") // a forged CLIENT header
 recorder:=httptest.NewRecorder()
 b.exchange(recorder,request)
 if recorder.Code!=http.StatusUnauthorized || accounts.signed {t.Fatalf("spoofed identity signed in: %d",recorder.Code)}
}

func TestBridgeIssuesNativeSessionOnlyForBoundIdentity(t *testing.T){
 b,accounts,closeOutpost:=bridgeFixture(t,http.StatusOK,"known-uid")
 defer closeOutpost()
 request:=httptest.NewRequest("POST","https://tv.smadja.dev/polyfin-sso/complete",strings.NewReader(`{"deviceId":"browser-device-0001"}`))
 request.Header.Set("Origin","https://tv.smadja.dev")
 request.Header.Set("Cookie","authentik=opaque-session")
 recorder:=httptest.NewRecorder()
 b.exchange(recorder,request)
 if recorder.Code!=http.StatusOK || !accounts.signed {t.Fatalf("valid identity refused: %d %s",recorder.Code,recorder.Body.String())}
 var payload struct{ AccessToken,UserID,ServerID string }
 if err:=json.Unmarshal(recorder.Body.Bytes(),&payload);err!=nil{t.Fatal(err)}
 if payload.AccessToken!="fake-jellyfin-token" || payload.ServerID!="server-id" || payload.UserID=="" {t.Fatal("wrong native session payload")}
 if recorder.Header().Get("Cache-Control")!="no-store, private" {t.Fatal("token could be cached")}
}

func TestBridgeRejectsCrossOriginEvenWithValidAuthentikCookie(t *testing.T){
 b,accounts,closeOutpost:=bridgeFixture(t,http.StatusOK,"known-uid")
 defer closeOutpost()
 request:=httptest.NewRequest("POST","https://tv.smadja.dev/polyfin-sso/complete",strings.NewReader(`{"deviceId":"browser-device-0001"}`))
 request.Header.Set("Origin","https://attacker.example")
 request.Header.Set("Cookie","authentik=opaque-session")
 recorder:=httptest.NewRecorder()
 b.exchange(recorder,request)
 if recorder.Code!=http.StatusForbidden || accounts.signed {t.Fatal("CSRF protection failed")}
}

func TestBridgeRejectsUnboundAuthentikAccount(t *testing.T){
 b,accounts,closeOutpost:=bridgeFixture(t,http.StatusOK,"unknown-uid")
 defer closeOutpost()
 request:=httptest.NewRequest("POST","https://tv.smadja.dev/polyfin-sso/complete",strings.NewReader(`{"deviceId":"browser-device-0001"}`))
 request.Header.Set("Origin","https://tv.smadja.dev")
 request.Header.Set("Cookie","authentik=opaque-session")
 recorder:=httptest.NewRecorder()
 b.exchange(recorder,request)
 if recorder.Code!=http.StatusUnauthorized || accounts.signed {t.Fatal("unbound account issued token")}
}

func TestBridgeConfigurationFailsClosed(t *testing.T){
 id,_:=accounts.ParseID("00000000-0000-4000-8000-000000000001")
 a:=&bridgeFakeAccounts{user:accounts.User{ID:id}}
 mapping:=`{"known-uid":"00000000-0000-4000-8000-000000000001"}`
 start:="https://tv.smadja.dev/outpost.goauthentik.io/start?rd=https%3A%2F%2Ftv.smadja.dev%2Fpolyfin-sso%2Fcomplete"
 for _, bad:=range []struct{origin,check,start,mapping string}{
  {"http://tv.smadja.dev","http://authentik.authentik.svc.cluster.local/outpost.goauthentik.io/auth/nginx",start,mapping},
  {"https://tv.smadja.dev","https://evil.example/outpost.goauthentik.io/auth/nginx",start,mapping},
  {"https://tv.smadja.dev","http://authentik.authentik.svc.cluster.local/outpost.goauthentik.io/auth/nginx",start,`{}`},
  {"https://tv.smadja.dev","http://authentik.authentik.svc.cluster.local/outpost.goauthentik.io/auth/nginx",
   "https://tv.smadja.dev/outpost.goauthentik.io/start?rd=https%3A%2F%2Ftv.smadja.dev%2Fpolyfin-sso%2Fcomplete.evil",mapping},
 }{
  if b,err:=newAuthentikBridge(a,"server",bad.origin,bad.check,bad.start,bad.mapping);err==nil {t.Fatalf("accepted unsafe config: %#v",b)}
 }
}

func TestBridgeIsFullyDisabledWithoutEnableFlag(t *testing.T){
 t.Setenv("POLYFIN_AUTHBRIDGE_ENABLED","")
 handler:=withAuthentikBridge(http.NotFoundHandler(),nil,"")
 request:=httptest.NewRequest("GET","https://tv.smadja.dev/polyfin-sso/status",nil)
 response:=httptest.NewRecorder()
 handler.ServeHTTP(response,request)
 if response.Code!=http.StatusNotFound {t.Fatalf("disabled bridge responded %d",response.Code)}
}
