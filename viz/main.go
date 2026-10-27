// hub-viz: live view of Delamain — machines, stage hubs and their workers, journal lines as messages between them.
//
// Serves the embedded viz.html and three endpoints over the hub home (AGENT_HUB_HOME, default ~/agent-hub):
//
//	/state            machine, and the open stages that run now: their hubs and live workers, as agent-top shows them
//	/history?hours=N  journal lines of the last N hours (default 24, at most a week), resolved to sender and recipients
//	/events           server-sent events: "line" for every new journal line, "state" every 5 s
//	/assets/          the page's images
//
// Read-only: it never writes to the hub home.
// Run: hub-viz [-addr 127.0.0.1:8765] [-allow-origin http://page-origin] [-v]; several machines: http://localhost:8765/?src=http://a:8765,http://b:8765
package main

import (
	"bufio"
	"bytes"
	"embed"
	"encoding/json"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"math"
	"net/http"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

//go:embed viz.html
var page []byte

//go:embed assets
var assets embed.FS

var (
	lineRE    = regexp.MustCompile(`^- (\d{1,2}):(\d{2}) \[([^\]]+)\]\s?(.*)$`)
	journalRE = regexp.MustCompile(`^journal-(\d{4}-\d{2}-\d{2})\.md$`)
	mentionRE = regexp.MustCompile(`@([\p{L}\p{N}][\p{L}\p{N}_.-]*)(?:\s+([a-z0-9][a-z0-9_-]*))?`)
	hubTagRE  = regexp.MustCompile(`^(?:([a-z0-9][a-z0-9_-]*)-)?hub-\d+$`)
)

const (
	hubSpoke = 30 * time.Minute // a stage whose hub wrote to the journal this recently has a tower
	working  = 10 * time.Minute // a worker is busy while its log grew this recently
)

type Node [2]string // {stage, role}; the owner is {"*", "owner"}

type Event struct {
	Stage string `json:"stage"`
	Repo  string `json:"repo,omitempty"`
	Tag   string `json:"tag"`
	Text  string `json:"text"`
	At    string `json:"at"`
	From  Node   `json:"from"`
	// Engine of the sender from the role registry ("claude", "codex"), empty when unknown.
	Engine string `json:"engine,omitempty"`
	To     []Node `json:"to"`
	at     time.Time
}

type roleEntry struct {
	Tag    string `json:"tag"`
	Role   string `json:"role"`
	Kind   string `json:"kind"`
	Host   string `json:"host"`
	Engine string `json:"engine"`
	Title  string `json:"title"`
	PID    int    `json:"pid"`
	// CLISessionID is a hub's Claude session; a live hub has some process (its journal waiters) naming it.
	CLISessionID string `json:"cli_session_id"`
}

type stage struct {
	name, goal string
	repo       string // the repository's directory name; the page groups stages into districts by it
	open       bool
	dir        string
	active     map[string]roleEntry
	tags       map[string]string // tag -> role
	engines    map[string]string // role -> engine
}

type Worker struct {
	Role    string `json:"role"`
	Tag     string `json:"tag"`
	Engine  string `json:"engine"`
	Model   string `json:"model"`
	Alive   bool   `json:"alive"`
	Working bool   `json:"working"`
	Title   string `json:"title"`
}

type HubInfo struct {
	Tag   string `json:"tag"`
	Kind  string `json:"kind"`
	Host  string `json:"host"`
	Title string `json:"title"`
	Ctx   int    `json:"ctx"` // tokens in the hub session's context; 0 if unknown
}

type StageView struct {
	Name    string   `json:"name"`
	Repo    string   `json:"repo,omitempty"`
	Open    bool     `json:"open"`
	Goal    string   `json:"goal"`
	Hub     *HubInfo `json:"hub"`
	Workers []Worker `json:"workers"`
}

type State struct {
	Machine string      `json:"machine"`
	At      string      `json:"at"`
	Stages  []StageView `json:"stages"`
}

type Hub struct {
	root    string
	machine string

	mu      sync.Mutex
	stages  map[string]*stage
	heard   map[Node]time.Time // the latest journal line of each writer
	offsets map[string]int64
	state   State

	subMu sync.Mutex
	subs  map[chan []byte]struct{}
}

func readJSON(path string, v any) bool {
	b, err := os.ReadFile(path)
	return err == nil && json.Unmarshal(b, v) == nil
}

func pidAlive(pid int) bool {
	return pid > 0 && syscall.Kill(pid, 0) == nil
}

// processTable is {pid: command line} of every process, or nil when ps fails.
func processTable() map[int]string {
	out, err := exec.Command("ps", "-ww", "-axo", "pid=,command=").Output()
	if err != nil {
		return nil
	}
	table := map[int]string{}
	for _, ln := range strings.Split(string(out), "\n") {
		f := strings.Fields(ln)
		if len(f) < 2 {
			continue
		}
		if pid, err := strconv.Atoi(f[0]); err == nil {
			table[pid] = strings.Join(f[1:], " ")
		}
	}
	return table
}

// agentAlive mirrors agent-top's is_alive: the pid must run a command line that names the agent's session,
// since a pid is reused by unrelated processes once the agent exits.
func agentAlive(pid int, token string, table map[int]string) bool {
	if pid <= 0 {
		return false
	}
	if table == nil {
		return pidAlive(pid)
	}
	return token != "" && strings.Contains(table[pid], token)
}

// scan rebuilds the stage registry and tag → role index. Caller holds mu.
func (h *Hub) scan() {
	metas, _ := filepath.Glob(filepath.Join(h.root, "*", "stage.json"))
	stages := map[string]*stage{}
	for _, meta := range metas {
		dir := filepath.Dir(meta)
		var info struct {
			Goal   string          `json:"goal"`
			Repo   string          `json:"repo"`
			Closed json.RawMessage `json:"closed"`
		}
		readJSON(meta, &info)
		var roles struct {
			Roles   map[string]roleEntry `json:"roles"`
			Retired []roleEntry          `json:"retired"`
		}
		readJSON(filepath.Join(dir, "roles.json"), &roles)
		repo := ""
		if info.Repo != "" {
			repo = filepath.Base(info.Repo)
		}
		st := &stage{name: filepath.Base(dir), goal: info.Goal, repo: repo, dir: dir, active: roles.Roles, tags: map[string]string{}, engines: map[string]string{},
			open: len(info.Closed) == 0 || string(info.Closed) == "null"}
		for _, r := range roles.Retired {
			if r.Tag != "" && r.Role != "" {
				st.tags[r.Tag] = r.Role
			}
			if r.Role != "" && r.Engine != "" {
				st.engines[r.Role] = r.Engine
			}
		}
		for role, r := range roles.Roles {
			st.tags[role] = role
			if r.Engine != "" {
				st.engines[role] = r.Engine
			}
			if r.Tag != "" {
				st.tags[r.Tag] = role
			}
		}
		stages[st.name] = st
	}
	h.stages = stages
}

// resolve maps a journal tag written in stage's journal to the node that wrote it.
func (h *Hub) resolve(stageName, tag string) Node {
	if f := strings.Fields(tag); len(f) > 0 {
		tag = f[0]
	}
	if tag == "owner" {
		return Node{"*", "owner"}
	}
	if m := hubTagRE.FindStringSubmatch(tag); m != nil {
		if m[1] == "" {
			return Node{stageName, "hub"}
		}
		if _, ok := h.stages[m[1]]; ok {
			return Node{m[1], "hub"}
		}
	}
	if st := h.stages[stageName]; st != nil {
		if role, ok := st.tags[tag]; ok {
			return Node{stageName, role}
		}
	}
	for name, st := range h.stages {
		if rest, ok := strings.CutPrefix(tag, name+"-"); ok {
			if role, ok := st.tags[rest]; ok {
				return Node{name, role}
			}
		}
	}
	return Node{stageName, tag}
}

func (h *Hub) known(stageName, tag string) bool {
	st := h.stages[stageName]
	if st == nil {
		return false
	}
	_, ok := st.tags[tag]
	return ok
}

func (h *Hub) recipients(stageName string, sender Node, text string) []Node {
	if len(text) > 240 {
		text = text[:240]
	}
	var out []Node
	add := func(n Node) {
		if n == sender {
			return
		}
		for _, o := range out {
			if o == n {
				return
			}
		}
		out = append(out, n)
	}
	for _, m := range mentionRE.FindAllStringSubmatch(text, -1) {
		name, qual := strings.TrimRight(m[1], ".,;:!?)"), m[2]
		if name != m[1] {
			qual = "" // the mention ended at punctuation: the next word is not its stage
		}
		_, qualIsStage := h.stages[qual]
		switch {
		case name == "hub" || name == "hubs" || name == "all":
			if qualIsStage {
				add(Node{qual, "hub"})
			} else {
				add(Node{stageName, "hub"})
			}
		case name == "owner":
			add(Node{"*", "owner"})
		case h.stages[name] != nil && !h.known(stageName, name): // a stage's name addresses its hub
			add(Node{name, "hub"})
		default:
			where := stageName
			if qualIsStage {
				where = qual
			}
			n := h.resolve(where, name)
			if n[1] == name && !h.known(n[0], name) {
				continue // an e-mail, a decorator, an unknown handle: not an address
			}
			add(n)
		}
	}
	if len(out) == 0 && sender != (Node{stageName, "hub"}) {
		add(Node{stageName, "hub"}) // an unaddressed line is a report to the stage's hub
	}
	return out
}

// event parses one journal line. Caller holds mu.
func (h *Hub) event(stageName string, day time.Time, line string) *Event {
	m := lineRE.FindStringSubmatch(strings.TrimRight(line, "\r\n"))
	if m == nil {
		return nil
	}
	hh, _ := strconv.Atoi(m[1])
	mm, _ := strconv.Atoi(m[2])
	at := time.Date(day.Year(), day.Month(), day.Day(), hh%24, mm, 0, 0, time.Local)
	sender := h.resolve(stageName, m[3])
	text := m[4]
	if r := []rune(text); len(r) > 400 {
		text = string(r[:400])
	}
	ev := &Event{Stage: stageName, Tag: m[3], Text: text, At: at.Format(time.RFC3339), From: sender,
		To: h.recipients(stageName, sender, m[4]), at: at}
	if st := h.stages[sender[0]]; st != nil {
		ev.Engine = st.engines[sender[1]]
	}
	if st := h.stages[stageName]; st != nil {
		ev.Repo = st.repo
	}
	if prev, ok := h.heard[sender]; !ok || at.After(prev) {
		h.heard[sender] = at
	}
	return ev
}

type journal struct {
	stage string
	day   time.Time
	path  string
}

func (h *Hub) journals(since time.Time) []journal {
	paths, _ := filepath.Glob(filepath.Join(h.root, "*", "coordinator", "work", "journal-*.md"))
	var out []journal
	for _, p := range paths {
		m := journalRE.FindStringSubmatch(filepath.Base(p))
		if m == nil {
			continue
		}
		day, err := time.ParseInLocation("2006-01-02", m[1], time.Local)
		if err != nil || day.Before(since) {
			continue
		}
		out = append(out, journal{filepath.Base(filepath.Dir(filepath.Dir(filepath.Dir(p)))), day, p})
	}
	return out
}

func midnight(t time.Time) time.Time {
	return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.Local)
}

func (h *Hub) history(hours float64) []*Event {
	h.mu.Lock()
	defer h.mu.Unlock()
	cutoff := time.Now().Add(-time.Duration(hours * float64(time.Hour)))
	var out []*Event
	for _, j := range h.journals(midnight(cutoff)) {
		f, err := os.Open(j.path)
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
		for sc.Scan() {
			if ev := h.event(j.stage, j.day, sc.Text()); ev != nil && !ev.at.Before(cutoff) {
				out = append(out, ev)
			}
		}
		f.Close()
	}
	sort.SliceStable(out, func(a, b int) bool { return out[a].at.Before(out[b].at) })
	return out
}

// poll returns the lines appended to the recent journals since the last poll.
func (h *Hub) poll() []*Event {
	h.mu.Lock()
	defer h.mu.Unlock()
	var out []*Event
	for _, j := range h.journals(midnight(time.Now()).AddDate(0, 0, -1)) {
		fi, err := os.Stat(j.path)
		if err != nil {
			continue
		}
		start := h.offsets[j.path]
		if fi.Size() < start { // truncated or rotated: resume from its end, the old lines are not news
			h.offsets[j.path] = fi.Size()
			continue
		}
		if fi.Size() == start {
			continue
		}
		f, err := os.Open(j.path)
		if err != nil {
			continue
		}
		buf := make([]byte, fi.Size()-start)
		n, _ := f.ReadAt(buf, start)
		f.Close()
		buf = buf[:n]
		cut := bytes.LastIndexByte(buf, '\n') + 1 // a half-written last line waits for the next poll
		h.offsets[j.path] = start + int64(cut)
		for _, line := range strings.Split(string(buf[:cut]), "\n") {
			if ev := h.event(j.stage, j.day, line); ev != nil {
				out = append(out, ev)
			}
		}
	}
	return out
}

// prime starts the tail at the journals' current ends and fills heard from the lines a tower depends on.
func (h *Hub) prime() {
	h.mu.Lock()
	for _, j := range h.journals(midnight(time.Now()).AddDate(0, 0, -1)) {
		if fi, err := os.Stat(j.path); err == nil {
			h.offsets[j.path] = fi.Size()
		}
	}
	h.mu.Unlock()
	h.history(hubSpoke.Hours())
}

// snapshot builds the visible state: what runs, like agent-top. A worker is on it while its process lives; an open
// stage has a tower while it has live workers, its hub spoke within hubSpoke, or some process names the hub's session
// (the hub's journal waiters do). Caller holds mu.
func (h *Hub) snapshot() State {
	now := time.Now()
	procs := processTable()
	names := make([]string, 0, len(h.stages))
	for n := range h.stages {
		names = append(names, n)
	}
	sort.Strings(names)
	views := []StageView{}
	for _, name := range names {
		st := h.stages[name]
		if !st.open {
			continue
		}
		workers := []Worker{}
		roles := make([]string, 0, len(st.active))
		for r := range st.active {
			roles = append(roles, r)
		}
		sort.Strings(roles)
		for _, role := range roles {
			if role == "hub" {
				continue
			}
			entry := st.active[role]
			var meta struct {
				PID           int    `json:"pid"`
				SessionID     string `json:"session_id"`
				ProcessToken  string `json:"process_token"`
				Engine        string `json:"engine"`
				Model         string `json:"model"`
				ResolvedModel string `json:"resolved_model"`
				Title         string `json:"title"`
			}
			adir := filepath.Join(st.dir, "agents", role)
			readJSON(filepath.Join(adir, "meta.json"), &meta)
			pid := meta.PID
			if pid == 0 {
				pid = entry.PID
			}
			token := meta.ProcessToken
			if token == "" {
				token = meta.SessionID
			}
			if !agentAlive(pid, token, procs) {
				continue
			}
			busy := false
			if fi, err := os.Stat(filepath.Join(adir, "log.jsonl")); err == nil {
				busy = now.Sub(fi.ModTime()) < working
			}
			w := Worker{Role: role, Tag: entry.Tag, Engine: entry.Engine, Model: meta.ResolvedModel, Alive: true,
				Working: busy, Title: meta.Title}
			if w.Tag == "" {
				w.Tag = role
			}
			if w.Engine == "" {
				w.Engine = meta.Engine
			}
			if w.Model == "" {
				w.Model = meta.Model
			}
			if w.Title == "" {
				w.Title = entry.Title
			}
			workers = append(workers, w)
		}
		spoke, ok := h.heard[Node{name, "hub"}]
		hubLive := len(workers) > 0 || ok && now.Sub(spoke) < hubSpoke
		if hub, ok := st.active["hub"]; ok && hub.CLISessionID != "" && !hubLive {
			for _, cmd := range procs {
				if strings.Contains(cmd, hub.CLISessionID) {
					hubLive = true
					break
				}
			}
		}
		if !hubLive {
			continue
		}
		v := StageView{Name: name, Repo: st.repo, Open: st.open, Goal: st.goal, Workers: workers}
		if hub, ok := st.active["hub"]; ok {
			v.Hub = &HubInfo{Tag: hub.Tag, Kind: hub.Kind, Host: hub.Host, Title: hub.Title, Ctx: hubContext(h.root, hub.CLISessionID)}
		}
		views = append(views, v)
	}
	return State{Machine: h.machine, At: now.Format(time.RFC3339), Stages: views}
}

func (h *Hub) publish(kind string, v any) {
	b, _ := json.Marshal(v)
	msg := []byte(fmt.Sprintf("event: %s\ndata: %s\n\n", kind, b))
	h.subMu.Lock()
	defer h.subMu.Unlock()
	for ch := range h.subs {
		select {
		case ch <- msg:
		default: // a slow viewer drops frames rather than holding the hub
		}
	}
}

func (h *Hub) loop() {
	for tick := 1; ; tick++ {
		time.Sleep(time.Second)
		if tick%5 == 0 {
			h.mu.Lock()
			h.scan()
			h.mu.Unlock()
		}
		for _, ev := range h.poll() {
			h.publish("line", ev)
		}
		if tick%5 == 0 {
			h.mu.Lock()
			h.state = h.snapshot()
			st := h.state
			h.mu.Unlock()
			h.publish("state", st)
		}
	}
}

// allowOrigins are the page origins that may read this server from another origin (-allow-origin); none by default.
var allowOrigins = map[string]bool{}

func cors(w http.ResponseWriter, r *http.Request) {
	if len(allowOrigins) == 0 {
		return
	}
	w.Header().Add("Vary", "Origin")
	if o := r.Header.Get("Origin"); allowOrigins[o] {
		w.Header().Set("Access-Control-Allow-Origin", o)
	}
}

func writeJSON(w http.ResponseWriter, r *http.Request, v any) {
	cors(w, r)
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func (h *Hub) routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/{$}", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(page)
	})
	files := http.FileServerFS(assets)
	mux.HandleFunc("/assets/", func(w http.ResponseWriter, r *http.Request) {
		if fi, err := fs.Stat(assets, path.Clean(r.URL.Path[1:])); err != nil || fi.IsDir() {
			http.NotFound(w, r) // files only: no directory listing
			return
		}
		cors(w, r)
		files.ServeHTTP(w, r)
	})
	mux.HandleFunc("/state", func(w http.ResponseWriter, r *http.Request) {
		h.mu.Lock()
		st := h.state
		h.mu.Unlock()
		writeJSON(w, r, st)
	})
	mux.HandleFunc("/history", func(w http.ResponseWriter, r *http.Request) {
		hours, err := strconv.ParseFloat(r.URL.Query().Get("hours"), 64)
		if err != nil || hours <= 0 || math.IsNaN(hours) || math.IsInf(hours, 0) {
			hours = 24
		}
		writeJSON(w, r, map[string]any{"machine": h.machine, "lines": h.history(min(hours, 24*7))})
	})
	mux.HandleFunc("/events", func(w http.ResponseWriter, r *http.Request) {
		fl, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, "streaming unsupported", http.StatusInternalServerError)
			return
		}
		cors(w, r)
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Type", "text/event-stream")
		ch := make(chan []byte, 64)
		h.subMu.Lock()
		h.subs[ch] = struct{}{}
		h.subMu.Unlock()
		defer func() {
			h.subMu.Lock()
			delete(h.subs, ch)
			h.subMu.Unlock()
		}()
		h.mu.Lock()
		b, _ := json.Marshal(h.state)
		h.mu.Unlock()
		fmt.Fprintf(w, "event: state\ndata: %s\n\n", b)
		fl.Flush()
		ping := time.NewTicker(15 * time.Second)
		defer ping.Stop()
		for {
			select {
			case <-r.Context().Done():
				return
			case msg := <-ch:
				w.Write(msg)
			case <-ping.C:
				w.Write([]byte(": ping\n\n"))
			}
			fl.Flush()
		}
	})
	return mux
}

func main() {
	addr := flag.String("addr", "127.0.0.1:8765", "listen address; 0.0.0.0:8765 lets another machine's page read this one")
	origins := flag.String("allow-origin", "", "comma-separated page origins that may read this server from another origin (CORS); none by default")
	verbose := flag.Bool("v", false, "log every request but assets, with its user agent (a screen saver's diagnostics arrive this way)")
	flag.Parse()
	for _, o := range strings.Split(*origins, ",") {
		if o = strings.TrimRight(strings.TrimSpace(o), "/"); o != "" {
			allowOrigins[o] = true
		}
	}
	root := os.Getenv("AGENT_HUB_HOME")
	if root == "" {
		home, _ := os.UserHomeDir()
		root = filepath.Join(home, "agent-hub")
	}
	host, _ := os.Hostname()
	h := &Hub{root: root, machine: strings.TrimSuffix(host, ".local"), heard: map[Node]time.Time{},
		offsets: map[string]int64{}, subs: map[chan []byte]struct{}{}}
	h.mu.Lock()
	h.scan()
	h.mu.Unlock()
	h.prime()
	h.mu.Lock()
	h.state = h.snapshot()
	h.mu.Unlock()
	go h.loop()
	log.Printf("hub-viz: http://%s/  (home %s, machine %s)", *addr, root, h.machine)
	var handler http.Handler = h.routes()
	if *verbose {
		routes := handler
		handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !strings.HasPrefix(r.URL.Path, "/assets/") {
				log.Printf("%s %s (%s)", r.Method, r.URL.RequestURI(), r.UserAgent())
			}
			routes.ServeHTTP(w, r)
		})
	}
	log.Fatal(http.ListenAndServe(*addr, handler))
}
