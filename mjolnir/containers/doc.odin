// Index allocation over storage the caller owns. Slots hands out indices and generational
// Handles, optionally holding a freed index back for a grace period so a lagging consumer
// never sees it reused. SlabAllocator hands out blocks of several size classes from one
// shared index range.
package containers
