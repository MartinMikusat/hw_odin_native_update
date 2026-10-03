#+build darwin
package native_update

import "core:fmt"
import "core:os"
import "core:strings"
import "base:intrinsics"
import "core:sys/posix"
import "core:time"

foreign import libc "system:c"
foreign libc {
	renamex_np :: proc(old_path, new_path: cstring, flags: u32) -> i32 ---
}

RENAME_SWAP :: 2
COMMAND_TIMEOUT :: 60 * time.Second
DOWNLOAD_TIMEOUT :: 5 * time.Minute

// run starts a fixed system executable with separate arguments, never a shell,
// and reaps it on timeout or when cancel becomes true.
run :: proc(arguments: []string, cancel: ^bool, timeout := COMMAND_TIMEOUT) -> bool {
	if cancel != nil && intrinsics.atomic_load(cancel) {return false}
	child, start_error := os.process_start({command = arguments})
	if start_error != nil {return false}
	started := time.tick_now()
	for {
		state, wait_error := os.process_wait(child, 100 * time.Millisecond)
		if wait_error == nil {return state.exited && state.success && state.exit_code == 0}
		if wait_error != .Timeout || (cancel != nil && intrinsics.atomic_load(cancel)) || time.tick_since(started) >= timeout {
			_ = os.process_kill(child)
			_, _ = os.process_wait(child)
			return false
		}
	}
}

temporary_directory :: proc(parent: string) -> string {
	template := strings.clone_to_cstring(fmt.tprintf("%s/.native-update-XXXXXX", parent), context.temp_allocator)
	if posix.mkdtemp(cast([^]u8)template) == nil {return ""}
	return strings.clone(string(template))
}

// requirement is the code requirement a bundle must satisfy: this team's
// Developer ID, this bundle ID and exactly the announced version.
requirement :: proc(config: Config, version: string) -> (string, bool) {
	_, version_ok := version_parse(version)
	if !version_ok || !identifier_valid(config.bundle_id, "") || !identifier_valid(config.team_id, "") {return "", false}
	return fmt.tprintf(
		`=anchor apple generic and certificate leaf[subject.OU] = "%s" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and identifier "%s" and info[CFBundleShortVersionString] = "%s"`,
		config.team_id, config.bundle_id, version,
	), true
}

bundle_verify :: proc(config: Config, path, version: string, cancel: ^bool) -> bool {
	text, ok := requirement(config, version)
	return ok && run({"/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", text, path}, cancel)
}

download :: proc(url, output: string, file: File, cancel: ^bool) -> bool {
	arguments := []string{
		"/usr/bin/curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https",
		"--max-filesize", fmt.tprintf("%d", file.bytes), "--output", output, url,
	}
	return run(arguments, cancel, DOWNLOAD_TIMEOUT) && file_verify(output, file)
}

feed_directory :: proc(feed_url: string) -> (string, bool) {
	if !strings.has_prefix(feed_url, "https://") {return "", false}
	slash := strings.last_index_byte(feed_url, '/')
	if slash < len("https://") {return "", false}
	return feed_url[:slash], true
}

// prepare checks the feed and, when it announces a newer version, downloads,
// unpacks and verifies it into a staging directory. Allocations use
// context.allocator; the caller owns them and the staging directory (see discard).
prepare :: proc(config: Config, current_version: string, cancel: ^bool = nil) -> Prepared {
	directory, feed_ok := feed_directory(config.feed_url)
	if !feed_ok || !identifier_valid(config.bundle_name, "_ .") {return {status = .Error, error = "update feed is not configured"}}
	temporary, temporary_error := os.temp_dir(context.temp_allocator)
	if temporary_error != nil {return {status = .Error, error = "no temporary directory"}}
	root := temporary_directory(temporary)
	if root == "" {return {status = .Error, error = "could not create the staging directory"}}
	result := Prepared{status = .Error, root = root}
	manifest_path := fmt.tprintf("%s/update.json", root)
	manifest_limit := File{bytes = MAX_MANIFEST_BYTES}
	arguments := []string{
		"/usr/bin/curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https",
		"--max-filesize", fmt.tprintf("%d", manifest_limit.bytes), "--output", manifest_path, config.feed_url,
	}
	if !run(arguments, cancel, 30 * time.Second) {
		result.error = "update check failed"
		return result
	}
	data, read_error := os.read_entire_file(manifest_path, context.temp_allocator)
	if read_error != nil {
		result.error = "update metadata could not be read"
		return result
	}
	manifest, valid := manifest_decode(data, config.bundle_id)
	if !valid {
		result.error = "update metadata is invalid"
		return result
	}
	if !version_newer(manifest.version, current_version) {
		result.status = .Up_To_Date
		return result
	}
	result.manifest = manifest
	archive := fmt.tprintf("%s/download.zip", root)
	unpacked := fmt.tprintf("%s/staged", root)
	app := fmt.tprintf("%s/%s", unpacked, config.bundle_name)
	if !download(fmt.tprintf("%s/%s", directory, manifest.archive.name), archive, manifest.archive, cancel) {
		result.error = "update download failed verification"
		return result
	}
	if !run({"/usr/bin/ditto", "-x", "-k", archive, unpacked}, cancel) || !bundle_verify(config, app, manifest.version, cancel) {
		result.error = "update bundle failed verification"
		return result
	}
	result.app_path = strings.clone(app)
	result.status, result.error = .Ready, ""
	return result
}

// discard removes a staging directory.
discard :: proc(prepared: ^Prepared) {
	if prepared.root != "" {os.remove_all(prepared.root)}
}

// apply replaces the installed bundle with the verified one: it copies beside the
// installed app (same volume), verifies the copy again and swaps the two with
// renamex_np, so the installed app is never half-written. It returns an error
// message, or "" once the new bundle is in place; the previous bundle is removed.
apply :: proc(config: Config, prepared: ^Prepared, installed_app: string) -> string {
	if prepared.status != .Ready {return "no verified update is ready"}
	slash := strings.last_index_byte(installed_app, '/')
	if slash <= 0 || !strings.has_suffix(installed_app, ".app") {return "invalid installed application path"}
	root := temporary_directory(installed_app[:slash])
	if root == "" {return "cannot write beside the installed app"}
	defer os.remove_all(root)
	candidate := fmt.tprintf("%s/%s", root, config.bundle_name)
	if !run({"/usr/bin/ditto", prepared.app_path, candidate}, nil) || !bundle_verify(config, candidate, prepared.manifest.version, nil) {
		return "could not prepare the verified app for installation"
	}
	if renamex_np(strings.clone_to_cstring(installed_app, context.temp_allocator), strings.clone_to_cstring(candidate, context.temp_allocator), RENAME_SWAP) != 0 {
		return "could not replace the app; the installed version was left unchanged"
	}
	return ""
}
