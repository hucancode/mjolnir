package navigation

import "core:log"

// Simple navigation memory management using standard Odin patterns
// Following C++ reference implementation approach

// Initialize navigation memory system (no-op, using standard Odin allocators)
nav_memory_init :: proc() {
    log.infof("Navigation memory system initialized (using standard allocators)")
}

// Shutdown navigation memory system (no-op, using standard Odin allocators)
nav_memory_shutdown :: proc() {
    log.infof("Navigation memory system shutdown")
}