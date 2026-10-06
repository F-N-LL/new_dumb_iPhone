// wabridge: WhatsApp for phones too old for the app.
// Links to your WhatsApp as a companion device (like WhatsApp Web) and serves a tiny
// black-and-white chat page over HTTPS that iOS 9 Safari can use. No JavaScript.
//
//	wabridge -data DIR -link     show a QR code to link (WhatsApp > Linked devices)
//	wabridge -data DIR           serve on :8443
package main

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"database/sql"
	"encoding/hex"
	"encoding/pem"
	"flag"
	"fmt"
	"html/template"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/mdp/qrterminal/v3"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
	_ "modernc.org/sqlite"
)

var (
	dataDir = flag.String("data", "data", "where the WhatsApp session, messages, certificates and token live")
	link    = flag.Bool("link", false, "link this bridge to your WhatsApp with a QR code, then exit")
	addr    = flag.String("addr", ":8443", "HTTPS listen address")
	extraIP = flag.String("ip", "", "this machine's address on the home network (added to the certificate)")
	logout  = flag.Bool("logout", false, "unlink this bridge from WhatsApp, then exit")

	cli   *whatsmeow.Client
	db    *sql.DB
	token string

	namesMu sync.Mutex
	names   = map[string]string{} // chat JID -> display name (cache)
)

func main() {
	flag.Parse()
	ctx := context.Background()
	androidDNS()
	must(os.MkdirAll(*dataDir, 0o700))
	dsn := func(f string) string {
		return "file:" + filepath.Join(*dataDir, f) + "?_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)"
	}

	container, err := sqlstore.New(ctx, "sqlite", dsn("session.db"), waLog.Noop)
	must(err)
	device, err := container.GetFirstDevice(ctx)
	must(err)
	cli = whatsmeow.NewClient(device, waLog.Noop)

	db, err = sql.Open("sqlite", dsn("messages.db"))
	must(err)
	_, err = db.Exec(`CREATE TABLE IF NOT EXISTS msg (id TEXT PRIMARY KEY, chat TEXT, sender TEXT, push TEXT, me INT, ts INT, text TEXT);
		CREATE INDEX IF NOT EXISTS msg_chat ON msg(chat, ts);
		CREATE TABLE IF NOT EXISTS seen (chat TEXT PRIMARY KEY, ts INT)`)
	must(err)
	db.Exec(`ALTER TABLE msg ADD COLUMN st INT DEFAULT 0`) // 1 sent, 2 delivered, 3 read (own messages)

	if *logout {
		if cli.Store.ID != nil {
			must(cli.Connect())
			must(cli.Logout(ctx))
		}
		fmt.Println("Unlinked.")
		return
	}
	token = loadOrCreateToken()
	cert := loadOrCreateCert()
	if *link {
		doLink(ctx)
		return
	}
	if cli.Store.ID == nil {
		log.Fatal("not linked yet: run with -link first")
	}
	cli.AddEventHandler(onEvent)
	must(cli.Connect())

	mux := http.NewServeMux()
	mux.HandleFunc("/", auth(listPage))
	mux.HandleFunc("/c", auth(chatPage))
	mux.HandleFunc("/send", auth(sendHandler))
	mux.HandleFunc("/s", auth(searchPage))
	mux.HandleFunc("/pick", auth(pickPage))
	mux.HandleFunc("/thumb", auth(thumbHandler))
	mux.HandleFunc("/n", auth(pollHandler))
	srv := &http.Server{
		Addr:              *addr,
		Handler:           logRequests(mux),
		ReadHeaderTimeout: 10 * time.Second,
		TLSConfig:         &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12},
	}
	log.Printf("serving on https://%s%s", lanIPs()[0], *addr)
	log.Fatal(srv.ListenAndServeTLS("", ""))
}

func must(err error) {
	if err != nil {
		log.Fatal(err)
	}
}

// ---- WhatsApp ---------------------------------------------------------------

func doLink(ctx context.Context) {
	if cli.Store.ID != nil {
		fmt.Println("Already linked.")
		return
	}
	qr, err := cli.GetQRChannel(ctx)
	must(err)
	must(cli.Connect())
	fmt.Println("On your main phone: WhatsApp > Settings > Linked devices > Link a device, then scan:")
	for evt := range qr {
		switch evt.Event {
		case "code":
			qrterminal.GenerateHalfBlock(evt.Code, qrterminal.L, os.Stdout)
		case "success":
			fmt.Println("Linked. Waiting a moment for your recent chats to arrive...")
			cli.AddEventHandler(onEvent)
			time.Sleep(45 * time.Second)
			cli.Disconnect()
			return
		default:
			log.Fatalf("linking stopped: %s", evt.Event)
		}
	}
}

func onEvent(evt any) {
	switch e := evt.(type) {
	case *events.Message:
		store(e)
	case *events.Receipt:
		onReceipt(e)
	case *events.HistorySync:
		for _, conv := range e.Data.GetConversations() {
			chat, err := types.ParseJID(conv.GetID())
			if err != nil {
				continue
			}
			var stamps []int64
			for _, hm := range conv.GetMessages() {
				if m, err := cli.ParseWebMessage(chat, hm.GetMessage()); err == nil {
					store(m)
					stamps = append(stamps, m.Info.Timestamp.Unix())
				}
			}
			// History is read up to WhatsApp's own unread count for the chat.
			sort.Slice(stamps, func(i, j int) bool { return stamps[i] < stamps[j] })
			if k := len(stamps) - 1 - int(conv.GetUnreadCount()); k >= 0 {
				db.Exec(`INSERT INTO seen VALUES (?, ?) ON CONFLICT(chat) DO UPDATE SET ts=MAX(ts, excluded.ts)`,
					chat.ToNonAD().String(), stamps[k])
			}
		}
	}
}

func store(m *events.Message) {
	text := describe(m.Message)
	if text == "" || m.Info.Chat.Server == types.BroadcastServer {
		return // reactions, receipts, status updates...
	}
	_, err := db.Exec(`INSERT OR IGNORE INTO msg (id, chat, sender, push, me, ts, text) VALUES (?,?,?,?,?,?,?)`,
		m.Info.ID, m.Info.Chat.ToNonAD().String(), m.Info.Sender.ToNonAD().String(), m.Info.PushName,
		m.Info.IsFromMe, m.Info.Timestamp.Unix(), text)
	if err != nil {
		log.Print(err)
	}
}

// onReceipt: ticks on your messages, and chats you read on your main phone stop showing unread.
func onReceipt(e *events.Receipt) {
	chat := e.Chat.ToNonAD().String()
	read := e.Type == types.ReceiptTypeRead || e.Type == types.ReceiptTypeReadSelf || e.Type == types.ReceiptTypePlayed
	if e.IsFromMe {
		if read {
			db.Exec(`INSERT INTO seen VALUES (?, ?) ON CONFLICT(chat) DO UPDATE SET ts=MAX(ts, excluded.ts)`, chat, e.Timestamp.Unix())
		}
		return
	}
	st := 2
	if read {
		st = 3
	} else if e.Type != types.ReceiptTypeDelivered {
		return
	}
	for _, id := range e.MessageIDs {
		db.Exec(`UPDATE msg SET st=MAX(COALESCE(st,0), ?) WHERE id=? AND me=1`, st, id)
	}
}

func describe(m *waE2E.Message) string {
	switch {
	case m == nil:
		return ""
	case m.GetConversation() != "":
		return m.GetConversation()
	case m.GetExtendedTextMessage() != nil:
		return m.GetExtendedTextMessage().GetText()
	case m.GetImageMessage() != nil:
		return strings.TrimSpace("[photo] " + m.GetImageMessage().GetCaption())
	case m.GetVideoMessage() != nil:
		return strings.TrimSpace("[video] " + m.GetVideoMessage().GetCaption())
	case m.GetAudioMessage() != nil:
		return "[voice message]"
	case m.GetDocumentMessage() != nil:
		return "[file] " + m.GetDocumentMessage().GetFileName()
	case m.GetStickerMessage() != nil:
		return "[sticker]"
	case m.GetLocationMessage() != nil:
		return "[location]"
	case m.GetContactMessage() != nil:
		return "[contact] " + m.GetContactMessage().GetDisplayName()
	case m.GetEphemeralMessage() != nil:
		return describe(m.GetEphemeralMessage().GetMessage())
	case m.GetViewOnceMessage() != nil:
		return "[view once]"
	}
	return ""
}

func chatName(ctx context.Context, jidStr string) string {
	namesMu.Lock()
	n, ok := names[jidStr]
	namesMu.Unlock()
	if ok {
		return n
	}
	jid, _ := types.ParseJID(jidStr)
	n = jid.User
	if jid.Server == types.GroupServer {
		if gi, err := cli.GetGroupInfo(ctx, jid); err == nil && gi.Name != "" {
			n = gi.Name
		}
	} else if c, err := cli.Store.Contacts.GetContact(ctx, jid); err == nil {
		for _, s := range []string{c.FullName, c.FirstName, c.PushName, c.BusinessName} {
			if s != "" {
				n = s
				break
			}
		}
		if n == jid.User {
			n = "+" + jid.User
		}
	}
	namesMu.Lock()
	names[jidStr] = n
	namesMu.Unlock()
	return n
}

// ---- web --------------------------------------------------------------------

// auth: the first visit carries ?k=<token> (from the LightHome row); it becomes a cookie.
func auth(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// Home network only, even if this computer has no firewall and joins a public Wi-Fi.
		if host, _, err := net.SplitHostPort(r.RemoteAddr); err != nil || !isLocal(net.ParseIP(host)) {
			http.Error(w, "Forbidden", http.StatusForbidden)
			return
		}
		if k := r.URL.Query().Get("k"); k != "" && eq(k, token) {
			http.SetCookie(w, &http.Cookie{Name: "k", Value: token, Path: "/", HttpOnly: true, Secure: true,
				Expires: time.Now().AddDate(5, 0, 0)})
			q := r.URL.Query()
			q.Del("k")
			r.URL.RawQuery = q.Encode()
			http.Redirect(w, r, r.URL.String(), http.StatusSeeOther)
			return
		}
		if c, err := r.Cookie("k"); err != nil || !eq(c.Value, token) {
			http.Error(w, "Open WhatsApp from the home screen.", http.StatusUnauthorized)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		h(w, r)
	}
}

type statusWriter struct {
	http.ResponseWriter
	code int
}

func (s *statusWriter) WriteHeader(c int) { s.code = c; s.ResponseWriter.WriteHeader(c) }

func logRequests(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start, sw := time.Now(), &statusWriter{w, 200}
		h.ServeHTTP(sw, r)
		if r.URL.Path != "/n" { // the 6-second polls would drown everything else
			log.Printf("%s %s %d %dms %dKB", r.Method, r.URL.Path, sw.code, time.Since(start).Milliseconds(), r.ContentLength>>10)
		}
	})
}

func isLocal(ip net.IP) bool { return ip != nil && (ip.IsPrivate() || ip.IsLoopback()) }

func eq(a, b string) bool { return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1 }

// csrf: forms carry a value only a page served by us knows (cookies alone are sent cross-site).
func csrf() string {
	m := hmac.New(sha256.New, []byte(token))
	m.Write([]byte("send"))
	return hex.EncodeToString(m.Sum(nil))
}

func chatURL(chat string) string { return "/c?j=" + url.QueryEscape(chat) }

type chatRow struct {
	URL, Name, Text, When string
	Me, Media             bool
	Unread                int
}

func listPage(w http.ResponseWriter, r *http.Request) {
	rows, err := db.Query(`SELECT m.chat, m.text, MAX(m.ts), m.me,
		(SELECT COUNT(*) FROM msg u WHERE u.chat=m.chat AND u.me=0 AND u.ts > COALESCE(s.ts,0))
		FROM msg m LEFT JOIN seen s ON s.chat=m.chat GROUP BY m.chat ORDER BY MAX(m.ts) DESC LIMIT 50`)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	defer rows.Close()
	var list []chatRow
	var newest int64
	for rows.Next() {
		var c chatRow
		var chat string
		var ts int64
		rows.Scan(&chat, &c.Text, &ts, &c.Me, &c.Unread)
		c.URL, c.Name, c.When = chatURL(chat), chatName(r.Context(), chat), when(ts)
		c.Media = strings.HasPrefix(c.Text, "[")
		c.Text = clip(c.Text, 70)
		newest = max(newest, ts)
		list = append(list, c)
	}
	total := 0
	for _, c := range list {
		total += c.Unread
	}
	render(w, listTpl, map[string]any{"Rows": list, "Unread": total, "Since": newest})
}

type line struct {
	Day, From, Text, When, Tick string
	Me, Media, Read             bool
}

func chatPage(w http.ResponseWriter, r *http.Request) {
	chat := r.URL.Query().Get("j")
	jid, err := types.ParseJID(chat)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	before, _ := strconv.ParseInt(r.URL.Query().Get("before"), 10, 64)
	if before == 0 {
		before = 1 << 62
	}
	rows, err := db.Query(`SELECT * FROM (SELECT id, sender, push, me, ts, text, COALESCE(st,0) FROM msg
		WHERE chat=? AND ts<? ORDER BY ts DESC LIMIT 60) ORDER BY ts`, chat, before)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	defer rows.Close()
	var lines []line
	var first, last int64
	var unread []types.MessageID
	var lastSender types.JID
	prevDay := ""
	for rows.Next() {
		var id, sender, push, text string
		var me bool
		var ts int64
		var st int
		rows.Scan(&id, &sender, &push, &me, &ts, &text, &st)
		l := line{Text: text, When: time.Unix(ts, 0).Format("15:04"), Me: me, Media: strings.HasPrefix(text, "[")}
		if d := day(ts); d != prevDay {
			l.Day, prevDay = d, d
		}
		if !me && jid.Server == types.GroupServer {
			if l.From = push; l.From == "" {
				l.From = chatName(r.Context(), sender)
			}
		}
		if me {
			l.Tick, l.Read = [...]string{"", "✓", "✓✓", "✓✓"}[min(st, 3)], st == 3
		} else {
			unread = append(unread, id)
			lastSender, _ = types.ParseJID(sender)
		}
		if first == 0 {
			first = ts
		}
		last = ts
		lines = append(lines, l)
	}
	if r.URL.Query().Get("before") == "" { // only the live view marks things read
		db.Exec(`INSERT INTO seen VALUES (?, ?) ON CONFLICT(chat) DO UPDATE SET ts=MAX(ts, excluded.ts)`, chat, last)
		if len(unread) > 0 { // blue ticks for what you just saw
			go cli.MarkRead(context.Background(), unread[max(0, len(unread)-20):], time.Now(), jid, lastSender)
		}
	}
	render(w, chatTpl, map[string]any{
		"Name": chatName(r.Context(), chat), "Chat": chat, "URL": chatURL(chat), "Lines": lines,
		"CSRF": csrf(), "Earlier": first, "HasEarlier": len(lines) == 60, "Since": last,
		"Older": r.URL.Query().Get("before") != "",
	})
}

// pollHandler: "1" if something newer than ts arrived (in one chat, or anywhere). The pages poll this.
func pollHandler(w http.ResponseWriter, r *http.Request) {
	since, _ := strconv.ParseInt(r.URL.Query().Get("ts"), 10, 64)
	var n int
	if chat := r.URL.Query().Get("j"); chat != "" {
		db.QueryRow(`SELECT COUNT(*) FROM msg WHERE chat=? AND ts>?`, chat, since).Scan(&n)
	} else {
		db.QueryRow(`SELECT COUNT(*) FROM msg WHERE ts>?`, since).Scan(&n)
	}
	fmt.Fprint(w, min(n, 1))
}

// sendHandler: the chat's one form. A picked photo is sent with the typed text as its caption;
// otherwise the text goes out as a normal message.
func sendHandler(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 25<<20)
	if r.Method != http.MethodPost {
		http.Error(w, "bad request", 400)
		return
	}
	if err := r.ParseMultipartForm(8 << 20); err != nil && err != http.ErrNotMultipart {
		fail(w, r, 413, "Upload failed or too big", err)
		return
	}
	if !eq(r.FormValue("t"), csrf()) {
		fail(w, r, 400, "Bad request", fmt.Errorf("csrf"))
		return
	}
	chat := r.FormValue("j")
	jid, err := types.ParseJID(chat)
	if err != nil {
		fail(w, r, 400, "Bad chat", err)
		return
	}
	text := strings.TrimSpace(r.FormValue("m"))
	var msg *waE2E.Message
	stored := text
	if name := r.FormValue("lib"); name != "" {
		raw, err := fetchPhoto(r, name)
		if err != nil || len(raw) == 0 {
			fail(w, r, 502, "Couldn't read that photo from the phone", err)
			return
		}
		full, thumb, pw, ph, err := preparePhoto(raw)
		if err != nil {
			fail(w, r, 415, "That file isn't a photo this bridge can read (JPEG, PNG or GIF)", err)
			return
		}
		up, err := cli.Upload(r.Context(), full, whatsmeow.MediaImage)
		if err != nil {
			fail(w, r, 502, "Not sent", err)
			return
		}
		img := &waE2E.ImageMessage{
			Mimetype: proto.String("image/jpeg"), URL: proto.String(up.URL), DirectPath: proto.String(up.DirectPath),
			MediaKey: up.MediaKey, FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256,
			FileLength: proto.Uint64(up.FileLength), Width: proto.Uint32(uint32(pw)), Height: proto.Uint32(uint32(ph)),
			JPEGThumbnail: thumb,
		}
		if text != "" {
			img.Caption = proto.String(text)
		}
		msg, stored = &waE2E.Message{ImageMessage: img}, strings.TrimSpace("[photo] "+text)
		log.Printf("photo: %d KB in, %dx%d %d KB out", len(raw)>>10, pw, ph, len(full)>>10)
	} else if text != "" && len(text) <= 4000 {
		msg = &waE2E.Message{Conversation: proto.String(text)}
	} else {
		http.Redirect(w, r, chatURL(chat)+"#end", http.StatusSeeOther)
		return
	}
	resp, err := cli.SendMessage(r.Context(), jid, msg)
	if err != nil {
		fail(w, r, 502, "Not sent", err)
		return
	}
	db.Exec(`INSERT OR IGNORE INTO msg (id, chat, sender, push, me, ts, text, st) VALUES (?,?,?,?,?,?,?,1)`,
		resp.ID, chat, "", "", true, resp.Timestamp.Unix(), stored)
	http.Redirect(w, r, chatURL(chat)+"#end", http.StatusSeeOther)
}

// fail: log the real error for ./whatsapp.sh users (journalctl), show a short one on the phone.
func fail(w http.ResponseWriter, r *http.Request, code int, msg string, err error) {
	log.Printf("%s %s: %d %s: %v", r.Method, r.URL.Path, code, msg, err)
	http.Error(w, msg+". Go back and try again.", code)
}

type hit struct{ URL, Name, Text, When string }

// searchPage: people and groups by name, messages by text; a full number opens a new chat.
func searchPage(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	lq := strings.ToLower(q)
	var people, msgs []hit
	var number string
	if q != "" {
		digits := strings.Map(func(c rune) rune {
			if c >= '0' && c <= '9' {
				return c
			}
			return -1
		}, q)
		isNumber := strings.Trim(q, "0123456789 +-().") == ""
		if isNumber && len(digits) >= 8 && len(digits) <= 15 {
			number = chatURL(digits + "@" + types.DefaultUserServer)
		}
		seen := map[string]bool{}
		add := func(jid, name string) {
			if !seen[jid] && len(people) < 25 && (strings.Contains(strings.ToLower(name), lq) || (digits != "" && strings.Contains(jid, digits))) {
				seen[jid] = true
				people = append(people, hit{URL: chatURL(jid), Name: name})
			}
		}
		// chats you already have first (groups included), then the rest of your contacts
		if rows, err := db.Query(`SELECT chat FROM msg GROUP BY chat ORDER BY MAX(ts) DESC`); err == nil {
			for rows.Next() {
				var c string
				rows.Scan(&c)
				add(c, chatName(r.Context(), c))
			}
			rows.Close()
		}
		if all, err := cli.Store.Contacts.GetAllContacts(r.Context()); err == nil {
			for jid, c := range all {
				if jid.Server != types.DefaultUserServer {
					continue
				}
				for _, n := range []string{c.FullName, c.FirstName, c.PushName, c.BusinessName} {
					if n != "" {
						add(jid.ToNonAD().String(), n)
						break
					}
				}
			}
		}
		esc := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(q)
		if rows, err := db.Query(`SELECT chat, ts, text FROM msg WHERE text LIKE ? ESCAPE '\' ORDER BY ts DESC LIMIT 30`, "%"+esc+"%"); err == nil {
			for rows.Next() {
				var c, text string
				var ts int64
				rows.Scan(&c, &ts, &text)
				// open the chat ending at that message, so it's right above the fold
				msgs = append(msgs, hit{URL: chatURL(c) + "&before=" + strconv.FormatInt(ts+1, 10), Name: chatName(r.Context(), c),
					Text: snippet(text, q), When: when(ts)})
			}
			rows.Close()
		}
	}
	render(w, searchTpl, map[string]any{"Q": q, "People": people, "Msgs": msgs, "Number": number})
}

// snippet: the part of a long message around the match.
func snippet(text, q string) string {
	r := []rune(strings.Join(strings.Fields(text), " "))
	i := strings.Index(strings.ToLower(string(r)), strings.ToLower(q))
	if i < 0 || len(r) <= 70 {
		return clip(string(r), 70)
	}
	start := max(0, len([]rune(string(r)[:i]))-25)
	return "…" + clip(string(r[start:]), 68)
}

func clip(s string, n int) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > n {
		return string(r[:n]) + "…"
	}
	return s
}

func day(ts int64) string {
	t, now := time.Unix(ts, 0), time.Now()
	y1, m1, d1 := t.Date()
	y2, m2, d2 := now.Date()
	days := int(time.Date(y2, m2, d2, 0, 0, 0, 0, time.Local).Sub(time.Date(y1, m1, d1, 0, 0, 0, 0, time.Local)).Hours() / 24)
	switch {
	case days == 0:
		return "Today"
	case days == 1:
		return "Yesterday"
	case days < 7:
		return t.Format("Monday")
	case y1 == y2:
		return t.Format("2 January")
	}
	return t.Format("2 January 2006")
}

func when(ts int64) string {
	if d := day(ts); d != "Today" {
		if len(d) > 9 {
			return time.Unix(ts, 0).Format("2 Jan")
		}
		return d[:min(3, len(d))]
	}
	return time.Unix(ts, 0).Format("15:04")
}

func render(w http.ResponseWriter, t *template.Template, data any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := t.Execute(w, data); err != nil {
		log.Print(err)
	}
}

// Same look as LightHome: black, white text, quiet grey for everything secondary.
// iOS 9 Safari: no flexbox gaps, no CSS variables in some paths, ES5 only. Keep it plain.
const head = `<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="format-detection" content="telephone=no">
<meta name="theme-color" content="#000">
<style>
html{-webkit-tap-highlight-color:rgba(0,0,0,0);-webkit-text-size-adjust:100%}
body{margin:0;background:#000;color:#f2f2f2;font:17px/1.4 -apple-system,"Helvetica Neue",sans-serif}
a{color:inherit;text-decoration:none;touch-action:manipulation;-webkit-user-select:none;-webkit-touch-callout:none}
.bar{position:-webkit-sticky;position:sticky;top:0;z-index:2;background:#000;padding:14px 18px 10px;border-bottom:1px solid #1a1a1a;overflow:hidden}
.bar h1{margin:0;font-size:28px;font-weight:200;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.bar .l{float:left;color:#8c8c8c;padding:8px 14px 8px 0;margin:-8px 0}
.bar .r{float:right;color:#8c8c8c;padding:8px 0 8px 14px;margin:-8px 0}
.bar .r,.bar .l{font-size:17px;line-height:44px;margin-top:-6px}
.bar.chat h1{font-size:22px;font-weight:300;line-height:30px}
a:active,button:active{opacity:.5}
.row{display:block;padding:12px 18px 13px;border-bottom:1px solid #141414;min-height:44px}
.row .t{float:right;color:#6e6e6e;font-size:14px;margin-top:3px}
.row b{display:block;font-weight:400;font-size:20px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-right:56px}
.row p{margin:2px 0 0;color:#8c8c8c;font-size:15px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.row .n{float:right;clear:right;background:#f2f2f2;color:#000;font-size:13px;font-weight:600;border-radius:10px;min-width:20px;text-align:center;padding:0 6px;margin-top:4px}
.row.unread b{font-weight:600}.row.unread p{color:#d0d0d0}
.dim{color:#6e6e6e}
.day{text-align:center;color:#6e6e6e;font-size:13px;padding:16px 0 6px;-webkit-user-select:none}
.m{padding:3px 14px;overflow:hidden}
.m div{float:left;max-width:80%;background:#121212;border-radius:16px;padding:7px 12px 6px;white-space:pre-wrap;word-wrap:break-word}
.m.me div{float:right;background:#262626}
.m s{display:block;text-decoration:none;color:#8c8c8c;font-size:13px}
.m i{font-style:normal;color:#6e6e6e;font-size:12px;margin-left:8px;white-space:nowrap}
.m i b{font-weight:400;letter-spacing:-2px;margin-left:2px}.m i b.read{color:#f2f2f2}
.more{display:block;text-align:center;color:#8c8c8c;padding:14px}
form{padding:10px 14px 18px;border-top:1px solid #1a1a1a;margin-top:10px;overflow:hidden}
textarea,input{width:100%;box-sizing:border-box;background:#0d0d0d;color:#f2f2f2;border:1px solid #2a2a2a;border-radius:18px;font:17px/1.35 -apple-system,sans-serif;padding:9px 14px;-webkit-appearance:none;resize:none;outline:0}
textarea{height:42px;max-height:140px}
button{margin-top:8px;float:right;padding:10px 22px;background:#f2f2f2;color:#000;border:0;border-radius:20px;font:600 17px -apple-system,sans-serif;-webkit-appearance:none;touch-action:manipulation;-webkit-user-select:none}
button[disabled]{opacity:.4}
.empty{padding:40px 18px;color:#8c8c8c;text-align:center}
.find{padding:8px 14px 10px;border:0;margin:0}
.find input{height:38px;padding:6px 14px;font-size:16px}
.cam{position:relative;float:left;overflow:hidden;margin-top:8px;padding:10px 16px 10px 2px;color:#8c8c8c;font-size:17px;-webkit-user-select:none}
.grid{padding:4px 10px 30px;overflow:hidden}
.grid button{float:left;width:33.33%;margin:0;padding:3px;background:none;border-radius:0}
.grid img{display:block;width:100%;height:96px;object-fit:cover;border-radius:4px;background:#111}
.cap{padding:8px 14px 4px}
.sec{color:#6e6e6e;font-size:13px;padding:16px 18px 4px;text-transform:uppercase;letter-spacing:.05em}
</style>`

// poll: reload when the server says something new arrived, unless you're in the middle of typing.
const poll = `<script>
(function(){var u='{{.PollURL}}',t=setInterval(function(){
var x=new XMLHttpRequest();x.open('GET',u,true);x.onload=function(){
var a=document.activeElement,typing=window.busy||a&&a.tagName=='TEXTAREA'||(document.getElementById('m')||{}).value;
if(x.responseText=='1'&&!typing){clearInterval(t);location.replace('{{.ReloadURL}}');}};x.send();},6000);})();
</script>`

var listTpl = template.Must(template.New("l").Funcs(template.FuncMap{"poll": func(since int64) map[string]any {
	return map[string]any{"PollURL": fmt.Sprintf("/n?ts=%d", since), "ReloadURL": "/"}
}}).Parse(head + `<title>WhatsApp</title></head><body>
<div class="bar"><h1>WhatsApp{{if .Unread}} <span class="dim">{{.Unread}}</span>{{end}}</h1></div>
<form class="find" method="get" action="/s"><input type="search" name="q" placeholder="Search people, groups, messages" autocorrect="off" autocapitalize="off"></form>
{{range .Rows}}<a class="row{{if .Unread}} unread{{end}}" href="{{.URL}}#end"><span class="t">{{.When}}</span>{{if .Unread}}<span class="n">{{.Unread}}</span>{{end}}<b>{{.Name}}</b><p{{if .Media}} class="dim"{{end}}>{{if .Me}}You: {{end}}{{.Text}}</p></a>
{{else}}<div class="empty">No messages yet.<br>They show up here as they arrive.</div>{{end}}
{{template "poll" poll .Since}}
</body></html>{{define "poll"}}` + poll + `{{end}}`))

var chatTpl = template.Must(template.New("c").Funcs(template.FuncMap{"poll": func(chat string, since int64) map[string]any {
	return map[string]any{"PollURL": fmt.Sprintf("/n?ts=%d&j=%s", since, url.QueryEscape(chat)),
		"ReloadURL": chatURL(chat) + "&r=" + strconv.FormatInt(time.Now().Unix(), 10) + "#end"}
}}).Parse(head + `<title>{{.Name}}</title></head><body>
<div class="bar chat"><a class="l" href="/">‹ Chats</a><h1>{{.Name}}</h1></div>
{{if .HasEarlier}}<a class="more" href="{{.URL}}&before={{.Earlier}}">Earlier messages</a>{{end}}
{{range .Lines}}{{if .Day}}<div class="day">{{.Day}}</div>{{end}}<div class="m{{if .Me}} me{{end}}"><div>{{if .From}}<s>{{.From}}</s>{{end}}<span{{if .Media}} class="dim"{{end}}>{{.Text}}</span><i>{{.When}}{{if .Tick}}<b{{if .Read}} class="read"{{end}}>{{.Tick}}</b>{{end}}</i></div></div>
{{else}}<div class="empty">No messages yet. Say hello.</div>{{end}}
{{if .Older}}<a class="more" href="{{.URL}}#end">Latest messages</a>{{else}}
<form method="post" action="/send" id="f"><input type="hidden" name="j" value="{{.Chat}}"><input type="hidden" name="t" value="{{.CSRF}}">
<textarea name="m" id="m" placeholder="Message" autocapitalize="sentences"></textarea>
<a class="cam" id="pk" href="/pick?j={{.Chat}}">Photo</a><button id="b">Send</button></form>
<script>
var m=document.getElementById('m'),f=document.getElementById('f'),b=document.getElementById('b'),pk=document.getElementById('pk');
window.busy=false;
m.oninput=function(){m.style.height='42px';m.style.height=Math.min(m.scrollHeight+2,140)+'px';};
f.onsubmit=function(){if(!m.value.replace(/\s/g,'')){return false;}window.busy=true;b.disabled=true;b.innerHTML='Sending';};
// the typed text travels to the photo picker as the caption
pk.onclick=function(){if(m.value){pk.href+='&m='+encodeURIComponent(m.value);}};
</script>
{{template "poll" poll .Chat .Since}}{{end}}
<a id="end"></a>
</body></html>{{define "poll"}}` + poll + `{{end}}`))

var searchTpl = template.Must(template.New("s").Parse(head + `<title>Search</title></head><body>
<div class="bar chat"><a class="l" href="/">‹ Chats</a><h1>Search</h1></div>
<form class="find" method="get" action="/s"><input type="search" name="q" value="{{.Q}}" placeholder="Search people, groups, messages" autocorrect="off" autocapitalize="off"></form>
{{if .Number}}<a class="row" href="{{.Number}}#end"><b>Message {{.Q}}</b><p>New chat with this number</p></a>{{end}}
{{if .People}}<div class="sec">People and groups</div>{{range .People}}<a class="row" href="{{.URL}}#end"><b>{{.Name}}</b></a>
{{end}}{{end}}
{{if .Msgs}}<div class="sec">Messages</div>{{range .Msgs}}<a class="row" href="{{.URL}}#end"><span class="t">{{.When}}</span><b>{{.Name}}</b><p>{{.Text}}</p></a>
{{end}}{{end}}
{{if and .Q (not .People) (not .Msgs) (not .Number)}}<div class="empty">Nothing found for “{{.Q}}”.</div>{{end}}
</body></html>`))

var pickTpl = template.Must(template.New("p").Parse(head + `<title>Send a photo</title></head><body>
<div class="bar chat"><a class="l" href="{{.URL}}#end">‹ {{.Name}}</a><h1>&nbsp;</h1></div>
<form method="post" action="/send" id="pf" style="border:0;margin:0;padding:0"><input type="hidden" name="j" value="{{.Chat}}"><input type="hidden" name="t" value="{{.CSRF}}">
<div class="cap"><textarea name="m" placeholder="Caption (optional)" autocapitalize="sentences">{{.Caption}}</textarea></div>
{{if .Msg}}<div class="empty">{{.Msg}}</div>{{end}}
<div class="grid">{{range .Names}}<button name="lib" value="{{.}}"><img src="/thumb?n={{.}}" alt=""></button>{{end}}</div></form>
<script>
document.getElementById('pf').onsubmit=function(){var g=document.querySelectorAll('.grid button');
for(var i=0;i<g.length;i++){g[i].style.opacity='.3';}document.querySelector('.bar h1').innerHTML='Sending…';};
</script>
</body></html>`))

// ---- secrets and certificates -------------------------------------------------

func loadOrCreateToken() string {
	p := filepath.Join(*dataDir, "token")
	if b, err := os.ReadFile(p); err == nil && len(b) >= 32 {
		return strings.TrimSpace(string(b))
	}
	b := make([]byte, 24)
	rand.Read(b)
	t := hex.EncodeToString(b)
	must(os.WriteFile(p, []byte(t), 0o600))
	return t
}

// A private CA (installed on the phone once) signs a server cert for this computer's LAN addresses.
// The server cert is re-made on every start, so a new DHCP address just needs a restart.
func loadOrCreateCert() tls.Certificate {
	caCertPath, caKeyPath := filepath.Join(*dataDir, "ca.pem"), filepath.Join(*dataDir, "ca-key.pem")
	var ca *x509.Certificate
	var caKey *rsa.PrivateKey
	if cb, err := os.ReadFile(caCertPath); err == nil {
		kb, err := os.ReadFile(caKeyPath)
		must(err)
		cblk, _ := pem.Decode(cb)
		kblk, _ := pem.Decode(kb)
		ca, err = x509.ParseCertificate(cblk.Bytes)
		must(err)
		caKey, err = x509.ParsePKCS1PrivateKey(kblk.Bytes)
		must(err)
	} else {
		var err error
		caKey, err = rsa.GenerateKey(rand.Reader, 2048)
		must(err)
		tmpl := &x509.Certificate{
			SerialNumber: serial(), Subject: pkix.Name{CommonName: "dumb iPhone WhatsApp bridge CA"},
			NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().AddDate(10, 0, 0),
			IsCA: true, BasicConstraintsValid: true, MaxPathLenZero: true,
			KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		}
		der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &caKey.PublicKey, caKey)
		must(err)
		ca, _ = x509.ParseCertificate(der)
		must(os.WriteFile(caCertPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644))
		must(os.WriteFile(caKeyPath, pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(caKey)}), 0o600))
	}
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	must(err)
	host, _ := os.Hostname()
	tmpl := &x509.Certificate{
		SerialNumber: serial(), Subject: pkix.Name{CommonName: host},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().AddDate(1, 0, 0),
		KeyUsage:    x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, DNSNames: []string{host, host + ".local"},
	}
	for _, ip := range lanIPs() {
		tmpl.IPAddresses = append(tmpl.IPAddresses, net.ParseIP(ip))
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, ca, &key.PublicKey, caKey)
	must(err)
	return tls.Certificate{Certificate: [][]byte{der, ca.Raw}, PrivateKey: key}
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// androidDNS: Android has no /etc/resolv.conf, so Go's resolver would ask 127.0.0.1 and fail.
// Use Termux's resolv.conf if present, else public resolvers.
func androidDNS() {
	if _, err := os.Stat("/etc/resolv.conf"); err == nil {
		return
	}
	servers := []string{"1.1.1.1:53", "8.8.8.8:53"}
	if b, err := os.ReadFile(os.ExpandEnv("$PREFIX/etc/resolv.conf")); err == nil {
		var own []string
		for _, l := range strings.Split(string(b), "\n") {
			if f := strings.Fields(l); len(f) == 2 && f[0] == "nameserver" {
				own = append(own, net.JoinHostPort(f[1], "53"))
			}
		}
		if len(own) > 0 {
			servers = own
		}
	}
	net.DefaultResolver = &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
		var d net.Dialer
		var err error
		for _, s := range servers {
			var c net.Conn
			if c, err = d.DialContext(ctx, network, s); err == nil {
				return c, nil
			}
		}
		return nil, err
	}}
}

func serial() *big.Int {
	n, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	return n
}

func lanIPs() []string {
	var ips []string
	if *extraIP != "" {
		ips = append(ips, *extraIP)
	}
	addrs, _ := net.InterfaceAddrs()
	for _, a := range addrs {
		if n, ok := a.(*net.IPNet); ok && n.IP.To4() != nil && !n.IP.IsLoopback() && n.IP.IsPrivate() && n.IP.String() != *extraIP {
			ips = append(ips, n.IP.String())
		}
	}
	sort.Strings(ips[min(len(ips), boolInt(*extraIP != "")):])
	return append(ips, "127.0.0.1")
}
