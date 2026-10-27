package main

// Per-hub facts read from the hub home and the Claude transcripts: the size of a hub session's context, the number
// of owner questions a stage has open. Read-only.

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

const (
	ctxChunk   = 1 << 20  // read the transcript tail this much at a time
	ctxMaxScan = 32 << 20 // give up after this much of the tail
)

// ctxCache remembers where a session's transcript is and what its tail said, until the file changes.
var ctxCache = struct {
	sync.Mutex
	path map[string]string // session id -> transcript path
	last map[string]ctxSeen
}{path: map[string]string{}, last: map[string]ctxSeen{}}

type ctxSeen struct {
	size, mtime int64
	tokens      int
}

func claudeProjectsDir() string {
	if d := os.Getenv("CLAUDE_CONFIG_DIR"); d != "" {
		return filepath.Join(d, "projects")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".claude", "projects")
}

// hubContext is the token count of a hub session's context: the usage of the last assistant record of its Claude
// transcript (input + cache read + cache creation, as the context-budget hook counts it), else the count the
// context-budget hook recorded when it last warned (it records one only past its first threshold), else 0.
func hubContext(root, session string) int {
	if session == "" || strings.ContainsAny(session, `/\`) {
		return 0
	}
	if n := transcriptContext(session); n > 0 {
		return n
	}
	var st struct {
		Tokens int `json:"tokens"`
	}
	readJSON(filepath.Join(root, ".state", "context-budget", session+".json"), &st)
	return st.Tokens
}

func transcriptContext(session string) int {
	ctxCache.Lock()
	p := ctxCache.path[session]
	ctxCache.Unlock()
	fi, err := os.Stat(p)
	if p == "" || err != nil {
		m, _ := filepath.Glob(filepath.Join(claudeProjectsDir(), "*", session+".jsonl"))
		if len(m) == 0 {
			return 0
		}
		p = m[0]
		if fi, err = os.Stat(p); err != nil {
			return 0
		}
		ctxCache.Lock()
		ctxCache.path[session] = p
		ctxCache.Unlock()
	}
	ctxCache.Lock()
	seen, ok := ctxCache.last[session]
	ctxCache.Unlock()
	if ok && seen.size == fi.Size() && seen.mtime == fi.ModTime().UnixNano() {
		return seen.tokens
	}
	n := lastUsage(p)
	ctxCache.Lock()
	ctxCache.last[session] = ctxSeen{fi.Size(), fi.ModTime().UnixNano(), n}
	ctxCache.Unlock()
	return n
}

type usageRecord struct {
	Type        string `json:"type"`
	IsSidechain bool   `json:"isSidechain"`
	Message     struct {
		Model string `json:"model"`
		Usage struct {
			Input         int `json:"input_tokens"`
			CacheRead     int `json:"cache_read_input_tokens"`
			CacheCreation int `json:"cache_creation_input_tokens"`
		} `json:"usage"`
	} `json:"message"`
}

// lastUsage scans a JSONL transcript backwards for its last main-thread assistant record with usage.
func lastUsage(path string) int {
	f, err := os.Open(path)
	if err != nil {
		return 0
	}
	defer f.Close()
	pos, err := f.Seek(0, io.SeekEnd)
	if err != nil {
		return 0
	}
	var tail []byte
	scanned := int64(0)
	for pos > 0 && scanned < ctxMaxScan {
		step := int64(ctxChunk)
		if step > pos {
			step = pos
		}
		pos -= step
		buf := make([]byte, step)
		if _, err := f.ReadAt(buf, pos); err != nil {
			return 0
		}
		scanned += step
		buf = append(buf, tail...)
		lines := bytes.Split(buf, []byte("\n"))
		if pos > 0 {
			tail, lines = lines[0], lines[1:] // the first line is cut by the chunk edge
		}
		for i := len(lines) - 1; i >= 0; i-- {
			if !bytes.Contains(lines[i], []byte(`"assistant"`)) {
				continue
			}
			var r usageRecord
			if json.Unmarshal(lines[i], &r) != nil || r.Type != "assistant" || r.IsSidechain || r.Message.Model == "<synthetic>" {
				continue
			}
			if n := r.Message.Usage.Input + r.Message.Usage.CacheRead + r.Message.Usage.CacheCreation; n > 0 {
				return n
			}
		}
	}
	return 0
}
