package mjolnir

import "resource"

Material :: struct {
    features: u32,
    name: string,
    albedo: resource.Handle,
    metalic: resource.Handle,
    roughness: resource.Handle,
}
