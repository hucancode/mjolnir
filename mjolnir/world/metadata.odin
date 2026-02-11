package world

ResourceMetadata :: struct {
  ref_count:  u32, // Reference count for resource lifetime tracking
  auto_purge: bool, // true = purge when ref_count==0, false = self managed lifecycle, never purged automatically
}
