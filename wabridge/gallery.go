package main

import (
	"bytes"
	"context"
	"image/jpeg"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// The phone's camera roll, read over Wi-Fi with a key the phone limits to "list" and "get"
// (see phone/dumbiphone-gallery). Safari's own photo picker crashes on jailbroken iOS 9.

var photoName = regexp.MustCompile(`^[0-9]{3}APPLE/IMG_[0-9]+\.(JPG|jpg|PNG|png)$`)

// phoneSSH runs the gallery command on the phone that made this request.
func phoneSSH(r *http.Request, args ...string) ([]byte, error) {
	ip, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "ssh", append([]string{"-F", filepath.Join(*dataDir, "ssh_config"),
		"-o", "HostName=" + ip, "gallery"}, args...)...)
	cmd.Env = append(os.Environ(), "OPENSSL_CONF="+filepath.Join(*dataDir, "openssl-legacy.cnf"))
	var errb bytes.Buffer
	cmd.Stderr = &errb
	out, err := cmd.Output()
	if err != nil && errb.Len() > 0 {
		return out, &sshError{err, strings.TrimSpace(errb.String())}
	}
	return out, err
}

type sshError struct {
	err    error
	stderr string
}

func (e *sshError) Error() string { return e.err.Error() + ": " + e.stderr }

func recentPhotos(r *http.Request, n int) ([]string, error) {
	out, err := phoneSSH(r, "list")
	if err != nil {
		return nil, err
	}
	var names []string
	for _, l := range strings.Split(string(out), "\n") {
		if photoName.MatchString(l) && len(names) < n {
			names = append(names, l)
		}
	}
	return names, nil
}

func fetchPhoto(r *http.Request, name string) ([]byte, error) {
	if !photoName.MatchString(name) {
		return nil, os.ErrNotExist
	}
	return phoneSSH(r, "get", name)
}

// thumbHandler: small previews for the picker, cached on this computer.
func thumbHandler(w http.ResponseWriter, r *http.Request) {
	name := r.URL.Query().Get("n")
	if !photoName.MatchString(name) {
		http.NotFound(w, r)
		return
	}
	cache := filepath.Join(*dataDir, "thumbs", strings.NewReplacer("/", "_").Replace(name)+".jpg")
	if b, err := os.ReadFile(cache); err == nil {
		w.Header().Set("Content-Type", "image/jpeg")
		w.Header().Set("Cache-Control", "private, max-age=86400")
		w.Write(b)
		return
	}
	raw, err := fetchPhoto(r, name)
	if err != nil {
		fail(w, r, 502, "Couldn't read that photo from the phone", err)
		return
	}
	img, _, err := decodeUpright(raw)
	if err != nil {
		fail(w, r, 415, "Not a photo", err)
		return
	}
	var b bytes.Buffer
	jpeg.Encode(&b, fit(img, 200), &jpeg.Options{Quality: 70})
	os.MkdirAll(filepath.Dir(cache), 0o700)
	os.WriteFile(cache, b.Bytes(), 0o600)
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Cache-Control", "private, max-age=86400")
	w.Write(b.Bytes())
}

// pickPage: the latest camera-roll photos; tapping one sends it, with the caption above.
func pickPage(w http.ResponseWriter, r *http.Request) {
	chat := r.URL.Query().Get("j")
	names, err := recentPhotos(r, 24)
	msg := ""
	if err != nil {
		log.Printf("gallery: %v", err)
		msg = "Couldn't reach the phone's photos. Is it on the same Wi-Fi as this computer?"
	} else if len(names) == 0 {
		msg = "No photos yet. Take one with Camera, then come back here."
	}
	render(w, pickTpl, map[string]any{"Chat": chat, "URL": chatURL(chat), "Name": chatName(r.Context(), chat),
		"Names": names, "Msg": msg, "CSRF": csrf(), "Caption": r.URL.Query().Get("m")})
}
