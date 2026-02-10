package data

ResourceMetadata :: struct {
	ref_count:  u32, // Reference count for resource lifetime tracking
	auto_purge: bool, // true = purge when ref_count==0, false = self managed lifecycle, never purged automatically
}

SamplerType :: enum u32 {
	NEAREST_CLAMP  = 0,
	LINEAR_CLAMP   = 1,
	NEAREST_REPEAT = 2,
	LINEAR_REPEAT  = 3,
}
