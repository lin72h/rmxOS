// Shared selection contract for xcrun and the future xcode-select implementation.
// Tests replace this module at build time; no environment variable redirects it.
pub const selection_link: [:0]const u8 = "/var/db/xcode_select_link";
pub const default_directory: [:0]const u8 = "/Library/Developer/CommandLineTools";
