//go:build !windows
// +build !windows

package unlock

import "errors"

// ForceUnlockFile 在非 Windows 平台上不支持
func ForceUnlockFile(filePath string) error {
	return errors.New("ForceUnlockFile is only supported on Windows")
}

// CloseSelfFileHandles 在非 Windows 平台上不支持
func CloseSelfFileHandles(filePath string) error {
	return errors.New("CloseSelfFileHandles is only supported on Windows")
}
