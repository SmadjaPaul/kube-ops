// Copyright: local downstream integration of upstream Polyfin.
// Dormant unless POLYFIN_AUTHBRIDGE_ENABLED=true.
// Authentik is the identity authority; Polyfin remains the session authority.
package main

import (
 "context"
 "crypto/rand"
 "encoding/base64"
 "encoding/json"
 "errors"
 "fmt"
 "html"
 "io"
 "net/http"
 "net/url"
 "os"
 "strings"
 "time"

 "github.com/moodiness/polyfin/internal/accounts"
)

const bridgePrefix = "/polyfin-sso/complete"

type bridgeStore interface {
 User(context.Context, accounts.ID) (accounts.User, error)
 SignInDevice(context.Context, accounts.ID, accounts.DeviceInfo) (string, accounts.Device, error)
}

type authentikBridge struct {
 store bridgeStore
 serverID string
 origin string
 checkURL string
 startURL string
 identities map[string]accounts.ID
 client *http.Client
}

// withAuthentikBridge does NOT trust incoming X-authentik-* headers. It
// rechecks the browser's Authentik cookie against a fixed internal Outpost
// every time it mints a Jellyfin device token. No password, API key or
// privileged database mutation is used to fake an application session.
func withAuthentikBridge(next http.Handler, store *accounts.Store, serverID string) http.Handler {
 if os.Getenv("POLYFIN_AUTHBRIDGE_ENABLED") != "true" { return next }
 b, err := newAuthentikBridge(store, serverID,
  os.Getenv("POLYFIN_AUTHBRIDGE_ORIGIN"),
  os.Getenv("POLYFIN_AUTHBRIDGE_CHECK_URL"),
  os.Getenv("POLYFIN_AUTHBRIDGE_START_URL"),
  os.Getenv("POLYFIN_AUTHBRIDGE_IDENTITIES"))
 if err != nil { panic("Polyfin Authentik bridge configuration invalid: " + err.Error()) }
 mux := http.NewServeMux()
 mux.HandleFunc("GET /polyfin-sso/status", func(w http.ResponseWriter, r *http.Request) {
  bridgeHeaders(w)
  if r.Host != "tv.smadja.dev" { http.NotFound(w,r); return }
  w.WriteHeader(http.StatusNoContent)
 })
 mux.Handle("GET "+bridgePrefix, http.HandlerFunc(b.page))
 mux.Handle("POST "+bridgePrefix, http.HandlerFunc(b.exchange))
 mux.Handle("/", next)
 return mux
}

func newAuthentikBridge(store bridgeStore, serverID, origin, checkURL, startURL, mapping string) (*authentikBridge, error) {
 if store == nil || serverID == "" { return nil, errors.New("missing Polyfin account store/server ID") }
 originURL, err := url.Parse(origin)
 if err != nil || originURL.Scheme != "https" || originURL.Host != "tv.smadja.dev" || originURL.Path != "" || originURL.RawQuery != "" {
  return nil, errors.New("origin must be https://tv.smadja.dev")
 }
 internal, err := url.Parse(checkURL)
 if err != nil || internal.Hostname() == "" || internal.Path != "/outpost.goauthentik.io/auth/nginx" || internal.RawQuery != "" ||
  !(internal.Scheme == "https" && internal.Hostname() == "auth.smadja.dev" || internal.Scheme == "http" && strings.HasSuffix(internal.Hostname(), ".svc.cluster.local")) {
  return nil, errors.New("Outpost check URL must have fixed nginx-auth path and a trusted HTTPS or cluster-service host")
 }
 start, err := url.Parse(startURL)
 if err != nil || start.Scheme != "https" || start.Host != "tv.smadja.dev" ||
  start.Path != "/outpost.goauthentik.io/start" || start.Query().Get("rd") != origin+bridgePrefix {
  return nil, errors.New("start URL must use same-origin Authentik Outpost with a fixed return to Polyfin")
 }
 var raw map[string]string
 if json.Unmarshal([]byte(mapping), &raw) != nil || len(raw) == 0 { return nil, errors.New("explicit Authentik UID → Polyfin ID map required") }
 ids := make(map[string]accounts.ID, len(raw))
 for uid, value := range raw {
  if uid == "" || strings.TrimSpace(uid) != uid { return nil, errors.New("empty/invalid Authentik UID in map") }
  id, err := accounts.ParseID(value)
  if err != nil { return nil, errors.New("invalid Polyfin account ID in mapping") }
  ids[uid] = id
 }
 return &authentikBridge{store: store, serverID: serverID, origin: origin, checkURL: checkURL,
  startURL: startURL, identities: ids,
  client: &http.Client{Timeout: 4*time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }},
 }, nil
}

// identity comes ONLY from an Outpost response, never a client request header.
// Forwarding the cookie lets Outpost validate its own Authentik session.
func (b *authentikBridge) identity(r *http.Request) (accounts.User, error) {
 check, err := http.NewRequestWithContext(r.Context(), http.MethodGet, b.checkURL, nil)
 if err != nil { return accounts.User{}, err }
 check.Header.Set("Cookie", r.Header.Get("Cookie"))
 check.Header.Set("X-Original-URL", b.origin+bridgePrefix)
 check.Header.Set("X-Forwarded-Proto", "https")
 check.Header.Set("X-Forwarded-Host", "tv.smadja.dev")
 check.Header.Set("X-Forwarded-Method", "GET")
 resp, err := b.client.Do(check)
 if err != nil { return accounts.User{}, err }
 defer resp.Body.Close()
 io.Copy(io.Discard, io.LimitReader(resp.Body, 2048))
 if resp.StatusCode != http.StatusOK { return accounts.User{}, errors.New("no valid Authentik session") }
 uid := resp.Header.Get("X-Authentik-Uid")
 id, ok := b.identities[uid]
 if uid == "" || !ok { return accounts.User{}, errors.New("unbound Authentik identity") }
 user, err := b.store.User(r.Context(), id)
 if err != nil { return accounts.User{}, err }
 if user.Refused(time.Now()) || !user.AllowedAt(time.Now()) { return accounts.User{}, errors.New("Polyfin account not allowed") }
 return user, nil
}

func bridgeHeaders(w http.ResponseWriter) {
 w.Header().Set("Cache-Control", "no-store, private")
 w.Header().Set("Referrer-Policy", "no-referrer")
 w.Header().Set("X-Content-Type-Options", "nosniff")
 w.Header().Set("X-Frame-Options", "DENY")
}

func (b *authentikBridge) page(w http.ResponseWriter, r *http.Request) {
 bridgeHeaders(w)
 if r.Host != "tv.smadja.dev" { http.Error(w, "wrong host", http.StatusBadRequest); return }
 if _, err := b.identity(r); err != nil {
  // Only redirect on user-facing GET. Never follow Outpost-provided Location.
  http.Redirect(w, r, b.startURL, http.StatusSeeOther)
  return
 }
 // HTML contains no token: only a same-origin POST can mint a native session.
 nonceBytes := make([]byte, 18)
 if _, err := rand.Read(nonceBytes); err != nil { http.Error(w, "unavailable", http.StatusServiceUnavailable); return }
 nonce := base64.RawURLEncoding.EncodeToString(nonceBytes)
 w.Header().Set("Content-Type", "text/html; charset=utf-8")
 w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'nonce-"+nonce+"'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'")
 fmt.Fprint(w, `<!doctype html><html><head><meta charset="utf-8"><title>Polyfin</title></head><body>Connexion Polyfin…<script nonce="`,html.EscapeString(nonce),`">
 (async()=>{
  try {
   const key='_deviceId2';
   let id=localStorage.getItem(key);
   if(!id){id=crypto.randomUUID();localStorage.setItem(key,id)}
   const response=await fetch('/polyfin-sso/complete',{method:'POST',credentials:'same-origin',
    headers:{'Content-Type':'application/json'},body:JSON.stringify({deviceId:id})});
   if(!response.ok)throw Error('Connexion refusée: '+response.status);
   const data=await response.json();
   const publicInfo=await fetch('/System/Info/Public',{credentials:'same-origin'}).then(x=>x.json());
   if(!data.accessToken||!data.userId||!data.serverId||data.serverId!==publicInfo.Id)throw Error('Session invalide');
   const k='jellyfin_credentials';
   let saved={};try{saved=JSON.parse(localStorage.getItem(k)||'{}')}catch{}
   const other=Array.isArray(saved.Servers)?saved.Servers.filter(s=>s?.Id!==data.serverId):[];
   localStorage.setItem(k,JSON.stringify({...saved,Servers:[{Id:data.serverId,Name:publicInfo.ServerName||'Polyfin',
     ManualAddress:location.origin,LastConnectionMode:2,DateLastAccessed:Date.now(),
     UserId:data.userId,AccessToken:data.accessToken},...other]}));
   location.replace('/web/');
  } catch (e) { document.body.textContent='Connexion impossible. Retour au login Polyfin.'; }
 })();
 </script></body></html>`)
}

func (b *authentikBridge) exchange(w http.ResponseWriter, r *http.Request) {
 bridgeHeaders(w)
 if r.Host != "tv.smadja.dev" || r.Header.Get("Origin") != b.origin ||
  (r.Header.Get("Sec-Fetch-Site") != "" && r.Header.Get("Sec-Fetch-Site") != "same-origin") {
  http.Error(w, "forbidden", http.StatusForbidden); return
 }
 user, err := b.identity(r)
 if err != nil { http.Error(w, "unauthorized", http.StatusUnauthorized); return }
 var in struct { DeviceID string `json:"deviceId"` }
 if json.NewDecoder(http.MaxBytesReader(w,r.Body,1024)).Decode(&in) != nil ||
  len(in.DeviceID)<12 || len(in.DeviceID)>128 {
  http.Error(w, "invalid device", http.StatusBadRequest); return
 }
 token, _, err := b.store.SignInDevice(r.Context(), user.ID, accounts.DeviceInfo{
  DeviceID: in.DeviceID, DeviceName:"Authentik Browser", Client:"Jellyfin Web", ClientVersion:"12.4.0",
  RemoteAddress:r.RemoteAddr,
 })
 if err != nil { http.Error(w, "cannot sign in", http.StatusServiceUnavailable); return }
 w.Header().Set("Content-Type", "application/json")
 _ = json.NewEncoder(w).Encode(struct {
  AccessToken string `json:"accessToken"`
  UserID string `json:"userId"`
  ServerID string `json:"serverId"`
 }{token,user.ID.String(),b.serverID})
}
