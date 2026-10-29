package main

// Plan limits of both engines for the owner tower's gauge, read like bin/limit_pace.py: the last rate_limit_event of
// each recent headless Claude agent log in the hub home, and the token_count rate limits in the tails of recent Codex
// rollouts. Logged observations, not API queries; read-only. A window whose reset has passed counts as full again.

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	limitsEvery  = time.Minute    // the logs are read again this often
	limitsLogAge = 12 * time.Hour // logs and rollouts written within this span are read
	limitsTail   = 256 << 10      // a Codex rollout's tail
	limitsScan   = 8 << 20        // a Claude log is searched backwards at most this far
	limitsLogMax = 64             // at most this many Claude logs and Codex rollouts, newest first
)

// Limit is what an engine has left: the smallest remaining share over its known windows, and which window that is.
type Limit struct {
	Left   float64 `json:"left"` // percent, 0..100
	Window string  `json:"window"`
}

type limitSample struct {
	used   float64 // percent
	seen   time.Time
	resets time.Time // zero when unknown
}

var limitsCache = struct {
	sync.Mutex
	at  time.Time
	out map[string]*Limit
}{}

// planLimits is {"claude": …, "codex": …}; an engine without a sample is missing.
func planLimits(home string) map[string]*Limit {
	limitsCache.Lock()
	defer limitsCache.Unlock()
	if limitsCache.out != nil && time.Since(limitsCache.at) < limitsEvery {
		return limitsCache.out
	}
	now := time.Now()
	out := map[string]*Limit{}
	for engine, wins := range map[string]map[string]limitSample{"claude": claudeLimits(home, now), "codex": codexLimits(now)} {
		for label, s := range wins {
			left := 100 - s.used
			if !s.resets.IsZero() && s.resets.Before(now) {
				left = 100
			}
			left = max(0, min(100, left))
			if cur := out[engine]; cur == nil || left < cur.Left {
				out[engine] = &Limit{Left: left, Window: label}
			}
		}
	}
	limitsCache.at, limitsCache.out = now, out
	return out
}

// recentFiles is the files matching the patterns written within limitsLogAge, newest first, at most limitsLogMax.
func recentFiles(now time.Time, patterns ...string) []string {
	type f struct {
		path string
		mt   time.Time
	}
	var got []f
	for _, pat := range patterns {
		paths, _ := filepath.Glob(pat)
		for _, p := range paths {
			if fi, err := os.Stat(p); err == nil && now.Sub(fi.ModTime()) < limitsLogAge {
				got = append(got, f{p, fi.ModTime()})
			}
		}
	}
	for i := 1; i < len(got); i++ { // insertion sort, newest first: a few dozen files
		for j := i; j > 0 && got[j].mt.After(got[j-1].mt); j-- {
			got[j], got[j-1] = got[j-1], got[j]
		}
	}
	out := []string{}
	for i := 0; i < len(got) && i < limitsLogMax; i++ {
		out = append(out, got[i].path)
	}
	return out
}

func newer(wins map[string]limitSample, label string, s limitSample) {
	if cur, ok := wins[label]; !ok || s.seen.After(cur.seen) {
		wins[label] = s
	}
}

func epochTime(v *float64) time.Time {
	if v == nil || *v <= 0 {
		return time.Time{}
	}
	return time.Unix(int64(*v), 0)
}

// claudeLimits: the last rate_limit_event of each log; the event has no time, so the log's mtime is the sample time.
func claudeLimits(home string, now time.Time) map[string]limitSample {
	wins := map[string]limitSample{}
	for _, p := range recentFiles(now, filepath.Join(home, "*", "agents", "*", "log.jsonl")) {
		fi, err := os.Stat(p)
		if err != nil {
			continue
		}
		line := lastLineWith(p, []byte(`"rate_limit_event"`))
		var ev struct {
			Info struct {
				Windows map[string]struct {
					Utilization *float64 `json:"utilization"`
					ResetsAt    *float64 `json:"resetsAt"`
				} `json:"unifiedWindows"`
			} `json:"rate_limit_info"`
		}
		if line == nil || json.Unmarshal(line, &ev) != nil {
			continue
		}
		for key, label := range map[string]string{"seven_day": "7d", "five_hour": "5h"} {
			w, ok := ev.Info.Windows[key]
			if !ok || w.Utilization == nil || *w.Utilization < 0 {
				continue
			}
			newer(wins, label, limitSample{used: 100 * *w.Utilization, seen: fi.ModTime(), resets: epochTime(w.ResetsAt)})
		}
	}
	return wins
}

// lastLineWith is the newest complete line of the file that contains needle, searching back at most limitsScan.
func lastLineWith(path string, needle []byte) []byte {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	end, err := f.Seek(0, io.SeekEnd)
	if err != nil {
		return nil
	}
	pos, stop := end, max(0, end-limitsScan)
	var pending []byte // the partial leading line of the chunk read last
	for pos > stop {
		size := min(int64(limitsTail), pos-stop)
		pos -= size
		buf := make([]byte, size, size+int64(len(pending)))
		if _, err := f.ReadAt(buf, pos); err != nil {
			return nil
		}
		buf = append(buf, pending...)
		lines := bytes.Split(buf, []byte("\n"))
		pending = lines[0]
		tail := lines[1:]
		for i := len(tail) - 1; i >= 0; i-- {
			if i == len(tail)-1 && pos+size == end {
				continue // after the last newline: unfinished, or empty
			}
			if bytes.Contains(tail[i], needle) {
				return tail[i]
			}
		}
	}
	if pos == 0 && bytes.Contains(pending, needle) {
		return pending
	}
	return nil
}

func codexHome() string {
	if d := os.Getenv("CODEX_HOME"); d != "" {
		return d
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".codex")
}

// codexLimits: every account-bucket (limit_id "codex") token_count rate limit in the rollouts' tails. A rollout lives
// under the day it started, so the last week of day directories is searched.
func codexLimits(now time.Time) map[string]limitSample {
	root := filepath.Join(codexHome(), "sessions")
	var pats []string
	for d := 0; d < 7; d++ {
		pats = append(pats, filepath.Join(root, now.AddDate(0, 0, -d).Format("2006/01/02"), "rollout-*.jsonl"))
	}
	wins := map[string]limitSample{}
	for _, p := range recentFiles(now, pats...) {
		f, err := os.Open(p)
		if err != nil {
			continue
		}
		if fi, err := f.Stat(); err == nil && fi.Size() > limitsTail {
			f.Seek(fi.Size()-limitsTail, io.SeekStart)
		}
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 0, 64<<10), limitsTail+1)
		for sc.Scan() {
			line := sc.Bytes()
			if !bytes.Contains(line, []byte(`"rate_limits"`)) {
				continue
			}
			var ev struct {
				Type      string `json:"type"`
				Timestamp string `json:"timestamp"`
				Payload   struct {
					Type   string `json:"type"`
					Limits *struct {
						LimitID string       `json:"limit_id"`
						Primary *codexWindow `json:"primary"`
						Second  *codexWindow `json:"secondary"`
					} `json:"rate_limits"`
				} `json:"payload"`
			}
			if json.Unmarshal(line, &ev) != nil || ev.Type != "event_msg" || ev.Payload.Type != "token_count" || ev.Payload.Limits == nil {
				continue
			}
			if id := ev.Payload.Limits.LimitID; id != "" && id != "codex" {
				continue
			}
			seen, err := time.Parse(time.RFC3339Nano, ev.Timestamp)
			if err != nil {
				continue
			}
			for _, w := range []*codexWindow{ev.Payload.Limits.Primary, ev.Payload.Limits.Second} {
				if w == nil || w.Used == nil || w.Minutes == nil || *w.Used < 0 {
					continue
				}
				label := map[int]string{300: "5h", 10080: "7d"}[int(*w.Minutes)]
				if label == "" {
					label = time.Duration(*w.Minutes * float64(time.Minute)).String()
				}
				newer(wins, label, limitSample{used: *w.Used, seen: seen, resets: epochTime(w.ResetsAt)})
			}
		}
		f.Close()
	}
	return wins
}

type codexWindow struct {
	Used     *float64 `json:"used_percent"`
	Minutes  *float64 `json:"window_minutes"`
	ResetsAt *float64 `json:"resets_at"`
}
