// Copyright 2026 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Loopback close probe: investigates whether one peer closing a TCP
// connection unblocks the other peer's in-flight Write on Plan 9.
//
// Mirrors the failure mode of net/http's TestServerNoWriteTimeout and
// TestTransportReqCancelerCleanupOnRequestBodyWriteError, but in a
// self-contained program that doesn't depend on the net/http stack.
//
// Two scenarios are exercised:
//
//	Scenario A: server writes 'a's forever; client reads 1 MiB then Close().
//	            Server's Write should eventually return an error.
//
//	Scenario B: client streams a 1 GiB body forever; server reads 1 byte,
//	            writes a small response, then Close()s.  Client's Write
//	            should eventually return an error.
//
// For each scenario, the program prints whether the writer unblocked and
// how many bytes were buffered before that happened.  A scenario that
// fails to unblock within the per-scenario deadline is reported with
// TIMEOUT, which is the symptom that hangs the corresponding net/http
// test.
package main

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	clientReadAmount = 1 << 20 // 1 MiB
	scenarioDeadline = 60 * time.Second
	scenarioBufBytes = 32 * 1024
	scenarioMaxWrite = 1 << 30 // 1 GiB
)

func main() {
	fmt.Printf("loopback-close-probe %s/%s %s\n", runtime.GOOS, runtime.GOARCH, runtime.Version())

	failures := 0
	if !scenarioA() {
		failures++
	}
	if !scenarioB() {
		failures++
	}
	if !scenarioC() {
		failures++
	}
	if failures > 0 {
		fmt.Printf("RESULT %d/3 scenarios FAILED to unblock\n", failures)
		os.Exit(1)
	}
	fmt.Println("RESULT all scenarios unblocked")
}

// tcpStateForConn reads /net/tcp/N/status for the conv whose local AND
// remote endpoint match the connection (so the listener conv is ignored).
// Returns the first whitespace token of the status line (the TCP state)
// and the raw status content.
func tcpStateForConn(local, remote net.Addr) (state, raw string, ok bool) {
	if runtime.GOOS != "plan9" {
		return "", "", false
	}
	localTCP, _ := local.(*net.TCPAddr)
	remoteTCP, _ := remote.(*net.TCPAddr)
	if localTCP == nil || remoteTCP == nil {
		return "", "", false
	}
	wantLocalPort := strconv.Itoa(localTCP.Port)
	wantRemotePort := strconv.Itoa(remoteTCP.Port)
	entries, err := os.ReadDir("/net/tcp")
	if err != nil {
		return "", "", false
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		if _, err := strconv.Atoi(e.Name()); err != nil {
			continue
		}
		dir := filepath.Join("/net/tcp", e.Name())
		lb, err := os.ReadFile(filepath.Join(dir, "local"))
		if err != nil {
			continue
		}
		local := strings.TrimSpace(string(lb))
		lparts := strings.Split(local, "!")
		if len(lparts) < 2 || lparts[len(lparts)-1] != wantLocalPort {
			continue
		}
		rb, err := os.ReadFile(filepath.Join(dir, "remote"))
		if err != nil {
			continue
		}
		remote := strings.TrimSpace(string(rb))
		rparts := strings.Split(remote, "!")
		if len(rparts) < 2 || rparts[len(rparts)-1] != wantRemotePort {
			continue
		}
		sb, err := os.ReadFile(filepath.Join(dir, "status"))
		if err != nil {
			continue
		}
		status := strings.TrimSpace(string(sb))
		fields := strings.Fields(status)
		if len(fields) == 0 {
			continue
		}
		return fields[0], status, true
	}
	return "", "", false
}

// scenarioC sends a moderate amount of data, then closes one side, then
// waits a bit, then writes a single byte from the other side to see if
// that write fails.  This is closer to the http transport pattern where
// the writer is throttled by the client receiver.
func scenarioC() bool {
	fmt.Println("--- scenario C: small write after peer close should eventually fail ---")
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Printf("scenarioC: listen: %v\n", err)
		return false
	}
	defer ln.Close()

	type result struct {
		err     error
		elapsed time.Duration
		state   string
	}
	resCh := make(chan result, 1)
	clientClosed := make(chan struct{})

	var wg sync.WaitGroup
	wg.Add(2)

	go func() {
		defer wg.Done()
		conn, err := ln.Accept()
		if err != nil {
			fmt.Printf("scenarioC server: accept: %v\n", err)
			resCh <- result{err: err}
			return
		}
		defer conn.Close()
		if _, err := io.WriteString(conn, "hello"); err != nil {
			fmt.Printf("scenarioC server: initial write: %v\n", err)
			resCh <- result{err: err}
			return
		}
		<-clientClosed
		dumpState := func(tag string) string {
			state, raw, ok := tcpStateForConn(conn.LocalAddr(), conn.RemoteAddr())
			if ok {
				fmt.Printf("scenarioC server: %s state=%s raw=%q\n", tag, state, raw)
				return state
			}
			fmt.Printf("scenarioC server: %s state lookup failed\n", tag)
			return ""
		}
		state := dumpState("post-close")
		start := time.Now()
		var lastErr error
		for i := 0; i < 600; i++ { // up to 60s at 100ms each
			_, lastErr = conn.Write([]byte("x"))
			if lastErr != nil {
				dumpState(fmt.Sprintf("write-error iter=%d", i))
				resCh <- result{err: lastErr, elapsed: time.Since(start), state: state}
				return
			}
			if i%10 == 0 {
				dumpState(fmt.Sprintf("after iter=%d", i))
			}
			time.Sleep(100 * time.Millisecond)
		}
		dumpState("end-of-loop")
		resCh <- result{err: nil, elapsed: time.Since(start), state: state}
	}()

	go func() {
		defer wg.Done()
		conn, err := net.Dial("tcp", ln.Addr().String())
		if err != nil {
			fmt.Printf("scenarioC client: dial: %v\n", err)
			close(clientClosed)
			return
		}
		r := bufio.NewReader(conn)
		buf := make([]byte, 5)
		if _, err := io.ReadFull(r, buf); err != nil {
			fmt.Printf("scenarioC client: read: %v\n", err)
		}
		if err := conn.Close(); err != nil {
			fmt.Printf("scenarioC client: close: %v\n", err)
		}
		close(clientClosed)
	}()

	r := <-resCh
	wg.Wait()
	if r.err == nil {
		fmt.Printf("scenarioC: no error after %v (state at close: %s)\n", r.elapsed, r.state)
		return false
	}
	fmt.Printf("scenarioC: write failed after %v: %v (state at close: %s)\n", r.elapsed, r.err, r.state)
	return true
}

func scenarioA() bool {
	fmt.Println("--- scenario A: peer close should unblock our long-running Write ---")
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Printf("scenarioA: listen: %v\n", err)
		return false
	}
	defer ln.Close()

	var wg sync.WaitGroup
	wg.Add(2)

	type result struct {
		bytes   int64
		elapsed time.Duration
		err     error
		timeout bool
	}
	resCh := make(chan result, 1)

	go func() {
		defer wg.Done()
		conn, err := ln.Accept()
		if err != nil {
			fmt.Printf("scenarioA server: accept: %v\n", err)
			resCh <- result{err: err}
			return
		}
		defer conn.Close()
		buf := make([]byte, scenarioBufBytes)
		for i := range buf {
			buf[i] = 'a'
		}
		start := time.Now()
		var total int64
		done := make(chan struct{})
		var rr result
		go func() {
			for {
				n, err := conn.Write(buf)
				total += int64(n)
				if err != nil {
					rr = result{bytes: total, elapsed: time.Since(start), err: err}
					close(done)
					return
				}
				if total >= scenarioMaxWrite {
					rr = result{bytes: total, elapsed: time.Since(start), err: fmt.Errorf("hit %d byte cap", scenarioMaxWrite)}
					close(done)
					return
				}
			}
		}()
		select {
		case <-done:
		case <-time.After(scenarioDeadline):
			rr = result{bytes: total, elapsed: time.Since(start), timeout: true}
			conn.Close()
			<-done
		}
		resCh <- rr
	}()

	go func() {
		defer wg.Done()
		conn, err := net.Dial("tcp", ln.Addr().String())
		if err != nil {
			fmt.Printf("scenarioA client: dial: %v\n", err)
			return
		}
		n, err := io.CopyN(io.Discard, conn, clientReadAmount)
		fmt.Printf("scenarioA client: read %d bytes, err=%v\n", n, err)
		if err := conn.Close(); err != nil {
			fmt.Printf("scenarioA client: close: %v\n", err)
		} else {
			fmt.Println("scenarioA client: close OK")
		}
	}()

	r := <-resCh
	wg.Wait()

	if r.timeout {
		fmt.Printf("scenarioA: TIMEOUT after %v with %d bytes buffered\n", r.elapsed, r.bytes)
		return false
	}
	if r.err == nil {
		fmt.Printf("scenarioA: HIT CAP %d bytes in %v without unblocking via error\n", r.bytes, r.elapsed)
		return false
	}
	fmt.Printf("scenarioA: server write unblocked after %d bytes / %v: %v\n", r.bytes, r.elapsed, r.err)
	return true
}

func scenarioB() bool {
	fmt.Println("--- scenario B: peer close should unblock our long-running Write (we are the dialer) ---")
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Printf("scenarioB: listen: %v\n", err)
		return false
	}
	defer ln.Close()

	var wg sync.WaitGroup
	wg.Add(2)

	type result struct {
		bytes   int64
		elapsed time.Duration
		err     error
		timeout bool
	}
	resCh := make(chan result, 1)

	go func() {
		defer wg.Done()
		conn, err := ln.Accept()
		if err != nil {
			fmt.Printf("scenarioB server: accept: %v\n", err)
			return
		}
		if _, err := io.ReadFull(conn, make([]byte, 1)); err != nil {
			fmt.Printf("scenarioB server: read 1 byte: %v\n", err)
			conn.Close()
			return
		}
		if _, err := io.WriteString(conn, "ok"); err != nil {
			fmt.Printf("scenarioB server: write 2 bytes: %v\n", err)
		}
		if err := conn.Close(); err != nil {
			fmt.Printf("scenarioB server: close: %v\n", err)
		} else {
			fmt.Println("scenarioB server: close OK")
		}
	}()

	go func() {
		defer wg.Done()
		conn, err := net.Dial("tcp", ln.Addr().String())
		if err != nil {
			fmt.Printf("scenarioB client: dial: %v\n", err)
			resCh <- result{err: err}
			return
		}
		buf := make([]byte, scenarioBufBytes)
		for i := range buf {
			buf[i] = 'x'
		}
		start := time.Now()
		var total int64
		done := make(chan struct{})
		var rr result
		go func() {
			for {
				n, err := conn.Write(buf)
				total += int64(n)
				if err != nil {
					rr = result{bytes: total, elapsed: time.Since(start), err: err}
					close(done)
					return
				}
				if total >= scenarioMaxWrite {
					rr = result{bytes: total, elapsed: time.Since(start), err: fmt.Errorf("hit %d byte cap", scenarioMaxWrite)}
					close(done)
					return
				}
			}
		}()
		select {
		case <-done:
		case <-time.After(scenarioDeadline):
			rr = result{bytes: total, elapsed: time.Since(start), timeout: true}
			conn.Close()
			<-done
		}
		resCh <- rr
	}()

	r := <-resCh
	wg.Wait()

	if r.timeout {
		fmt.Printf("scenarioB: TIMEOUT after %v with %d bytes buffered\n", r.elapsed, r.bytes)
		return false
	}
	if r.err == nil {
		fmt.Printf("scenarioB: HIT CAP %d bytes in %v without unblocking via error\n", r.bytes, r.elapsed)
		return false
	}
	fmt.Printf("scenarioB: client write unblocked after %d bytes / %v: %v\n", r.bytes, r.elapsed, r.err)
	return true
}
