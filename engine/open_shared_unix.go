//go:build !windows

package main

import "os"

func openFileReadShared(path string) (*os.File, error) {
	return os.Open(path)
}
