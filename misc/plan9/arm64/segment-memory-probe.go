// Copyright 2026 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build plan9 && arm64

package main

import (
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

const (
	sgCexec = 0x40 // SG_CEXEC from Plan 9.
	page    = 4096
)

var memoryName = []byte("memory\x00")

func main() {
	fmt.Println("segment-probe start")
	dumpSegments("initial")

	cases := []struct {
		name       string
		size       uintptr
		wantAttach bool
	}{
		{"512MiB", 512 << 20, true},
		{"1GiB", 1 << 30, true},
		{"2GiB", 2 << 30, true},
		{"3GiB", 3 << 30, true},
		{"4095MiB", 4095 << 20, true},
		{"4GiB", 4 << 30, false},
		{"8GiB", 8 << 30, false},
	}

	failed := false
	for _, tc := range cases {
		err := runCase(tc.name, tc.size)
		switch {
		case err == nil && tc.wantAttach:
			fmt.Printf("RESULT %s PASS\n", tc.name)
		case err == nil && !tc.wantAttach:
			fmt.Printf("RESULT %s UNEXPECTED_PASS\n", tc.name)
			failed = true
		case err != nil && tc.wantAttach:
			fmt.Printf("RESULT %s FAIL %v\n", tc.name, err)
			failed = true
		case err != nil && !tc.wantAttach:
			fmt.Printf("RESULT %s EXPECTED_FAIL %v\n", tc.name, err)
		}
	}

	dumpSegments("final")
	if failed {
		os.Exit(1)
	}
}

func runCase(name string, size uintptr) error {
	fmt.Printf("CASE %s attach size=%#x\n", name, size)
	base, err := segattach(size)
	if err != nil {
		return fmt.Errorf("segattach: %w", err)
	}
	fmt.Printf("CASE %s attached base=%#x end=%#x\n", name, base, base+size)
	dumpSegments("after attach " + name)
	defer func() {
		if err := segdetach(base); err != nil {
			fmt.Printf("CASE %s segdetach error: %v\n", name, err)
		}
	}()

	points := []uintptr{base, base + size/2, base + size - page}
	for i, p := range points {
		if got := touch(p, byte(i+1)); got != byte(i+1) {
			return fmt.Errorf("touch %#x got %#x", p, got)
		}
	}
	fmt.Printf("CASE %s sparse-touch ok\n", name)

	for _, p := range points {
		if err := segfree(p, page); err != nil {
			return fmt.Errorf("segfree %#x: %w", p, err)
		}
	}
	fmt.Printf("CASE %s segfree touched pages ok\n", name)

	for _, p := range points {
		if got := *(*byte)(unsafe.Pointer(p)); got != 0 {
			return fmt.Errorf("post-segfree %#x got %#x, want zero", p, got)
		}
	}
	fmt.Printf("CASE %s post-segfree zero-fill ok\n", name)
	return nil
}

func segattach(size uintptr) (uintptr, error) {
	r0, _, err := syscall.Syscall6(syscall.SYS_SEGATTACH, sgCexec, uintptr(unsafe.Pointer(&memoryName[0])), 0, size, 0, 0)
	if err != "" {
		return 0, err
	}
	if r0 == ^uintptr(0) {
		return 0, fmt.Errorf("returned -1")
	}
	return r0, nil
}

func segdetach(addr uintptr) error {
	r0, _, err := syscall.Syscall(syscall.SYS_SEGDETACH, addr, 0, 0)
	if err != "" {
		return err
	}
	if r0 == ^uintptr(0) {
		return fmt.Errorf("returned -1")
	}
	return nil
}

func segfree(addr, size uintptr) error {
	r0, _, err := syscall.Syscall(syscall.SYS_SEGFREE, addr, size, 0)
	if err != "" {
		return err
	}
	if r0 == ^uintptr(0) {
		return fmt.Errorf("returned -1")
	}
	return nil
}

func touch(addr uintptr, value byte) byte {
	p := (*byte)(unsafe.Pointer(addr))
	*p = value
	return *p
}

func dumpSegments(label string) {
	path := fmt.Sprintf("/proc/%d/segment", os.Getpid())
	b, err := os.ReadFile(path)
	if err != nil {
		fmt.Printf("SEGMENTS %s unavailable: %v\n", label, err)
		return
	}
	fmt.Printf("SEGMENTS %s\n%s", label, b)
}
