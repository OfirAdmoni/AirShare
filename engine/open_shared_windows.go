//go:build windows

package main

import (
	"os"

	"golang.org/x/sys/windows"
)

// openFileReadShared opens the file for reading with share modes that match
// typical Windows user expectations (Explorer, OneDrive, browsers) so reads
// do not fail with ERROR_ACCESS_DENIED while another handle is open.
func openFileReadShared(path string) (*os.File, error) {
	pathp, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	h, err := windows.CreateFile(
		pathp,
		windows.GENERIC_READ,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE,
		nil,
		windows.OPEN_EXISTING,
		windows.FILE_ATTRIBUTE_NORMAL,
		0,
	)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(h), path), nil
}
